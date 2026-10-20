#if os(macOS)
  import Darwin
  import Foundation

  /// Factory calibration is bounded device data, including when the source
  /// record has mode 0666. Its typed BWC2 fields must validate before publication.
  enum NativeFactoryCalibrationInput {
    static func live(name: String, storeIdentifier: String) throws -> Data {
      func information() throws -> [String: Any] {
        let info = try NativeHandoffEnvironment.live.disk(
          NativeSensorInputCollector.hardwareVolume.path)
        try NativeSensorInputCollector.requireFactoryStore(info, partition: storeIdentifier + "s1")
        return info
      }
      let before = try information()
      guard let device = before["DeviceIdentifier"] as? String,
        let uuid = before["VolumeUUID"] as? String
      else { throw NativePeripheralInputError.identityChanged }
      let tree = try NativeHandoffFileTree(
        NativeSensorInputCollector.hardwareVolume, protected: true,
        volumeRoot: true, volumeDevice: device)
      let bytes = try read(tree, name: name, volumeDevice: device)
      let after = try information()
      guard after["DeviceIdentifier"] as? String == device,
        after["VolumeUUID"] as? String == uuid
      else { throw NativePeripheralInputError.identityChanged }
      return bytes
    }

    static func read(
      _ tree: NativeHandoffFileTree, name: String, owner: uid_t = 0,
      volumeDevice: String? = nil, afterRead: () throws -> Void = {}
    ) throws -> Data {
      guard name.hasPrefix("BWC2-"), name.utf8.count <= 255, !name.contains("/"),
        NativeHandoffEvidence.safeRelative(name)
      else { throw NativePeripheralInputError.localInput }
      let path = NativeSensorInputCollector.factoryRelativePath + "/" + name
      let fd = try tree.fileDescriptor(path)
      defer { close(fd) }
      var before = stat()
      guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
        before.st_uid == owner, before.st_nlink == 1, before.st_size > 0,
        before.st_size <= 32 << 20,
        before.st_mode & 0o022 == 0 || before.st_mode & 0o7777 == 0o666
      else { throw NativePeripheralInputError.localInput }
      if let volumeDevice {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw NativePeripheralInputError.localInput }
        let source = withUnsafeBytes(of: filesystem.f_mntfromname) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard source == "/dev/" + volumeDevice else {
          throw NativePeripheralInputError.identityChanged
        }
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var bytes = Data()
      while bytes.count < before.st_size {
        try Task.checkCancellation()
        let chunk =
          try handle.read(upToCount: min(1 << 20, Int(before.st_size) - bytes.count))
          ?? Data()
        guard !chunk.isEmpty else { throw NativePeripheralInputError.localInput }
        bytes.append(chunk)
      }
      try afterRead()
      var after = stat()
      guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
        before.st_uid == after.st_uid, before.st_mode == after.st_mode,
        before.st_nlink == after.st_nlink, before.st_size == after.st_size,
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
      else { throw NativePeripheralInputError.identityChanged }
      return bytes
    }
  }
#endif
