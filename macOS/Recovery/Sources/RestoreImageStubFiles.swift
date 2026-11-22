import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Writes a RestoreImageStubPlan's files from the restore image into the new
/// stub's System, Preboot and Recovery volumes, for recoveryOS: the
/// restore-image part of the main installer's NativeStubFiles.populate, with
/// the same paths, order and modes. Each file is streamed with range reads
/// into a private temporary file next to its destination, checked (member
/// length and CRC-32, then the written file's own size and SHA-256), flushed,
/// and only then given its name. A destination that already holds the same
/// bytes is adopted, so an interrupted run can simply be run again; one that
/// holds anything else is left alone and stops the run. No path goes through
/// a link: every directory is opened without following one.
///
/// Two kinds of file are left to the next step and returned in `pending`,
/// each with its place among the receipts: a top-level restore directory
/// member that is an Apple Encrypted Archive (decoded first, as the main
/// installer does on macOS), and the Recovery image, which the stub keeps
/// compressed (decmpfs, as the main installer writes it) and which is itself
/// an Apple Encrypted Archive in current images. The installer's own files
/// (AdminUserRecoveryInfo.plist, the System volume's restore link, the Finish
/// Installation launcher, .IAPhysicalMedia and the receipts) are not written
/// here either. `roots` must be the stub's mounted volume roots, which the
/// caller has checked.
public struct RestoreImageStubFiles {
  public enum Failure: Error, Equatable {
    /// A path, root or group the stub can't be written under.
    case invalidPlan
    /// A directory or file in the way is a link, not ours, or writable by others.
    case unsafeFile
    /// A destination already holds other bytes, or a file changed while read.
    case changedFile
    case writeFailed
  }

  public struct Identity: Codable, Equatable {
    public let bytes: Int
    public let sha256: String
  }

  /// One written file or link, by its path on its volume, as the main
  /// installer's per-file receipt records it.
  public struct Installed: Codable, Equatable {
    public let role: String
    public let path: String
    public let installerDataName: String?
    public let identity: Identity
    /// The target, for a link; its identity is that of the target's bytes.
    public let linkTarget: String?
  }

  /// A member this pass leaves for the next step to write to `path` on
  /// `role`'s volume: decoded first if `appleEncrypted`, and kept compressed
  /// if `compressed`. Its receipt goes at `position` among `installed`.
  public struct Pending: Equatable {
    public let member: String
    public let role: String
    public let path: String
    public let installerDataName: String?
    public let appleEncrypted: Bool
    public let compressed: Bool
    public let position: Int
  }

  public static let recoveryImagePath = "usr/standalone/firmware/arm64eBaseSystem.dmg"
  public static let systemVersionPath = "System/Library/CoreServices/SystemVersion.plist"
  public static let roles = ["System", "Preboot", "Recovery"]

  public let installed: [Installed]
  public let pending: [Pending]

  /// `roots` holds the mounted System, Preboot and Recovery volumes; Preboot
  /// and Recovery files go under the volume group `group`.
  public init(
    plan: RestoreImageStubPlan, directory: RestoreImageDirectory,
    read: RestoreImageDirectory.Read, roots: [String: URL], group: String,
    owner: uid_t = geteuid(), chunkBytes: Int = RestoreImageDirectory.streamChunk
  ) throws {
    guard Set(roots.keys) == Set(Self.roles), let uuid = UUID(uuidString: group),
      uuid.uuidString == group
    else { throw Failure.invalidPlan }
    var trees = [String: Tree]()
    for role in Self.roles {
      trees[role] = try Tree(roots[role]!, owner: owner, namespace: group)
    }
    let members = Dictionary(uniqueKeysWithValues: directory.entries.map { ($0.name, $0) })
    var installed = [Installed]()
    var pending = [Pending]()

    func fullPath(_ role: String, _ path: String) -> String {
      role == "System" ? path : group + "/" + path
    }
    func record(
      _ role: String, _ path: String, _ dataName: String?, link: String? = nil,
      _ write: (Tree, String) throws -> Identity
    ) throws {
      let relative = fullPath(role, path)
      installed.append(
        Installed(
          role: role, path: relative, installerDataName: dataName,
          identity: try write(trees[role]!, relative), linkTarget: link))
    }
    func copy(
      _ role: String, _ path: String, _ dataName: String?,
      _ entry: RestoreImageDirectory.Entry
    ) throws {
      try record(role, path, dataName) { tree, relative in
        try tree.publish(relative, bytes: entry.size, mode: 0o644) { append in
          try directory.stream(entry, chunkBytes: chunkBytes, read: read, consume: append)
        }
      }
    }

    for operation in plan.copies {
      guard let entry = members[operation.member] else { throw Failure.invalidPlan }
      if let target = plan.linkTargets[operation.member] {
        // A link's receipt has no installer data name, as in the main installer.
        try record(operation.role, operation.path, nil, link: target) {
          try $0.link($1, target: target)
        }
      } else if plan.isTopLevelRestore(operation),
        try directory.isAppleEncryptedArchive(entry, read: read)
      {
        pending.append(
          Pending(
            member: operation.member, role: operation.role, path: operation.path,
            installerDataName: operation.installerDataName, appleEncrypted: true,
            compressed: false, position: installed.count))
      } else {
        try copy(operation.role, operation.path, operation.installerDataName, entry)
      }
    }
    try record("Preboot", plan.restorePath + "/BuildManifest.plist", "BuildManifest.plist") {
      try $0.data(plan.manifest, at: $1)
    }
    pending.append(
      Pending(
        member: plan.recoveryMember.name, role: "Recovery", path: Self.recoveryImagePath,
        installerDataName: nil,
        appleEncrypted: try directory.isAppleEncryptedArchive(plan.recoveryMember, read: read),
        compressed: true, position: installed.count))
    try record("System", Self.systemVersionPath, "SystemVersion.plist") {
      try $0.data(plan.systemVersion, at: $1)
    }
    self.installed = installed
    self.pending = pending
  }

  /// A volume's tree, opened at its root, walked one directory at a time
  /// without following links.
  final class Tree {
    let root: Int32
    let owner: uid_t
    let namespace: String

    init(_ url: URL, owner: uid_t, namespace: String) throws {
      root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      self.owner = owner
      self.namespace = namespace
      guard root >= 0 else { throw Failure.unsafeFile }
      try Self.requireDirectory(root, owner: owner)
    }
    deinit { close(root) }

    /// A directory of `owner`'s that no one else can write.
    static func requireDirectory(_ descriptor: Int32, owner: uid_t) throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner, info.st_mode & 0o022 == 0
      else { throw Failure.unsafeFile }
    }

    /// The opened parent directory of `path`, made as needed, and its leaf.
    func parent(_ path: String) throws -> (Int32, String) {
      guard RestoreImageDirectory.safeRelative(Array(path.utf8)) else {
        throw Failure.invalidPlan
      }
      // Split on bytes: a Character split keeps "/\u{301}" whole.
      var parts = Array(path.utf8).split(separator: UInt8(ascii: "/")).map {
        String(decoding: $0, as: UTF8.self)
      }
      let leaf = parts.removeLast()
      var current = dup(root)
      guard current >= 0 else { throw Failure.unsafeFile }
      for part in parts {
        var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 && errno == ENOENT {
          // A new directory gets its mode whatever the umask, and its name
          // is flushed, as in the main installer.
          guard mkdirat(current, part, 0o755) == 0 else {
            close(current)
            throw Failure.writeFailed
          }
          next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          guard next >= 0, fchmod(next, 0o755) == 0, fsync(current) == 0 else {
            if next >= 0 { close(next) }
            close(current)
            throw Failure.writeFailed
          }
        }
        close(current)
        guard next >= 0 else { throw Failure.unsafeFile }
        current = next
        do { try Self.requireDirectory(current, owner: owner) } catch {
          close(current)
          throw error
        }
      }
      return (current, leaf)
    }

    func data(_ data: Data, at path: String, mode: mode_t = 0o644) throws -> Identity {
      try publish(path, bytes: data.count, mode: mode) { try $0(data) }
    }

    /// A link at `path` to `target`; an existing link to the same target is adopted.
    func link(_ path: String, target: String) throws -> Identity {
      let (parent, leaf) = try self.parent(path)
      defer { close(parent) }
      if symlinkat(target, parent, leaf) != 0 {
        guard errno == EEXIST else { throw Failure.writeFailed }
        var info = stat()
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = readlinkat(parent, leaf, &buffer, 4096)
        guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_mode & S_IFMT == S_IFLNK, info.st_uid == owner, info.st_nlink == 1, count >= 0,
          Array(buffer.prefix(count).map { UInt8(bitPattern: $0) }) == Array(target.utf8)
        else { throw Failure.changedFile }
      }
      guard fsync(parent) == 0 else { throw Failure.writeFailed }
      let bytes = Data(target.utf8)
      return Identity(bytes: bytes.count, sha256: RecoveryDigest.sha256(bytes))
    }

    /// Writes `bytes` bytes that `produce` hands to its sink into a private
    /// file, checks and flushes it, then names it `path`.
    func publish(
      _ path: String, bytes: Int, mode: mode_t,
      produce: (_ append: (Data) throws -> Void) throws -> Void
    ) throws -> Identity {
      guard bytes >= 0, bytes <= RestoreImageDirectory.maximumMember else {
        throw Failure.invalidPlan
      }
      let (parent, leaf) = try self.parent(path)
      defer { close(parent) }
      let temporary = Self.temporaryName(namespace: namespace, path: path)
      var stale = stat()
      if fstatat(parent, temporary, &stale, AT_SYMLINK_NOFOLLOW) == 0 {
        // A run stopped after naming a file and before removing its private
        // name leaves both names on one file: the private one can go.
        var named = stat()
        let alsoNamed =
          stale.st_nlink == 2 && fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0
          && named.st_dev == stale.st_dev && named.st_ino == stale.st_ino
        guard stale.st_mode & S_IFMT == S_IFREG, stale.st_uid == owner,
          stale.st_mode & 0o022 == 0, stale.st_nlink == 1 || alsoNamed,
          unlinkat(parent, temporary, 0) == 0, fsync(parent) == 0
        else { throw Failure.unsafeFile }
      } else if errno != ENOENT {
        throw Failure.unsafeFile
      }
      let descriptor = openat(
        parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw Failure.writeFailed }
      var removed = false
      defer {
        close(descriptor)
        if !removed { unlinkat(parent, temporary, 0) }
      }
      var written = 0
      var hash = RecoveryDigest.Stream()
      try produce { chunk in
        guard chunk.count <= bytes - written else { throw Failure.changedFile }
        try Self.write(descriptor, chunk, at: written)
        hash.update(chunk)
        written += chunk.count
      }
      let expected = Identity(bytes: written, sha256: hash.finish())
      guard written == bytes, fchmod(descriptor, mode) == 0, fsync(descriptor) == 0,
        try Self.identity(descriptor, owner: owner, maximum: bytes) == expected
      else { throw Failure.changedFile }
      // A hard link names the file only if nothing has that name yet; both
      // names are then flushed away to one.
      if linkat(parent, temporary, parent, leaf, 0) != 0 {
        guard errno == EEXIST else { throw Failure.writeFailed }
        let existing = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard existing >= 0 else { throw Failure.unsafeFile }
        defer { close(existing) }
        guard try Self.identity(existing, owner: owner, maximum: bytes) == expected else {
          throw Failure.changedFile
        }
      }
      removed = unlinkat(parent, temporary, 0) == 0
      guard removed, fsync(parent) == 0 else { throw Failure.writeFailed }
      return expected
    }

    /// The private name `path` is written under before it is published.
    static func temporaryName(namespace: String, path: String) -> String {
      ".aurora-stub-" + RecoveryDigest.sha256(Data(("restore-image-stub:" + namespace + ":" + path).utf8))
    }

    static func write(_ descriptor: Int32, _ data: Data, at offset: Int) throws {
      try data.withUnsafeBytes { buffer in
        var cursor = 0
        while cursor < buffer.count {
          let count = pwrite(
            descriptor, buffer.baseAddress!.advanced(by: cursor), buffer.count - cursor,
            off_t(offset + cursor))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw Failure.writeFailed }
          cursor += count
        }
      }
    }

    /// The size and SHA-256 of an opened regular file of `owner`'s, with one
    /// name, that no one else can write, read back from the file itself.
    static func identity(_ descriptor: Int32, owner: uid_t, maximum: Int) throws -> Identity {
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == owner, info.st_mode & 0o022 == 0, info.st_nlink == 1,
        info.st_size >= 0, info.st_size <= maximum
      else { throw Failure.unsafeFile }
      var hash = RecoveryDigest.Stream()
      var offset = 0
      var buffer = [UInt8](repeating: 0, count: 4 << 20)
      while offset < Int(info.st_size) {
        let want = min(buffer.count, Int(info.st_size) - offset)
        let got = buffer.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress, want, off_t(offset))
        }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { throw Failure.changedFile }
        hash.update(Data(buffer.prefix(got)))
        offset += got
      }
      var after = stat()
      guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
        modified(after) == modified(info)
      else { throw Failure.changedFile }
      return Identity(bytes: offset, sha256: hash.finish())
    }

    static func modified(_ info: stat) -> [Int] {
      #if canImport(Darwin)
        [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
      #else
        [Int(info.st_mtim.tv_sec), Int(info.st_mtim.tv_nsec)]
      #endif
    }
  }
}
