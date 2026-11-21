#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import IOKit

  /// Device-local inputs stay in memory until the private per-install snapshot
  /// is written. Never use the model-wide IPSW cache for factory calibration.
  struct NativeSensorInputs: Sendable {
    let calibration: Data
    /// Only Macs whose enclave opens the sensor session with a signed root key
    /// have the MSRk record; the others need the calibration alone.
    let rootKey: Data?
  }

  /// Touch ID firmware from this Mac's own sensor records, under the names
  /// the kernel requests. The sensor node's `firmware-name` lists
  /// `apple/mesacal-<board>.bin` and, where the enclave needs it, the root key
  /// `apple/msrk-<board>.bin`; a node that names no calibration makes the
  /// driver load `apple/mesa_calibration.bin`. Touch ID is optional: a Mac
  /// whose records are missing or invalid installs without it, with a warning.
  enum NativeTouchIDFirmware {
    static let defaultCalibrationName = "apple/mesa_calibration.bin"

    static func calibrationName(machine: String) -> String {
      "apple/mesacal-" + machine + ".bin"
    }

    static func rootKeyName(machine: String) -> String { "apple/msrk-" + machine + ".bin" }

    /// This Mac's sensor records, or nil without a sensor. A failure to read
    /// them leaves Touch ID out instead of stopping the installation.
    static func inputs(_ collect: () throws -> NativeSensorInputs?) throws -> NativeSensorInputs? {
      do {
        return try collect()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        warn("its sensor records could not be read (\(describe(error)))")
        return nil
      }
    }

    /// The firmware files for `inputs`, keyed by the board this Mac reports,
    /// or none when the records do not validate.
    static func files(_ inputs: NativeSensorInputs?, machine: String) -> [String: Data] {
      guard let inputs else { return [:] }
      let usable = machine.range(of: #"\A[a-z][a-z0-9]{1,15}\z"#, options: .regularExpression)
      guard usable != nil else {
        warn("its board name cannot name a firmware file")
        return [:]
      }
      do {
        let calibration = inputs.calibration
        guard try SignedSensorInputs.preparedCalibration(calibration) == calibration else {
          throw NativePeripheralInputError.sensorCalibrationMissing
        }
        var files = [calibrationName(machine: machine): calibration]
        files[defaultCalibrationName] = calibration
        if let rootKey = inputs.rootKey {
          files[rootKeyName(machine: machine)] = try SignedSensorInputs.rootKey(rootKey)
        }
        let detail = inputs.rootKey == nil ? "" : " and its signed root-key container"
        InstallerLog.progress("Collected this Mac’s Touch ID calibration\(detail).")
        return files
      } catch {
        warn("its sensor records are not valid (\(describe(error)))")
        return [:]
      }
    }

    private static func describe(_ error: any Error) -> String {
      (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func warn(_ detail: String) {
      InstallerLog.error("Touch ID will not work on Linux: \(detail). Installing without it.")
    }
  }

  struct NativeSensorInputCollector: Sendable {
    let present: @Sendable () throws -> Bool
    let snapshot: @Sendable () throws -> RemovalSnapshot
    let disk: @Sendable (String) throws -> [String: Any]
    let read: @Sendable (String, UInt64) throws -> Data
    let factoryNames: @Sendable () throws -> [String]
    let factoryRead: @Sendable (String) throws -> Data

    static func live(storeIdentifier: String) -> Self {
      Self(
        present: builtInSensor,
        snapshot: { try MacRemovalDiskOperator().snapshot(maximumPartitions: 4096) },
        disk: { try NativeHandoffEnvironment.live.disk($0) }, read: readContainer,
        factoryNames: {
          try FileManager.default.contentsOfDirectory(atPath: factoryDirectory.path)
        },
        factoryRead: {
          try NativeFactoryCalibrationInput.liveRecord(
            name: $0,
            storeIdentifier: storeIdentifier,
            maximum: 16 << 20)
        })
    }

    static let hardwareVolume = URL(fileURLWithPath: "/System/Volumes/Hardware")
    static let factoryRelativePath = "FactoryData/System/Library/Caches/com.apple.factorydata"
    static let factoryDirectory = hardwareVolume.appendingPathComponent(factoryRelativePath)

    func collect(storeIdentifier: String) throws -> NativeSensorInputs? {
      try Task.checkCancellation()
      guard try present() else { return nil }
      let before = try snapshot()
      guard before.disk == storeIdentifier,
        let source = before.partitions.min(by: { $0.offset < $1.offset }),
        source.type == "Apple_APFS_ISC", source.identifier == before.disk + "s1",
        source.size > 0, source.size <= 1 << 30
      else { throw NativePeripheralInputError.localInput }
      func verify() throws {
        let info = try disk(source.identifier)
        guard info["DeviceIdentifier"] as? String == source.identifier,
          info["ParentWholeDisk"] as? String == before.disk,
          info["Content"] as? String == source.type,
          (info["DiskUUID"] as? String)?.uppercased() == source.uuid.uppercased(),
          (info["Size"] as? NSNumber)?.uint64Value == source.size
        else { throw NativePeripheralInputError.identityChanged }
      }
      func verifyFactory() throws {
        try Self.requireFactoryStore(
          try disk(Self.hardwareVolume.path), partition: source.identifier)
      }
      try verify()
      try verifyFactory()
      let names = try factoryNames()
      guard names.count <= 4096, Set(names).count == names.count else {
        throw NativePeripheralInputError.unsafeSnapshot
      }
      func admitted(_ name: String) -> Bool {
        NativeHandoffEvidence.safeRelative(name) && !name.contains("/") && name.utf8.count <= 255
      }
      let roots = names.filter { $0.hasPrefix("MSRk-") }
      guard roots.count <= 1 else { throw NativePeripheralInputError.sensorRootKeyMissing }
      let root = roots.first
      if let root {
        guard admitted(root), root.count > 5 else {
          throw NativePeripheralInputError.sensorRootKeyMissing
        }
      }
      // The enclave refuses the factory records as stored: it loads their
      // IM4P under the FDR sealing manifest with the trust bundle as secb.
      // Only records that need resealing need these.
      var sealingCache: (seal: Data, trust: Data)?
      func sealing() throws -> (seal: Data, trust: Data) {
        if let sealingCache { return sealingCache }
        let records = try Self.sealingRecords(names, read: factoryRead)
        sealingCache = records
        return records
      }
      var rootKey: Data?
      if let root {
        let records = try sealing()
        rootKey = try SignedSensorInputs.rootKey(
          SignedSensorInputs.reseal(factoryRead(root), seal: records.seal, trust: records.trust))
      }
      let calibrations = names.filter { $0.hasPrefix("FSC2-") || $0.hasPrefix("FSCl-") }
      let found: Data
      if calibrations.isEmpty {
        let bytes = try read(source.identifier, source.size)
        guard bytes.count == source.size else { throw NativePeripheralInputError.localInput }
        found = try SignedSensorInputs.calibration(in: bytes)
      } else {
        // With a root key, the calibration must belong to the same sensor.
        guard calibrations.count == 1, let name = calibrations.first,
          root.map({ String(name.dropFirst(5)) == String($0.dropFirst(5)) }) ?? true,
          admitted(name)
        else { throw NativePeripheralInputError.sensorCalibrationMissing }
        let bytes = try factoryRead(name)
        found = try SignedSensorInputs.calibration(in: bytes)
        guard found == bytes else {
          throw NativePeripheralInputError.sensorCalibrationMissing
        }
      }
      // A combined FSCl record already has the layout the enclave loads.
      let calibration: Data
      if try SignedSensorInputs.needsSealing(found) {
        let records = try sealing()
        calibration = try SignedSensorInputs.loadableCalibration(
          found, seal: records.seal, trust: records.trust)
      } else {
        calibration = found
      }
      try Task.checkCancellation()
      try verify()
      try verifyFactory()
      guard try snapshot() == before else { throw NativePeripheralInputError.identityChanged }
      return NativeSensorInputs(calibration: calibration, rootKey: rootKey)
    }

    /// The FDR sealing manifest and the trust bundle that trustobject-current
    /// names. A macOS update can leave older named bundles in the cache; without
    /// trustobject-current exactly one named bundle must be present.
    static func sealingRecords(_ names: [String], read: (String) throws -> Data) throws -> (
      seal: Data, trust: Data
    ) {
      func admitted(_ name: String) -> Bool {
        NativeHandoffEvidence.safeRelative(name) && !name.contains("/") && name.utf8.count <= 255
      }
      let seals = names.filter { $0.hasPrefix("seal-") }
      let bundles = names.filter { $0.hasPrefix("trustobject-") && $0 != "trustobject-current" }
      guard seals.count == 1, let seal = seals.first, admitted(seal) else {
        throw NativePeripheralInputError.sensorSealMissing
      }
      let trust: Data
      if names.contains("trustobject-current") {
        trust = try read("trustobject-current")
      } else {
        guard bundles.count == 1, let only = bundles.first, admitted(only) else {
          throw NativePeripheralInputError.sensorSealMissing
        }
        trust = try read(only)
      }
      let digest = SHA256Digest(hashing: trust).hexadecimal
      let named = bundles.filter { String($0.dropFirst(12)).lowercased() == digest }
      guard named.count == 1, let name = named.first, admitted(name), try read(name) == trust
      else { throw NativePeripheralInputError.sensorSealMissing }
      return (try read(seal), trust)
    }

    static func requireFactoryStore(_ info: [String: Any], partition: String) throws {
      guard info["Internal"] as? Bool == true,
        info["MountPoint"] as? String == hardwareVolume.path,
        let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        stores[0]["APFSPhysicalStore"] as? String == partition
      else { throw NativePeripheralInputError.identityChanged }
    }

    static func builtInSensor() throws -> Bool {
      let node = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io")
      guard node != 0 else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(node) }
      var iterator: io_iterator_t = 0
      guard IORegistryEntryGetChildIterator(node, kIODeviceTreePlane, &iterator) == KERN_SUCCESS
      else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(iterator) }
      var count = 0
      var found = false
      while true {
        try Task.checkCancellation()
        let child = IOIteratorNext(iterator)
        if child == 0 { break }
        defer { IOObjectRelease(child) }
        count += 1
        guard count <= 4096 else { throw NativePeripheralInputError.localInput }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(child, kIODeviceTreePlane, &name) == KERN_SUCCESS
        else { throw NativePeripheralInputError.localInput }
        let value = String(
          decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !value.isEmpty else { throw NativePeripheralInputError.localInput }
        if value.split(separator: "@").first == "spi2" { found = true }
      }
      guard count > 0 else { throw NativePeripheralInputError.localInput }
      return found
    }

    static func readContainer(_ identifier: String, _ expected: UInt64) throws -> Data {
      guard identifier.range(of: #"\Adisk[0-9]+s1\z"#, options: .regularExpression) != nil,
        expected > 0, expected <= 1 << 30
      else { throw NativePeripheralInputError.localInput }
      let fd = open("/dev/r" + identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw NativePeripheralInputError.localInput }
      defer { close(fd) }
      var info = stat()
      var blockSize: UInt32 = 0
      var blocks: UInt64 = 0
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
        ioctl(fd, UInt(0x4004_6418), &blockSize) == 0,
        ioctl(fd, UInt(0x4008_6419), &blocks) == 0, blockSize > 0,
        !blocks.multipliedReportingOverflow(by: UInt64(blockSize)).overflow,
        blocks * UInt64(blockSize) == expected
      else { throw NativePeripheralInputError.localInput }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var result = Data()
      result.reserveCapacity(Int(expected))
      while result.count < expected {
        try Task.checkCancellation()
        let chunk = try file.read(upToCount: min(4 << 20, Int(expected) - result.count)) ?? Data()
        guard !chunk.isEmpty else { throw NativePeripheralInputError.localInput }
        result.append(chunk)
      }
      return result
    }
  }
#endif
