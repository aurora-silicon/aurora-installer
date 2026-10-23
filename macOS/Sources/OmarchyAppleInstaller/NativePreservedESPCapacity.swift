#if os(macOS)
  import Darwin
  import Foundation

  /// A reset keeps the existing ESP. Each payload file that differs from the
  /// file at its path is written in full while the replaced file stays as its
  /// rollback copy, so nothing is freed; only an identical file needs no room.
  struct NativePreservedESPCapacity: Sendable {
    let prepared: NativePreservedInstallAdmission.Prepared
    var disks: NativeAPFSPlatform = .live
    var device: NativeESPVolumeIDPlatform = .live()

    /// Read-only, before the first write: refuses an ESP without room for the
    /// payload's files, the owner's configuration and their rollback copies.
    func admit(installConf: InstallConf) async throws {
      var files = [(path: String, bytes: Data)]()
      for entry in prepared.esp.entries {
        let bytes = try await prepared.esp.archive.read(entry.member, maximumBytes: 64 << 20)
        files.append((entry.path, bytes))
      }
      files.append((InstallConf.relativePath, installConf.serializedData))
      let esp = prepared.target.esp
      try verify()
      let (descriptor, blockSize) = try device.openTarget(esp, false)
      defer { close(descriptor) }
      try verify()
      let volume = try RemovalFATVolume(size: esp.size) { offset, count in
        try Self.read(descriptor, at: offset, count: count, blockSize: blockSize, size: esp.size)
      }
      let required = try Self.requiredBytes(files, on: volume)
      let available = try volume.freeBytes()
      try verify()
      guard required <= available else {
        throw NativePreservedInstallError.espFull(
          requiredBytes: required, availableBytes: available)
      }
    }

    /// Each written file takes whole clusters, plus one cluster for the
    /// directory entries of its staged, final and rollback names.
    static func requiredBytes(_ files: [(path: String, bytes: Data)], on volume: RemovalFATVolume)
      throws -> UInt64
    {
      let unit = UInt64(volume.allocationUnit)
      var required: UInt64 = 0
      for file in files {
        let components = file.path.split(separator: "/").map(String.init)
        if try volume.read(components, limit: 64 << 20) == file.bytes { continue }
        required += (UInt64(file.bytes.count) + unit - 1) / unit * unit + unit
      }
      return required
    }

    private func verify() throws {
      guard try disks.snapshot() == prepared.diskSnapshot else {
        throw NativePreservedInstallError.changedLayout
      }
      try disks.verifyPartition(prepared.target.esp, prepared.diskSnapshot.disk)
    }

    /// Raw devices read whole blocks; the requested range is cut back out.
    private static func read(
      _ descriptor: Int32, at offset: UInt64, count: Int, blockSize: Int, size: UInt64
    ) throws -> Data {
      let block = UInt64(blockSize)
      let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
      guard blockSize > 0, count > 0, !overflow, end <= size else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let start = offset / block * block
      let stop = min((end + block - 1) / block * block, size)
      var buffer = [UInt8](repeating: 0, count: Int(stop - start))
      var done = 0
      while done < buffer.count {
        let got = buffer.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress! + done, $0.count - done, off_t(start) + off_t(done))
        }
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { throw NativeHandoffValidationError.invalidTarget }
        done += got
      }
      let from = Int(offset - start)
      return Data(buffer[from..<from + count])
    }
  }
#endif
