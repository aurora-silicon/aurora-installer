#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// Only large exact ranges are cached, each with a private checksum record.
  ///
  /// There is one cache per restore image, named by the digest of the image's
  /// identity: its URL, length and version. A cache outlives a failed attempt,
  /// so the next attempt or installation reads the same verified ranges instead
  /// of downloading them again. It is removed when the stub files are
  /// installed, after `maximumAge` without use, or when space runs low.
  actor NativeStubRestoreCache: FirmwareRangeReading {
    static let prefix = "native-restore-cache-"
    /// Earlier installers kept one cache per approved plan, which no later
    /// attempt could use.
    static let planPrefix = "native-stub-cache-"
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumRetainedBytes = 8 << 30
    static let reserveBytes: UInt64 = 10 << 30

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
      guard lstat(root.path, &info) == 0, info.st_mode & 0o077 == 0 else {
        throw NativeStubFileError.unsafeFile
      }
      // The directory's modification time records the cache's last use.
      guard utimes(root.path, nil) == 0 else { throw NativeStubFileError.unsafeFile }
      let marker = root.appendingPathComponent("identity.json")
      if FileManager.default.fileExists(atPath: marker.path) {
        guard try tree.read("identity.json", maximum: 65536) == identity else {
          throw NativeStubFileError.invalidPlan
        }
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
      guard retained <= Self.maximumRetainedBytes else {
        throw NativeStubFileError.insufficientSpace
      }
    }

    static func root(in directory: URL, identity: Data) -> URL {
      directory.appendingPathComponent(prefix + SHA256Digest(hashing: identity).hexadecimal)
    }

    /// Removes plan-keyed caches, other images' caches unused for
    /// `maximumAge`, and a cache at `current`'s place that belongs to another
    /// identity. While the volume has less free space than a full cache and
    /// the reserve, it removes other images' caches, least recently used first.
    static func prune(
      in directory: URL, keeping current: (root: URL, identity: Data)? = nil,
      owner: uid_t = 0, now: Date = Date(),
      freeBytes: (URL) -> UInt64? = NativeStubRestoreCache.freeBytes
    ) {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else { return }
      var others = [(url: URL, used: Date)]()
      for name in names where name.hasPrefix(prefix) || name.hasPrefix(planPrefix) {
        let url = directory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == owner
        else { continue }
        if let current, name == current.root.lastPathComponent {
          let marker = url.appendingPathComponent("identity.json")
          if FileManager.default.fileExists(atPath: marker.path),
            (try? NativeHandoffFileTree(url, protected: true, owner: owner)
              .read("identity.json", maximum: 65536)) != current.identity
          {
            try? FileManager.default.removeItem(at: url)
          }
          continue
        }
        let used = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if name.hasPrefix(planPrefix) || now.timeIntervalSince(used) > maximumAge {
          try? FileManager.default.removeItem(at: url)
        } else {
          others.append((url, used))
        }
      }
      for other in others.sorted(by: { $0.used < $1.used }) {
        guard let free = freeBytes(directory),
          free < reserveBytes + UInt64(maximumRetainedBytes)
        else { break }
        try? FileManager.default.removeItem(at: other.url)
      }
    }

    static func freeBytes(_ directory: URL) -> UInt64? {
      var status = statfs()
      guard statfs(directory.path, &status) == 0 else { return nil }
      return UInt64(status.f_bavail) * UInt64(status.f_bsize)
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
      } onCancel: {
        task.cancel()
      }
    }

    private func fetch(offset: Int, count: Int, name: String) async throws -> Data {
      if try !tree.isAbsent(name + ".json") {
        let record = try JSONDecoder().decode(
          NativeStubFileIdentity.self,
          from: tree.read(name + ".json", maximum: 4096))
        let bytes = try tree.read(name + ".bin", maximum: 8 << 20)
        guard record.bytes == count, bytes.count == count,
          NativeStubFileStore.hash(bytes) == record.sha256
        else {
          throw NativeStubFileError.changedFile
        }
        return bytes
      }
      guard retained + reserved <= Self.maximumRetainedBytes - count,
        let free = Self.freeBytes(root), free >= Self.reserveBytes + UInt64(count * 2)
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

  /// Restore-image cache pruning the helper does when it starts, before it
  /// answers any request.
  public enum RestoreImageCacheHousekeeping {
    /// Caches from attempts that were never retried, and those of earlier
    /// installers, are removed here too, not only when an installation next
    /// starts.
    public static func run(in workingDirectory: URL) {
      NativeStubRestoreCache.prune(in: workingDirectory, owner: geteuid())
    }
  }
#endif
