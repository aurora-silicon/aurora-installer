#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// Verified ranges of a restore image, each with a private checksum record,
  /// in one cache per image named by the digest of its source: the image's
  /// URL and length. Every attempt and installation that reads that image
  /// shares the cache, whatever its plan, so nothing is downloaded twice.
  ///
  /// Ranges of 64 KiB or more are kept exactly as read. Smaller reads, mostly
  /// the ZIP local headers of small members stored next to each other, go
  /// through aligned windows of `windowBytes`: one request and one kept range
  /// serve every such read inside a window.
  ///
  /// A cache outlives jobs. It is removed only when its image is no longer
  /// one the installer can select, or, least recently used first, while all
  /// caches together exceed `maximumRetainedBytes`.
  actor NativeStubRestoreCache: FirmwareRangeReading {
    static let prefix = "native-restore-cache-"
    /// Earlier installers named a cache after the approved plan, so a new
    /// plan for the same image started from nothing. Those are adopted.
    static let planPrefix = "native-stub-cache-"
    static let maximumRetainedBytes = 8 << 30
    static let reserveBytes: UInt64 = 10 << 30
    static let windowBytes = 1 << 20

    nonisolated let sizeBytes: Int
    private let source: any FirmwareRangeReading
    private let root: URL
    private let tree: NativeHandoffFileTree
    private let owner: uid_t
    private var retained = 0
    private var reserved = 0
    private var pending = [String: Task<Data, Error>]()
    private var recent: (name: String, bytes: Data)?

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

    static func identity(url: URL, bytes: Int) throws -> Data {
      try JSONSerialization.data(
        withJSONObject: ["url": url.absoluteString, "bytes": bytes] as [String: Any],
        options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func root(in directory: URL, identity: Data) -> URL {
      directory.appendingPathComponent(prefix + SHA256Digest(hashing: identity).hexadecimal)
    }

    /// The restore images this installer can select at all.
    static func selectableSources() -> Set<String>? {
      guard let policy = try? NativeInspectionPolicy.sealed() else { return nil }
      return Set(policy.firmware.compactMap { URL(string: $0.sourceURL)?.absoluteString })
    }

    /// Adopts plan-keyed caches, then removes a cache whose identity doesn't
    /// match its name, one whose image is not in `selectable`, and, least
    /// recently used first, others while all caches together exceed
    /// `capacity`. The cache at `current` is never removed for size.
    static func prune(
      in directory: URL, current: URL? = nil, selectable: Set<String>?, owner: uid_t = 0,
      capacity: Int = NativeStubRestoreCache.maximumRetainedBytes
    ) {
      adoptPlanCaches(in: directory, owner: owner)
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else { return }
      var kept = [(url: URL, used: Int, bytes: Int)]()
      for name in names where name.hasPrefix(prefix) {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard let used = ownedDirectory(url, owner: owner) else { continue }
        guard let identity = readIdentity(url, owner: owner),
          root(in: directory, identity: identity).lastPathComponent == name,
          let source = (try? JSONSerialization.jsonObject(with: identity) as? [String: Any])?[
            "url"] as? String,
          selectable?.contains(source) ?? true
        else {
          try? FileManager.default.removeItem(at: url)
          continue
        }
        kept.append((url, used, rangeBytes(in: url)))
      }
      var total = kept.reduce(0) { $0 + $1.bytes }
      for cache in kept.sorted(by: { $0.used < $1.used })
      where total > capacity && cache.url.lastPathComponent != current?.lastPathComponent {
        try? FileManager.default.removeItem(at: cache.url)
        total -= cache.bytes
      }
    }

    /// A plan-keyed cache moves under its image's name, or gives the image's
    /// cache the ranges it lacks. Its plan never bound any range.
    private static func adoptPlanCaches(in directory: URL, owner: uid_t) {
      let fileManager = FileManager.default
      for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
      where name.hasPrefix(planPrefix) {
        let legacy = directory.appendingPathComponent(name, isDirectory: true)
        guard ownedDirectory(legacy, owner: owner) != nil else { continue }
        defer { try? fileManager.removeItem(at: legacy) }
        guard let saved = readIdentity(legacy, owner: owner),
          let object = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
          let source = (object["url"] as? String).flatMap(URL.init(string:)),
          let bytes = object["bytes"] as? Int,
          let identity = try? self.identity(url: source, bytes: bytes)
        else { continue }
        let target = root(in: directory, identity: identity)
        if !fileManager.fileExists(atPath: target.path) {
          let marker = legacy.appendingPathComponent("identity.json")
          guard (try? identity.write(to: marker, options: .atomic)) != nil,
            chmod(marker.path, 0o600) == 0
          else { continue }
          rename(legacy.path, target.path)
          continue
        }
        for record in (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
        where record.hasSuffix(".json") && record != "identity.json" {
          let range = String(record.dropLast(".json".count))
          guard !fileManager.fileExists(atPath: target.appendingPathComponent(range + ".bin").path),
            !fileManager.fileExists(atPath: target.appendingPathComponent(record).path),
            rename(
              legacy.appendingPathComponent(range + ".bin").path,
              target.appendingPathComponent(range + ".bin").path) == 0
          else { continue }
          rename(
            legacy.appendingPathComponent(record).path,
            target.appendingPathComponent(record).path)
        }
      }
    }

    /// The directory's modification time, the cache's last use, when it is a
    /// private directory of `owner`.
    private static func ownedDirectory(_ url: URL, owner: uid_t) -> Int? {
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner, info.st_mode & 0o077 == 0
      else { return nil }
      return Int(info.st_mtimespec.tv_sec)
    }

    private static func readIdentity(_ url: URL, owner: uid_t) -> Data? {
      try? NativeHandoffFileTree(url, protected: true, owner: owner)
        .read("identity.json", maximum: 65536)
    }

    private static func rangeBytes(in url: URL) -> Int {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
      return names.filter { $0.hasSuffix(".bin") }.reduce(0) { total, name in
        var info = stat()
        guard lstat(url.appendingPathComponent(name).path, &info) == 0 else { return total }
        return total + Int(info.st_size)
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
      if count >= 65536 { return try await cached(offset: offset, count: count) }
      var bytes = Data()
      var cursor = offset
      while cursor < offset + count {
        let start = cursor / Self.windowBytes * Self.windowBytes
        let window = try await cached(
          offset: start, count: min(Self.windowBytes, sizeBytes - start))
        let end = min(start + window.count, offset + count)
        bytes.append(window.subdata(in: (cursor - start)..<(end - start)))
        cursor = end
      }
      return bytes
    }

    private func cached(offset: Int, count: Int) async throws -> Data {
      let name = "\(offset)-\(count)"
      if let recent, recent.name == name { return recent.bytes }
      if let task = pending[name] { return try await task.value }
      let task = Task { try await self.fetch(offset: offset, count: count, name: name) }
      pending[name] = task
      defer { pending.removeValue(forKey: name) }
      let bytes = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if count <= Self.windowBytes { recent = (name, bytes) }
      return bytes
    }

    private func fetch(offset: Int, count: Int, name: String) async throws -> Data {
      if try !tree.isAbsent(name + ".json") {
        let record = try? JSONDecoder().decode(
          NativeStubFileIdentity.self,
          from: tree.read(name + ".json", maximum: 4096))
        let bytes = try? tree.read(name + ".bin", maximum: 8 << 20)
        if let record, let bytes, record.bytes == count, bytes.count == count,
          NativeStubFileStore.hash(bytes) == record.sha256
        {
          return bytes
        }
        // A kept range that fails its record is never used: it is dropped
        // and read again, since the cache outlives this attempt.
        for suffix in [".json", ".bin"] {
          if unlink(root.appendingPathComponent(name + suffix).path) != 0 && errno != ENOENT {
            throw NativeStubFileError.changedFile
          }
        }
        retained -= min(retained, bytes?.count ?? 0)
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
    /// Plan-keyed caches are adopted, caches of images the installer can no
    /// longer select are removed, and all caches together stay under the cap.
    public static func run(in workingDirectory: URL) {
      NativeStubRestoreCache.prune(
        in: workingDirectory, selectable: NativeStubRestoreCache.selectableSources(),
        owner: geteuid())
    }
  }
#endif
