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
/// A top-level restore directory member that is an Apple Encrypted Archive
/// is decoded first, as the main installer does on macOS, and the Recovery
/// image, itself an Apple Encrypted Archive in current images, is decoded and
/// kept compressed (decmpfs type 12, as the main installer writes it and as
/// Apple's stubs keep it). Each archive is decoded as it streams in
/// (RestoreImageArchive: every header, segment MAC and segment SHA-256
/// checked before use) into the private file next to its destination, so no
/// plain copy is staged anywhere else; the Recovery image must also end in a
/// disk image trailer. The archive key comes from `archiveKey`, which gets the
/// member and its AEA metadata (`RestoreImageKey.keyURL` and `unwrap` open
/// it); without one, these files are left to the next step and returned in
/// `pending`, each with its place among the receipts. The installer's own files
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
    /// A decoded Recovery image doesn't end in a disk image (UDIF) trailer.
    case invalidImage
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
    owner: uid_t = geteuid(), chunkBytes: Int = RestoreImageDirectory.streamChunk,
    archiveKey: ((RestoreImageDirectory.Entry, [String: Data]) throws -> Data)? = nil
  ) throws {
    (installed, pending) = try withoutActuallyEscaping(read) { read in
      let writer = try Writer(
        plan: plan, directory: directory, read: read, roots: roots, group: group, owner: owner,
        chunkBytes: chunkBytes, archiveKey: archiveKey)
      try writer.write(roles: Set(Self.roles))
      return (writer.installed, writer.pending)
    }
  }

  /// One pass of the stub's files, all of them or only some volumes' (an
  /// in-place upgrade writes Preboot, then Recovery, then System). The
  /// receipts name each file where the plan puts it; `restoreDirectory` and
  /// `systemVersionPath` say where it is written instead, for an upgrade that
  /// builds the restore bundle beside the old one and keeps SystemVersion.plist
  /// where the launcher hid it. With `replaceSystemFiles`, a System file that
  /// holds other bytes is replaced (renamed over); elsewhere it stops the run.
  final class Writer {
    let plan: RestoreImageStubPlan
    let directory: RestoreImageDirectory
    let read: RestoreImageDirectory.Read
    let group: String
    let chunkBytes: Int
    let archiveKey: ((RestoreImageDirectory.Entry, [String: Data]) throws -> Data)?
    let trees: [String: Tree]
    let members: [String: RestoreImageDirectory.Entry]
    var restoreDirectory: String
    var systemVersionPath = RestoreImageStubFiles.systemVersionPath
    var replaceSystemFiles = false
    private(set) var installed = [Installed]()
    private(set) var pending = [Pending]()

    init(
      plan: RestoreImageStubPlan, directory: RestoreImageDirectory,
      read: @escaping RestoreImageDirectory.Read, roots: [String: URL], group: String,
      owner: uid_t, chunkBytes: Int,
      archiveKey: ((RestoreImageDirectory.Entry, [String: Data]) throws -> Data)?
    ) throws {
      guard Set(roots.keys) == Set(RestoreImageStubFiles.roles),
        let uuid = UUID(uuidString: group), uuid.uuidString == group
      else { throw Failure.invalidPlan }
      var trees = [String: Tree]()
      for role in RestoreImageStubFiles.roles {
        // recoveryOS starts the app and the aura command from the System
        // volume by path: its root is made the owner's alone, as the main
        // installer makes it (NativeHandoffFiles ownedVolumeRoot).
        trees[role] = try Tree(
          roots[role]!, owner: owner, namespace: group, ownedRoot: role == "System")
      }
      self.plan = plan
      self.directory = directory
      self.read = read
      self.group = group
      self.chunkBytes = chunkBytes
      self.archiveKey = archiveKey
      self.trees = trees
      members = Dictionary(uniqueKeysWithValues: directory.entries.map { ($0.name, $0) })
      restoreDirectory = plan.restorePath
    }

    func fullPath(_ role: String, _ path: String) -> String {
      role == "System" ? path : group + "/" + path
    }
    /// Where `path` of `role` is written: the restore bundle under
    /// `restoreDirectory`, the stub version at `systemVersionPath`.
    func writtenPath(_ role: String, _ path: String) -> String {
      let restore = Array((plan.restorePath + "/").utf8)
      if role == "Preboot", Array(path.utf8).starts(with: restore) {
        let rest = String(decoding: Array(path.utf8).dropFirst(restore.count), as: UTF8.self)
        return fullPath(role, restoreDirectory + "/" + rest)
      }
      if role == "System", path == RestoreImageStubFiles.systemVersionPath {
        return systemVersionPath
      }
      return fullPath(role, path)
    }
    func record(
      _ role: String, _ path: String, _ dataName: String?, link: String? = nil,
      _ write: (Tree, String) throws -> Identity
    ) throws {
      installed.append(
        Installed(
          role: role, path: fullPath(role, path), installerDataName: dataName,
          identity: try write(trees[role]!, writtenPath(role, path)), linkTarget: link))
    }
    func replacing(_ role: String) -> Bool { replaceSystemFiles && role == "System" }
    func copy(
      _ role: String, _ path: String, _ dataName: String?,
      _ entry: RestoreImageDirectory.Entry, compressed: Bool = false
    ) throws {
      try record(role, path, dataName) { tree, relative in
        try tree.publish(
          relative, bytes: entry.size, mode: 0o644, compressed: compressed,
          replacing: replacing(role)
        ) { append in
          try directory.stream(entry, chunkBytes: chunkBytes, read: read, consume: append)
        }
      }
    }
    /// An Apple Encrypted Archive member's plain image, decoded as it streams.
    func decode(
      _ role: String, _ path: String, _ dataName: String?,
      _ entry: RestoreImageDirectory.Entry, key: Data, diskImage: Bool
    ) throws {
      let prefix = try directory.appleEncryptedPrefix(entry, read: read)
      // The root header authenticates here, before any file is made.
      let size = try RestoreImageArchive.plainSize(
        prefix, archiveKey: key, archiveSize: entry.size)
      try record(role, path, dataName) { tree, relative in
        try tree.publish(
          relative, bytes: size, mode: 0o644, compressed: diskImage, replacing: replacing(role)
        ) { append in
          let decoder = try RestoreImageArchive.Decoder(archiveKey: key, archiveSize: entry.size)
          var tail = Data()
          try directory.stream(entry, chunkBytes: chunkBytes, read: read) { chunk in
            try decoder.consume(chunk) { plain in
              tail = Data((plain.count >= 512 ? plain : tail + plain).suffix(512))
              try append(plain)
            }
          }
          guard try decoder.finish().bytes == size else { throw Failure.changedFile }
          // As the main installer checks its decoded Recovery image: a UDIF trailer.
          if diskImage {
            guard tail.count == 512, tail.prefix(4) == Data("koly".utf8) else {
              throw Failure.invalidImage
            }
          }
        }
      }
    }
    func key(_ entry: RestoreImageDirectory.Entry) throws -> Data? {
      guard let archiveKey else { return nil }
      return try archiveKey(
        entry, RestoreImageKey.metadata(directory.appleEncryptedPrefix(entry, read: read)))
    }

    /// Writes the files of `roles`' volumes, in the main installer's order.
    func write(roles: Set<String>) throws {
      for operation in plan.copies where roles.contains(operation.role) {
        guard let entry = members[operation.member] else { throw Failure.invalidPlan }
        if let target = plan.linkTargets[operation.member] {
          // A link's receipt has no installer data name, as in the main installer.
          try record(operation.role, operation.path, nil, link: target) {
            try $0.link($1, target: target)
          }
        } else if plan.isTopLevelRestore(operation),
          try directory.isAppleEncryptedArchive(entry, read: read)
        {
          if let key = try key(entry) {
            try decode(
              operation.role, operation.path, operation.installerDataName, entry, key: key,
              diskImage: false)
            continue
          }
          pending.append(
            Pending(
              member: operation.member, role: operation.role, path: operation.path,
              installerDataName: operation.installerDataName, appleEncrypted: true,
              compressed: false, position: installed.count))
        } else {
          try copy(operation.role, operation.path, operation.installerDataName, entry)
        }
      }
      if roles.contains("Preboot") {
        try record("Preboot", plan.restorePath + "/BuildManifest.plist", "BuildManifest.plist") {
          try $0.data(plan.manifest, at: $1)
        }
      }
      if roles.contains("Recovery") {
        let recovery = plan.recoveryMember
        if !(try directory.isAppleEncryptedArchive(recovery, read: read)) {
          // An older image's Recovery image is a plain disk image: copied as it is, compressed.
          try copy(
            "Recovery", RestoreImageStubFiles.recoveryImagePath, nil, recovery, compressed: true)
        } else if let key = try key(recovery) {
          try decode(
            "Recovery", RestoreImageStubFiles.recoveryImagePath, nil, recovery, key: key,
            diskImage: true)
        } else {
          pending.append(
            Pending(
              member: recovery.name, role: "Recovery",
              path: RestoreImageStubFiles.recoveryImagePath, installerDataName: nil,
              appleEncrypted: true, compressed: true, position: installed.count))
        }
      }
      if roles.contains("System") {
        try record("System", RestoreImageStubFiles.systemVersionPath, "SystemVersion.plist") {
          try $0.data(plan.systemVersion, at: $1, replacing: replaceSystemFiles)
        }
      }
    }
  }

  /// A volume's tree, opened at its root, walked one directory at a time
  /// without following links.
  final class Tree {
    let root: Int32
    let owner: uid_t
    let namespace: String

    /// `url` is a mounted volume's root, which the caller has identified
    /// (RecoveryActions checks the volume mounted there).
    /// APFS makes a volume root root:admin 0775, so a root may let its group
    /// write when that group is wheel or admin; no one else may. With
    /// `ownedRoot`, a writable root is then made `owner`'s alone (mode 0755,
    /// group wheel) through the opened descriptor, and refused if it still
    /// lets another account write. Every directory below a root is checked
    /// strictly (`requireDirectory`).
    init(_ url: URL, owner: uid_t, namespace: String, ownedRoot: Bool = false) throws {
      root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      self.owner = owner
      self.namespace = namespace
      guard root >= 0 else { throw Failure.unsafeFile }
      try Self.requireVolumeRoot(root, owner: owner, owned: ownedRoot)
    }
    deinit { close(root) }

    /// The groups APFS gives a volume root: wheel and admin. A check run by
    /// another owner than root may also use its own group.
    static func rootGroupAdmitted(_ group: gid_t, owner: uid_t) -> Bool {
      group == 0 || group == 80 || (owner != 0 && group == getegid())
    }

    static func requireVolumeRoot(_ descriptor: Int32, owner: uid_t, owned: Bool) throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner, info.st_mode & 0o002 == 0,
        info.st_mode & 0o020 == 0 || rootGroupAdmitted(info.st_gid, owner: owner)
      else { throw Failure.unsafeFile }
      #if canImport(Darwin)
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
          filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
        else { throw Failure.unsafeFile }
      #endif
      guard owned else { return }
      #if canImport(Darwin)
        // No access-control entry may let another account write. (Which
        // volume is mounted at `url` the caller has checked.)
        guard !hasWriteACL(descriptor) else { throw Failure.unsafeFile }
        if filesystem.f_flags & UInt32(MNT_RDONLY) != 0 { return }
      #endif
      if info.st_mode & 0o022 == 0 { return }
      // root:wheel in Recovery; a check run by another owner can only give
      // a folder to one of its own groups.
      let group: gid_t = owner == 0 ? 0 : getegid()
      guard fchown(descriptor, owner, group) == 0, fchmod(descriptor, 0o755) == 0,
        fsync(descriptor) == 0, fstat(descriptor, &info) == 0, info.st_uid == owner,
        info.st_mode & 0o022 == 0
      else { throw Failure.unsafeFile }
    }

    #if canImport(Darwin)
      /// Whether `fd` has an extended access-control entry that lets anyone
      /// write, delete, add entries or change its mode, owner or list, as
      /// the main installer checks (NativeHandoffFiles.hasWriteACL). An
      /// unreadable list counts as one that does.
      static func hasWriteACL(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes: [acl_perm_t] = [
          ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
          ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
        ]
        var entry: acl_entry_t?
        var id = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, id, &entry) == 0, let current = entry {
          id = ACL_NEXT_ENTRY.rawValue
          var tag = ACL_UNDEFINED_TAG
          var permissions: acl_permset_t?
          guard acl_get_tag_type(current, &tag) == 0, acl_get_permset(current, &permissions) == 0,
            let permissions
          else { return true }
          if tag == ACL_EXTENDED_ALLOW,
            writes.contains(where: { acl_get_perm_np(permissions, $0) != 0 })
          {
            return true
          }
        }
        return false
      }
    #endif

    /// A directory of `owner`'s that no one else can write.
    static func requireDirectory(_ descriptor: Int32, owner: uid_t) throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner, info.st_mode & 0o022 == 0
      else { throw Failure.unsafeFile }
    }

    /// The opened parent directory of `path`, made as needed (or, without
    /// `create`, nil when a directory on the way is missing), and its leaf.
    func parent(_ path: String) throws -> (Int32, String) {
      guard let found = try parent(path, create: true) else { throw Failure.writeFailed }
      return found
    }

    func parent(_ path: String, create: Bool) throws -> (Int32, String)? {
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
        if next < 0 && errno == ENOENT && !create {
          close(current)
          return nil
        }
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

    func data(
      _ data: Data, at path: String, mode: mode_t = 0o644, replacing: Bool = false
    ) throws -> Identity {
      try publish(path, bytes: data.count, mode: mode, replacing: replacing) { try $0(data) }
    }

    /// Removes the regular file of `owner`'s at `path`, which has one name,
    /// and flushes its directory. Returns false when there is no such file.
    @discardableResult func remove(_ path: String) throws -> Bool {
      guard let (parent, leaf) = try self.parent(path, create: false) else { return false }
      defer { close(parent) }
      var info = stat()
      guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        guard errno == ENOENT else { throw Failure.unsafeFile }
        return false
      }
      guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_nlink == 1 else {
        throw Failure.unsafeFile
      }
      guard unlinkat(parent, leaf, 0) == 0, fsync(parent) == 0 else { throw Failure.writeFailed }
      return true
    }

    /// Whether `path` names anything, without following a link at its end.
    func exists(_ path: String) throws -> Bool {
      guard let (parent, leaf) = try self.parent(path, create: false) else { return false }
      defer { close(parent) }
      var info = stat()
      if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
      guard errno == ENOENT else { throw Failure.unsafeFile }
      return false
    }

    /// The target of the link of `owner`'s at `path`; nil when nothing is there.
    func linkTarget(_ path: String) throws -> String? {
      guard let (parent, leaf) = try self.parent(path, create: false) else { return nil }
      defer { close(parent) }
      var info = stat()
      guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        guard errno == ENOENT else { throw Failure.unsafeFile }
        return nil
      }
      var buffer = [CChar](repeating: 0, count: 4097)
      let count = readlinkat(parent, leaf, &buffer, 4096)
      guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == owner, count >= 0 else {
        throw Failure.unsafeFile
      }
      return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A link at `path` to `target`, replacing a link of `owner`'s that
    /// points elsewhere by a rename (never a file or a directory).
    func relink(_ path: String, target: String) throws -> Identity {
      if let current = try linkTarget(path), current != target {
        let (parent, leaf) = try self.parent(path)
        defer { close(parent) }
        let temporary = Self.temporaryName(namespace: namespace, path: path)
        if unlinkat(parent, temporary, 0) != 0 && errno != ENOENT { throw Failure.unsafeFile }
        guard symlinkat(target, parent, temporary) == 0 else { throw Failure.writeFailed }
        guard renameat(parent, temporary, parent, leaf) == 0 else {
          unlinkat(parent, temporary, 0)
          throw Failure.writeFailed
        }
        guard fsync(parent) == 0 else { throw Failure.writeFailed }
      }
      return try link(path, target: target)
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
    /// file, checks and flushes it, then names it `path`. A file already
    /// there with the same bytes is adopted; one with other bytes stops the
    /// run, or with `replacing` (a regular file of `owner`'s with one name)
    /// is replaced by renaming the private file over it.
    /// With `compressed`, the bytes go to the resource fork as decmpfs type 12
    /// (RestoreImageResourceFork) and are checked through APFS's own
    /// decompressed read. Linux has no decmpfs; there, where only the
    /// fixture checks run, they are written as they are.
    func publish(
      _ path: String, bytes: Int, mode: mode_t, compressed: Bool = false, replacing: Bool = false,
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
      var fork: RestoreImageResourceFork?
      var resource: Int32 = -1
      defer { if resource >= 0 { close(resource) } }
      #if canImport(Darwin)
        if compressed {
          resource = try Self.resourceFork(descriptor)
          let target = resource
          fork = try RestoreImageResourceFork(bytes: bytes) { try Self.write(target, $0, at: $1) }
        }
      #endif
      var written = 0
      var hash = RecoveryDigest.Stream()
      try produce { chunk in
        guard chunk.count <= bytes - written else { throw Failure.changedFile }
        if let fork {
          try fork.append(chunk)
        } else {
          try Self.write(descriptor, chunk, at: written)
        }
        hash.update(chunk)
        written += chunk.count
      }
      guard written == bytes else { throw Failure.changedFile }
      #if canImport(Darwin)
        if let fork {
          try fork.finish()
          guard fsync(resource) == 0 else { throw Failure.writeFailed }
          close(resource)
          resource = -1
          let attribute = RestoreImageResourceFork.attribute(bytes: bytes)
          let status = attribute.withUnsafeBytes {
            fsetxattr(
              descriptor, "com.apple.decmpfs", $0.baseAddress, attribute.count, 0, XATTR_CREATE)
          }
          guard status == 0, fchflags(descriptor, UInt32(UF_COMPRESSED)) == 0 else {
            throw Failure.writeFailed
          }
        }
      #endif
      let expected = Identity(bytes: written, sha256: hash.finish())
      guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0,
        try Self.identity(descriptor, owner: owner, maximum: bytes) == expected
      else { throw Failure.changedFile }
      // A hard link names the file only if nothing has that name yet; both
      // names are then flushed away to one.
      if linkat(parent, temporary, parent, leaf, 0) != 0 {
        guard errno == EEXIST else { throw Failure.writeFailed }
        let existing = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard existing >= 0 else { throw Failure.unsafeFile }
        defer { close(existing) }
        let found = try Self.identity(
          existing, owner: owner,
          maximum: replacing ? RestoreImageDirectory.maximumMember : bytes)
        if found != expected {
          guard replacing else { throw Failure.changedFile }
          // One rename: the old file or the new one has the name, never neither.
          guard renameat(parent, temporary, parent, leaf) == 0 else { throw Failure.writeFailed }
          removed = true
          guard fsync(parent) == 0 else { throw Failure.writeFailed }
          return expected
        }
      }
      removed = unlinkat(parent, temporary, 0) == 0
      guard removed, fsync(parent) == 0 else { throw Failure.writeFailed }
      return expected
    }

    #if canImport(Darwin)
      /// The resource fork of the opened private file, as the main installer
      /// opens it: by the file's path, then checked to be the same file.
      static func resourceFork(_ descriptor: Int32) throws -> Int32 {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw Failure.unsafeFile }
        let resource = open(
          String(cString: path) + "/..namedfork/rsrc", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
          0o600)
        var original = stat()
        var fork = stat()
        guard resource >= 0, fstat(descriptor, &original) == 0, fstat(resource, &fork) == 0,
          original.st_ino == fork.st_ino, original.st_dev == fork.st_dev, fork.st_size == 0
        else {
          if resource >= 0 { close(resource) }
          throw Failure.unsafeFile
        }
        return resource
      }
    #endif

    /// The private name `path` is written under before it is published.
    static func temporaryName(namespace: String, path: String) -> String {
      let key = "restore-image-stub:" + namespace + ":" + path
      return ".aurora-stub-" + RecoveryDigest.sha256(Data(key.utf8))
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
