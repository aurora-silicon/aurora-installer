#if os(macOS)
  import Darwin
  import Foundation

  /// Factory calibration is bounded device data, including when the source
  /// record has mode 0666. Its typed BWC2 fields must validate before publication.
  enum NativeFactoryCalibrationInput {
    /// The whole factory inventory is used only as untrusted firmware input.
    /// Its writable data records share the verified Hardware volume boundary,
    /// while the BWC2 calibration keeps its narrower typed reader.
    static func snapshot(storeIdentifier: String) throws -> [String: Data] {
      func information() throws -> [String: Any] {
        let info = try NativeHandoffEnvironment.live.disk(
          NativeSensorInputCollector.hardwareVolume.path)
        try NativeSensorInputCollector.requireFactoryStore(
          info, partition: storeIdentifier + "s1")
        return info
      }
      let before = try information()
      guard let device = before["DeviceIdentifier"] as? String,
        let uuid = before["VolumeUUID"] as? String
      else { throw NativePeripheralInputError.identityChanged }
      let tree = try NativeHandoffFileTree(
        NativeSensorInputCollector.hardwareVolume, protected: true,
        volumeRoot: true, volumeDevice: device)
      let directory = try tree.fileDescriptor(NativeSensorInputCollector.factoryRelativePath)
      defer { close(directory) }
      var info = stat()
      guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0, info.st_mode & 0o022 == 0
      else { throw NativePeripheralInputError.localInput }
      let root = NativeSensorInputCollector.factoryDirectory
      let names = try NativeFirmwareInputFiles.relativeEntries(root: root, maximum: 10000)
      guard names.count <= 1000 else { throw NativePeripheralInputError.localInput }
      var result = [String: Data]()
      var total = 0
      for name in names.sorted() {
        guard !name.contains("/") else { throw NativePeripheralInputError.localInput }
        let bytes: Data
        if name.hasPrefix("BWC2-") {
          bytes = try read(tree, name: name, volumeDevice: device)
        } else {
          bytes = try readRecord(tree, name: name, maximum: 64 << 20, volumeDevice: device)
        }
        guard bytes.count <= (256 << 20) - total else {
          throw NativePeripheralInputError.localInput
        }
        total += bytes.count
        result[name] = bytes
      }
      let after = try information()
      guard after["DeviceIdentifier"] as? String == device,
        after["VolumeUUID"] as? String == uuid,
        try NativeFirmwareInputFiles.relativeEntries(root: root, maximum: 10000).sorted()
          == names.sorted()
      else { throw NativePeripheralInputError.identityChanged }
      return result
    }

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
      guard name.hasPrefix("BWC2-") else { throw NativePeripheralInputError.localInput }
      return try readRecord(
        tree, name: name, maximum: 32 << 20, owner: owner,
        volumeDevice: volumeDevice, afterRead: afterRead)
    }

    static func readRecord(
      _ tree: NativeHandoffFileTree, name: String, maximum: Int, owner: uid_t = 0,
      volumeDevice: String? = nil, afterRead: () throws -> Void = {}
    ) throws -> Data {
      guard maximum > 0, maximum <= 64 << 20,
        name.utf8.count <= 255, !name.contains("/"),
        NativeHandoffEvidence.safeRelative(name)
      else { throw NativePeripheralInputError.localInput }
      let path = NativeSensorInputCollector.factoryRelativePath + "/" + name
      let fd = try tree.fileDescriptor(path)
      defer { close(fd) }
      var before = stat()
      guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
        before.st_uid == owner, before.st_nlink == 1, before.st_size > 0,
        before.st_size <= maximum,
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
