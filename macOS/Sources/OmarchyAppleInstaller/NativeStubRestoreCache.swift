#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// Only large exact ranges are cached. The namespace binds the approved plan,
  /// URL and archive size; every retained range has a private checksum record.
  actor NativeStubRestoreCache: FirmwareRangeReading {
    nonisolated let sizeBytes: Int
    private let source: any FirmwareRangeReading
    private let root: URL
    private let tree: NativeHandoffFileTree
    private let owner: uid_t
    private var retained = 0
    private var reserved = 0
    private var pending = [String: Task<Data, Error>]()

    init(source: any FirmwareRangeReading, root: URL, owner: uid_t, identity: Data) throws {
      self.source = source
      self.root = root
      self.owner = owner
      sizeBytes = source.sizeBytes
      if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw NativeStubFileError.unsafeFile }
      tree = try NativeHandoffFileTree(root, protected: true, owner: owner)
      var info = stat()
      guard lstat(root.path, &info) == 0, info.st_mode & 0o077 == 0 else { throw NativeStubFileError.unsafeFile }
      let marker = root.appendingPathComponent("identity.json")
      if FileManager.default.fileExists(atPath: marker.path) {
        guard try tree.read("identity.json", maximum: 65536) == identity else { throw NativeStubFileError.invalidPlan }
      } else {
        try identity.write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
      }
      let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
      guard files.count <= 8193 else { throw NativeStubFileError.insufficientSpace }
      retained = 0
      for name in files where name.hasSuffix(".bin") {
        let descriptor = try tree.fileDescriptor(name)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == owner,
          status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0, status.st_size <= 8 << 20
        else { throw NativeStubFileError.unsafeFile }
        retained += Int(status.st_size)
      }
      guard retained <= 8 << 30 else { throw NativeStubFileError.insufficientSpace }
    }

    func read(offset: Int, count: Int) async throws -> Data {
      try Task.checkCancellation()
      guard offset >= 0, count > 0, count <= 8 << 20, offset <= sizeBytes - count else {
        throw NativeStubFileError.invalidPlan
      }
      if count < 65536 { return try await source.read(offset: offset, count: count) }
      let name = "\(offset)-\(count)"
      if let task = pending[name] { return try await task.value }
      let task = Task { try await self.fetch(offset: offset, count: count, name: name) }
      pending[name] = task
      defer { pending.removeValue(forKey: name) }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: { task.cancel() }
    }

    private func fetch(offset: Int, count: Int, name: String) async throws -> Data {
      if try !tree.isAbsent(name + ".json") {
        let record = try JSONDecoder().decode(NativeStubFileIdentity.self,
          from: tree.read(name + ".json", maximum: 4096))
        let bytes = try tree.read(name + ".bin", maximum: 8 << 20)
        guard record.bytes == count, bytes.count == count, NativeStubFileStore.hash(bytes) == record.sha256 else {
          throw NativeStubFileError.changedFile
        }
        return bytes
      }
      var status = statfs()
      guard statfs(root.path, &status) == 0, retained + reserved <= (8 << 30) - count,
        UInt64(status.f_bavail) * UInt64(status.f_bsize) >= (10 << 30) + UInt64(count * 2)
      else { throw NativeStubFileError.insufficientSpace }
      reserved += count
      defer { reserved -= count }
      let bytes = try await source.read(offset: offset, count: count)
      guard bytes.count == count else { throw NativeStubFileError.changedFile }
      let store = NativeStubFileStore(tree: tree, owner: owner)
      let identity = try await store.data(bytes, at: name + ".bin", mode: 0o600)
      _ = try await store.data(JSONEncoder().encode(identity), at: name + ".json", mode: 0o600)
      retained += count
      return bytes
    }

    func retire() throws {
      try FileManager.default.removeItem(at: root)
    }
  }
#endif
