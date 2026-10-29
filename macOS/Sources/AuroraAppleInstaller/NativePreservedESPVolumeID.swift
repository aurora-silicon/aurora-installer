#if os(macOS)
  import Darwin
  import Foundation

  enum NativeESPVolumeIDError: Error, Equatable, Sendable {
    case unsupportedFilesystem
    case mounted
  }

  /// The FAT32 boot sector and its backup copy, read through the raw partition
  /// in whole sectors. Only the volume serial at 0x43 is ever rewritten.
  struct NativeFATBootSectors: Equatable, Sendable {
    static let serialOffset = 0x43
    let sectorBytes: Int
    let backupSector: Int
    private(set) var primary: [UInt8]
    private(set) var backup: [UInt8]

    var serials: [UInt32] { [primary, backup].map { Self.serial(in: $0) } }

    /// Reads a payload volume ID the way a fresh install's formatter does:
    /// 0x-prefixed hexadecimal, 0-prefixed octal, otherwise decimal.
    static func serial(volumeID text: String) -> UInt32? {
      let digits: Substring
      let radix: Int
      if text.hasPrefix("0x") || text.hasPrefix("0X") {
        digits = text.dropFirst(2)
        radix = 16
      } else if text.count > 1, text.hasPrefix("0") {
        digits = text.dropFirst()
        radix = 8
      } else {
        digits = Substring(text)
        radix = 10
      }
      guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
      return UInt32(digits, radix: radix)
    }

    /// Admits a FAT32 boot sector whose backup is an exact copy, except for
    /// bit 0 of 0x41, which Linux sets on the primary sector only while the
    /// volume is mounted, and the serial, which the caller checks.
    init(descriptor: Int32, blockSize: Int, partitionSize: UInt64) throws {
      guard (512...4096).contains(blockSize), blockSize & (blockSize - 1) == 0 else {
        throw NativeESPVolumeIDError.unsupportedFilesystem
      }
      let head = try Self.read(descriptor, at: 0, count: blockSize, size: partitionSize)
      let sector = Int(head[11]) | Int(head[12]) << 8
      guard [512, 1024, 2048, 4096].contains(sector), sector % blockSize == 0 else {
        throw NativeESPVolumeIDError.unsupportedFilesystem
      }
      let primary = try Self.read(descriptor, at: 0, count: sector, size: partitionSize)
      func u16(_ at: Int) -> Int { Int(primary[at]) | Int(primary[at + 1]) << 8 }
      func u32(_ at: Int) -> UInt64 { UInt64(u16(at)) | UInt64(u16(at + 2)) << 16 }
      let reserved = u16(0x0E)
      let backupSector = u16(0x32)
      guard [0xEB, 0xE9].contains(primary[0]), primary[510] == 0x55, primary[511] == 0xAA,
        reserved > 0, (1...2).contains(primary[0x10]),
        u16(0x11) == 0, u16(0x13) == 0, u16(0x16) == 0, u32(0x24) > 0,
        u32(0x20) > 0, u32(0x20) * UInt64(sector) <= partitionSize,
        primary[0x42] == 0x29, Array(primary[0x52..<0x5A]) == Array("FAT32   ".utf8),
        backupSector > 0, backupSector < reserved, backupSector != u16(0x30)
      else { throw NativeESPVolumeIDError.unsupportedFilesystem }
      let backup = try Self.read(
        descriptor, at: UInt64(backupSector * sector), count: sector, size: partitionSize)
      let serialBytes = Self.serialOffset..<Self.serialOffset + 4
      guard
        zip(primary, backup).enumerated().allSatisfy({ index, pair in
          pair.0 == pair.1 || serialBytes.contains(index)
            || (index == 0x41 && pair.0 ^ pair.1 == 1)
        })
      else { throw NativeESPVolumeIDError.unsupportedFilesystem }
      self.sectorBytes = sector
      self.backupSector = backupSector
      self.primary = primary
      self.backup = backup
    }

    mutating func setSerial(_ value: UInt32) {
      for index in 0..<4 {
        let byte = UInt8(truncatingIfNeeded: value >> (8 * index))
        primary[Self.serialOffset + index] = byte
        backup[Self.serialOffset + index] = byte
      }
    }

    /// Writes each sector that differs from `current`, the backup first, so an
    /// interrupted update leaves the primary serial as it was.
    func write(over current: Self, descriptor: Int32) throws {
      guard sectorBytes == current.sectorBytes, backupSector == current.backupSector else {
        throw NativeESPVolumeIDError.unsupportedFilesystem
      }
      if backup != current.backup {
        try Self.write(descriptor, backup, at: UInt64(backupSector * sectorBytes))
      }
      if primary != current.primary {
        try Self.write(descriptor, primary, at: 0)
      }
    }

    private static func serial(in sector: [UInt8]) -> UInt32 {
      (0..<4).reduce(UInt32(0)) { value, index in
        value | UInt32(sector[serialOffset + index]) << (8 * index)
      }
    }

    private static func read(_ descriptor: Int32, at offset: UInt64, count: Int, size: UInt64)
      throws -> [UInt8]
    {
      let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
      guard count > 0, !overflow, end <= size else {
        throw NativeESPVolumeIDError.unsupportedFilesystem
      }
      var bytes = [UInt8](repeating: 0, count: count)
      var done = 0
      while done < count {
        let got = bytes.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
        }
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { throw NativeHandoffValidationError.invalidTarget }
        done += got
      }
      return bytes
    }

    private static func write(_ descriptor: Int32, _ bytes: [UInt8], at offset: UInt64) throws {
      var done = 0
      while done < bytes.count {
        let count = bytes.withUnsafeBytes {
          pwrite(
            descriptor, $0.baseAddress! + done, bytes.count - done,
            off_t(offset) + off_t(done))
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NativeRawImageError.writeFailed }
        done += count
      }
    }
  }

  /// Raw access to the preserved ESP. Fixtures substitute an image file.
  struct NativeESPVolumeIDPlatform: Sendable {
    var openTarget:
      @Sendable (RemovalPartition, _ writable: Bool) throws -> (descriptor: Int32, blockSize: Int)
    var flush: @Sendable (Int32) throws -> Void
    var mounted: @Sendable (RemovalPartition) throws -> Bool

    static func live(_ environment: NativeHandoffEnvironment = .live) -> Self {
      Self(
        openTarget: { partition, writable in
          try NativeRawImagePlatform.openPartition(
            partition, flags: writable ? O_RDWR : O_RDONLY)
        },
        flush: { descriptor in
          guard fsync(descriptor) == 0 else { throw NativeRawImageError.flushFailed }
          try NativeRawImagePlatform.live.flush(descriptor)
        },
        mounted: { partition in
          let info = try environment.disk(partition.identifier)
          guard (info["DiskUUID"] as? String)?.uppercased() == partition.uuid.uppercased() else {
            throw NativeHandoffValidationError.invalidTarget
          }
          return (info["MountPoint"] as? String)?.isEmpty == false
        })
    }
  }

  /// Gives the preserved ESP the FAT volume serial the payload names, as a
  /// fresh install formats it; the payload's boot configuration and fstab find
  /// the ESP by that serial. The previous serial is journaled before the first
  /// write, so a retry resumes and a rollback restores it.
  struct NativePreservedESPVolumeIDExecution: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let prepared: NativePreservedInstallAdmission.Prepared
    var disks: NativeAPFSPlatform = .live
    var device: NativeESPVolumeIDPlatform = .live()

    /// Read-only. Refuses, before the first payload write, an ESP whose boot
    /// sectors couldn't be updated.
    func admit(journal: NativePreservedInstallJournal) throws {
      guard let installed = prepared.espVolumeID else { return }
      let state = try admitted(journal, states: [.ready, .started])
      let saved = try state == .ready ? nil : recorded(journal)
      let written = try state == .ready ? nil : journal.espVolumeIDReceipt()
      let sectors = try current(saved)
      if written != nil {
        guard sectors.serials.allSatisfy({ $0 == installed }) else {
          throw NativeHandoffValidationError.changedContent
        }
      } else if sectors.serials.contains(where: { $0 != installed }) {
        guard try !device.mounted(prepared.target.esp) else {
          throw NativeESPVolumeIDError.mounted
        }
      }
    }

    /// Runs while the ESP is unmounted, after the images and before the ESP
    /// files are replaced.
    func prepare(
      journal: NativePreservedInstallJournal,
      authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) throws {
      guard let installed = prepared.espVolumeID else { return }
      _ = try admitted(journal, states: [.started])
      try disks.verifySourceOwner(package, authorization, bootstrap, nil)
      let esp = prepared.target.esp
      let saved = try recorded(journal)
      let sectors = try current(saved)
      if try journal.espVolumeIDReceipt() != nil {
        guard sectors.serials.allSatisfy({ $0 == installed }) else {
          throw NativeHandoffValidationError.changedContent
        }
        return
      }
      if sectors.serials.contains(where: { $0 != installed }) {
        guard try !device.mounted(esp) else { throw NativeESPVolumeIDError.mounted }
      }
      let baseline =
        saved
        ?? NativePreservedESPVolumeID(
          partitionUUID: esp.uuid.lowercased(), previous: sectors.serials[0],
          installed: installed)
      if saved == nil { try journal.recordESPVolumeIDBaseline(baseline) }
      try apply(installed, saved: baseline)
      try journal.recordESPVolumeID(baseline)
    }

    /// Rollback before completion: writes the journaled previous serial back,
    /// as the retained ESP backups keep the previous files.
    func restore(
      journal: NativePreservedInstallJournal,
      authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) throws {
      guard prepared.espVolumeID != nil else { return }
      _ = try admitted(journal, states: [.started, .written])
      guard let saved = try recorded(journal) else { return }
      try disks.verifySourceOwner(package, authorization, bootstrap, nil)
      try apply(saved.previous, saved: saved)
    }

    private func admitted(
      _ journal: NativePreservedInstallJournal, states: [NativePreservedInstallState]
    ) throws -> NativePreservedInstallState {
      let state = try journal.snapshot()
      let target = prepared.target
      let baseline = prepared.diskSnapshot
      guard package.installationIntent == .reinstall, state.plan == approved,
        states.contains(state.state), state.targetIdentity == target.identityDigest,
        state.transcript.starts(with: prepared.transcript),
        target.disk == baseline.disk, baseline.disk == approved.storeIdentifier,
        target.esp.type == "EFI", UUID(uuidString: target.esp.uuid) != nil,
        target.esp.identifier.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression)
          != nil,
        baseline.partitions.contains(where: {
          $0.identifier == target.esp.identifier && $0 == target.esp
        })
      else { throw NativePreservedInstallError.changedLayout }
      return state.state
    }

    private func recorded(_ journal: NativePreservedInstallJournal) throws
      -> NativePreservedESPVolumeID?
    {
      guard let saved = try journal.espVolumeIDBaseline() else { return nil }
      guard saved.partitionUUID == prepared.target.esp.uuid.lowercased(),
        saved.installed == prepared.espVolumeID
      else { throw NativeRecoveryJournalError.evidenceChanged }
      return saved
    }

    private func verify() throws {
      guard try disks.snapshot() == prepared.diskSnapshot else {
        throw NativePreservedInstallError.changedLayout
      }
      try disks.verifyPartition(prepared.target.esp, prepared.diskSnapshot.disk)
    }

    /// The partition is re-verified around every open, read and write.
    private func opened<T>(
      writable: Bool, _ body: (Int32, Int, NativeFATBootSectors) throws -> T
    ) throws -> T {
      let esp = prepared.target.esp
      try verify()
      let (descriptor, blockSize) = try device.openTarget(esp, writable)
      defer { close(descriptor) }
      try verify()
      let result = try body(
        descriptor, blockSize,
        NativeFATBootSectors(
          descriptor: descriptor, blockSize: blockSize, partitionSize: esp.size))
      try verify()
      return result
    }

    /// Without a journaled baseline both serials must agree. With one, each
    /// may hold only the previous or the installed serial.
    private func check(_ sectors: NativeFATBootSectors, _ saved: NativePreservedESPVolumeID?)
      throws
    {
      if let saved {
        guard sectors.serials.allSatisfy({ $0 == saved.previous || $0 == saved.installed })
        else { throw NativeHandoffValidationError.changedContent }
      } else {
        guard sectors.serials[0] == sectors.serials[1] else {
          throw NativeESPVolumeIDError.unsupportedFilesystem
        }
      }
    }

    private func current(_ saved: NativePreservedESPVolumeID?) throws -> NativeFATBootSectors {
      let sectors = try opened(writable: false) { _, _, read in read }
      try check(sectors, saved)
      return sectors
    }

    /// Writes `serial` into each boot sector that doesn't hold it, flushes the
    /// device and reads both sectors back.
    private func apply(_ serial: UInt32, saved: NativePreservedESPVolumeID) throws {
      let esp = prepared.target.esp
      guard try current(saved).serials.contains(where: { $0 != serial }) else { return }
      guard try !device.mounted(esp) else { throw NativeESPVolumeIDError.mounted }
      try opened(writable: true) { descriptor, blockSize, sectors in
        try check(sectors, saved)
        var expected = sectors
        expected.setSerial(serial)
        try expected.write(over: sectors, descriptor: descriptor)
        try device.flush(descriptor)
        guard
          try NativeFATBootSectors(
            descriptor: descriptor, blockSize: blockSize, partitionSize: esp.size) == expected
        else { throw NativeHandoffValidationError.changedContent }
      }
    }
  }
#endif
