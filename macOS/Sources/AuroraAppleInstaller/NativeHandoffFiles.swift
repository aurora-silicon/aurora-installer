#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation

  /// What the source-owner read found at one component of its path, as a
  /// log line: kind, owner, mode, links, size and file flags. Display only.
  struct SourceOwnerMetadataComponent: Equatable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let uid: uid_t
    let gid: gid_t
    let mode: mode_t
    let links: nlink_t
    let size: off_t
    let flags: UInt32

    init(_ name: String, _ info: stat) {
      self.name = name
      kind = Self.kind(info.st_mode)
      uid = info.st_uid
      gid = info.st_gid
      mode = info.st_mode
      links = info.st_nlink
      size = info.st_size
      flags = info.st_flags
    }

    var octalMode: String {
      let digits = String(mode & 0o7777, radix: 8)
      return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    var description: String {
      "\(name): \(kind), owner \(uid):\(gid), mode \(octalMode), "
        + "\(links) link\(links == 1 ? "" : "s"), \(size) bytes, flags 0x\(String(flags, radix: 16))"
    }

    static func kind(_ mode: mode_t) -> String {
      switch mode & S_IFMT {
      case S_IFDIR: "folder"
      case S_IFREG: "file"
      case S_IFLNK: "symbolic link"
      case S_IFIFO: "named pipe"
      case S_IFSOCK: "socket"
      case S_IFCHR, S_IFBLK: "device"
      default: "special file"
      }
    }
  }

  /// The source-owner read refused one component. `reason` is short enough
  /// for the shown summary; `found` is what was there, for the log.
  struct SourceOwnerMetadataRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String
    let found: SourceOwnerMetadataComponent?
    /// True when a component does not exist: the list is absent, which
    /// macOS can recreate, rather than unsafe.
    let missing: Bool

    init(_ reason: String, _ found: SourceOwnerMetadataComponent?, missing: Bool = false) {
      self.reason = reason
      self.found = found
      self.missing = missing
    }

    var description: String { found.map { "\(reason) [\($0)]" } ?? reason }

    /// A component that could not be opened without following a link: say
    /// what is there instead, read without following it.
    static func unopened(
      _ name: String, errno code: Int32, parent: Int32, leaf: String,
      trace: (SourceOwnerMetadataComponent) -> Void
    ) -> Self {
      var info = stat()
      guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { return Self("\(name) is missing", nil, missing: true) }
        return Self("\(name) could not be examined (\(String(cString: strerror(code))))", nil)
      }
      let found = SourceOwnerMetadataComponent(name == "the file" ? leaf : name, info)
      trace(found)
      if info.st_mode & S_IFMT == S_IFLNK { return Self("\(name) is a symbolic link", found) }
      if code == ENOTDIR { return Self("\(name) is a \(found.kind), not a folder", found) }
      return Self("\(name) could not be opened (\(String(cString: strerror(code))))", found)
    }
  }

  /// A pinned directory, with every relative component opened without links.
  /// FAT contents are authenticated by bytes; System paths additionally require
  /// protected ownership and permissions before filename transitions.
  final class NativeHandoffFileTree: @unchecked Sendable {
    private let root: Int32
    private let protected: Bool
    private let owner: uid_t
    private let verifiedVolumeRoot: Bool
    /// Files in a hash-verified image may carry several names. Such a file is
    /// read only when its own filesystem is mounted read-only, where no link
    /// can be added; the single-link rule still guards every writable volume.
    private let readOnlyVolume: Bool

    init(
      _ url: URL, protected: Bool, owner: uid_t = 0, volumeRoot: Bool = false,
      volumeDevice: String? = nil, readOnlyVolume: Bool = false,
      verifyMount: @Sendable (Int32, URL, String) throws -> Void = NativeHandoffFileTree
        .verifyVolumeRoot
    ) throws {
      self.protected = protected
      self.owner = owner
      self.readOnlyVolume = readOnlyVolume
      verifiedVolumeRoot = volumeRoot
      let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw NativeHandoffValidationError.unsafePath }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        !protected || (info.st_uid == owner && info.st_mode & (volumeRoot ? 0o002 : 0o022) == 0)
      else {
        close(descriptor)
        throw NativeHandoffValidationError.unsafePath
      }
      do {
        if volumeRoot {
          guard let volumeDevice else { throw NativeHandoffValidationError.invalidTarget }
          try verifyMount(descriptor, url, volumeDevice)
        }
      } catch {
        close(descriptor)
        throw error
      }
      root = descriptor
    }
    deinit { close(root) }

    static func isReadOnly(_ fd: Int32) -> Bool {
      var filesystem = statfs()
      return fstatfs(fd, &filesystem) == 0 && filesystem.f_flags & UInt32(MNT_RDONLY) != 0
    }

    static func verifyVolumeRoot(_ fd: Int32, url: URL, device: String) throws {
      var filesystem = statfs()
      var opened = stat()
      var named = stat()
      func text<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) {
          $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
          }
        }
      }
      guard device.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil,
        fstatfs(fd, &filesystem) == 0, fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        text(&filesystem.f_mntfromname) == "/dev/" + device,
        text(&filesystem.f_mntonname) == url.path
      else { throw NativeHandoffValidationError.invalidTarget }
    }

    static let sourceOwnerMetadataMaximum = 1 << 20

    /// Reads macOS's list of Recovery administrators,
    /// `<group>/var/db/AdminUserRecoveryInfo.plist`, from the verified source
    /// Preboot volume.
    ///
    /// macOS leaves folders on this path writable by every local user: the
    /// group folder on macOS 26 (0777), `var` and `var/db` on macOS 27.2
    /// (both 0777, no sticky bit). The read therefore does not trust folder
    /// modes. What a local user who is not root can do in such a folder is
    /// add, remove and rename entries, and create symbolic links and hard
    /// links; they cannot create anything owned by root, change root's
    /// files or folders, or move anything across volumes. So:
    ///
    /// - every component is opened from the one before with `O_NOFOLLOW`
    ///   and checked with `fstat` on the opened descriptor, so a symbolic
    ///   link, or a swap after the check, cannot redirect the read;
    /// - every folder must be owned by root, whatever its mode, so a folder
    ///   a user made cannot stand in;
    /// - the file must be a root-owned regular file that no one else can
    ///   write, so its bytes are root's;
    /// - when the file's own folder is writable by others (sticky or not),
    ///   it must have exactly one name, since anyone can add a hard link
    ///   there to any root-owned file on the volume. Under a folder only
    ///   root can write, only root could have made a second name.
    ///
    /// A user can still remove the file (the list then reads as missing,
    /// which macOS rebuilds) or rename into its place another root-owned
    /// single-name file that already sits in a writable folder on the same
    /// Preboot, such as another group's list or `AllUsersInfo.plist`. Its
    /// contents are still root's: the caller reads only the authorized
    /// account's entry, keyed by its short name, and requires its
    /// GeneratedUID, and the account is proven an administrator and an APFS
    /// volume owner separately. No layout lets a user write the list.
    ///
    /// `trace` is told what was found at each component, for the log. A
    /// refusal is a `SourceOwnerMetadataRefusal` naming the component and
    /// the rule; other errors are the generic path errors.
    func sourceOwnerMetadata(
      groupUUID: String, trace: (SourceOwnerMetadataComponent) -> Void = { _ in }
    ) throws -> Data {
      guard protected, verifiedVolumeRoot,
        UUID(uuidString: groupUUID)?.uuidString == groupUUID
      else { throw NativeHandoffValidationError.unsafePath }
      let folders = [groupUUID, "var", "db"]
      var current = dup(root)
      guard current >= 0 else { throw NativeHandoffValidationError.unsafePath }
      defer { close(current) }
      var parentProtected = false
      for (index, component) in folders.enumerated() {
        let name = index == 0 ? "<group>" : folders[1...index].joined(separator: "/")
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else {
          throw SourceOwnerMetadataRefusal.unopened(
            name, errno: errno, parent: current, leaf: component, trace: trace)
        }
        var info = stat()
        guard fstat(next, &info) == 0 else {
          close(next)
          throw NativeHandoffValidationError.unsafePath
        }
        let found = SourceOwnerMetadataComponent(name, info)
        trace(found)
        if info.st_uid != owner {
          close(next)
          throw SourceOwnerMetadataRefusal(
            "\(name) is not owned by root (owner \(info.st_uid))", found)
        }
        parentProtected = info.st_mode & 0o022 == 0
        close(current)
        current = next
      }
      let leaf = "AdminUserRecoveryInfo.plist"
      let fd = openat(current, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else {
        throw SourceOwnerMetadataRefusal.unopened(
          "the file", errno: errno, parent: current, leaf: leaf, trace: trace)
      }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw NativeHandoffValidationError.unsafePath }
      let found = SourceOwnerMetadataComponent(leaf, info)
      trace(found)
      let problem: String? =
        if info.st_mode & S_IFMT != S_IFREG {
          "the file is a \(found.kind), not a regular file"
        } else if info.st_size < 0 || info.st_size > Self.sourceOwnerMetadataMaximum {
          "the file is larger than 1 MB (\(info.st_size) bytes)"
        } else if info.st_uid != owner {
          "the file is not owned by root (owner \(info.st_uid))"
        } else if info.st_mode & 0o022 != 0 {
          "the file is writable by other users (mode \(found.octalMode))"
        } else if info.st_nlink != 1, !parentProtected,
          !(readOnlyVolume && Self.isReadOnly(fd))
        {
          "the file has \(info.st_nlink) hard links in a folder others can write"
        } else {
          nil
        }
      if let problem { throw SourceOwnerMetadataRefusal(problem, found) }
      do {
        return try Self.readWhole(fd, info)
      } catch {
        throw SourceOwnerMetadataRefusal("the file changed while it was read", found)
      }
    }

    /// Reads an opened regular file of `info.st_size` bytes and proves its
    /// size and modification time did not change meanwhile.
    private static func readWhole(_ fd: Int32, _ info: stat) throws -> Data {
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var bytes = Data()
      while bytes.count < info.st_size {
        let chunk =
          try file.read(upToCount: min(4 << 20, Int(info.st_size) - bytes.count)) ?? Data()
        guard !chunk.isEmpty else { throw NativeHandoffValidationError.changedContent }
        bytes.append(chunk)
      }
      var after = stat()
      guard bytes.count == info.st_size, fstat(fd, &after) == 0,
        info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      else {
        throw NativeHandoffValidationError.changedContent
      }
      return bytes
    }

    func read(_ path: String, maximum: Int) throws -> Data {
      guard maximum >= 0, maximum <= 64 << 20 else { throw NativeHandoffValidationError.unsafePath }
      return try withParent(path) { parent, leaf in
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NativeHandoffValidationError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= maximum,
          !protected
            || (info.st_uid == owner && info.st_mode & 0o022 == 0
              && (info.st_nlink == 1 || (readOnlyVolume && Self.isReadOnly(fd))))
        else { throw NativeHandoffValidationError.unsafePath }
        return try Self.readWhole(fd, info)
      }
    }

    func isAbsent(_ path: String) throws -> Bool {
      try withParent(path, missingParent: true) { parent, leaf in
        if parent < 0 { return true }
        var info = stat()
        if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw NativeHandoffValidationError.unsafePath }
        return true
      }
    }

    /// The caller owns the returned descriptor across an asynchronous write.
    func writableParent(_ path: String) throws -> (Int32, String) {
      try withParent(path, createParents: true) { parent, leaf in
        let descriptor = dup(parent)
        guard descriptor >= 0 else { throw NativeHandoffValidationError.unsafePath }
        return (descriptor, leaf)
      }
    }

    func createDirectory(_ path: String) throws {
      let (parent, _) = try writableParent(path + "/.directory-check")
      defer { close(parent) }
    }

    func fileDescriptor(_ path: String) throws -> Int32 {
      try withParent(path) { parent, leaf in
        let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NativeHandoffValidationError.unsafePath }
        return descriptor
      }
    }

    func link(_ path: String, destination: String, admittedRoot: URL) throws {
      guard protected, destination.hasPrefix(admittedRoot.path + "/") else {
        throw NativeHandoffValidationError.unsafePath
      }
      try withParent(path, createParents: true) { parent, leaf in
        if symlinkat(destination, parent, leaf) != 0 {
          guard errno == EEXIST else { throw NativeHandoffValidationError.unsafePath }
          var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
          let length = readlinkat(parent, leaf, &bytes, bytes.count)
          guard length == destination.utf8.count,
            String(decoding: bytes.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
              == destination
          else { throw NativeHandoffValidationError.unsafePath }
        }
        guard fsync(parent) == 0 else { throw NativeHandoffValidationError.unsafePath }
      }
    }

    /// Publish only a relative, traversal-free target admitted by the restore
    /// plan. Parents are pinned without following links, including on retries.
    func relativeLink(_ path: String, target: String) throws {
      guard protected, NativeHandoffEvidence.safeRelative(target) else {
        throw NativeHandoffValidationError.unsafePath
      }
      try withParent(path, createParents: true) { parent, leaf in
        if symlinkat(target, parent, leaf) != 0 && errno != EEXIST {
          throw NativeHandoffValidationError.unsafePath
        }
        guard try relativeLinkTarget(parent: parent, leaf: leaf) == target, fsync(parent) == 0
        else { throw NativeHandoffValidationError.unsafePath }
      }
    }

    func relativeLinkTarget(_ path: String) throws -> String {
      try withParent(path) { try relativeLinkTarget(parent: $0, leaf: $1) }
    }

    private func relativeLinkTarget(parent: Int32, leaf: String) throws -> String {
      var info = stat()
      var bytes = [UInt8](repeating: 0, count: 4097)
      let count = readlinkat(parent, leaf, &bytes, bytes.count)
      guard protected, fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFLNK, info.st_uid == owner, info.st_nlink == 1,
        count > 0, count <= 4096,
        let target = String(bytes: bytes.prefix(count), encoding: .utf8),
        NativeHandoffEvidence.safeRelative(target)
      else { throw NativeHandoffValidationError.unsafePath }
      return target
    }

    func prepareForAuthorization() throws {
      try moveIfNeeded(
        active: "System/Library/CoreServices/SystemVersion.plist",
        inactive: "System/Library/CoreServices/SystemVersion-disabled.plist", activate: true)
    }

    func handoffVersion() throws -> Data {
      let version = try existing(
        active: "System/Library/CoreServices/SystemVersion.plist",
        inactive: "System/Library/CoreServices/SystemVersion-disabled.plist")
      _ = try existing(active: ".IAPhysicalMedia", inactive: "IAPhysicalMedia-disabled.plist")
      return try read(version, maximum: 65_536)
    }

    func prepareForRecovery() throws {
      try moveIfNeeded(
        active: "System/Library/CoreServices/SystemVersion.plist",
        inactive: "System/Library/CoreServices/SystemVersion-disabled.plist", activate: false)
      try moveIfNeeded(
        active: ".IAPhysicalMedia", inactive: "IAPhysicalMedia-disabled.plist", activate: true)
    }

    /// The reverse of `prepareForRecovery`: the volume starts its enrolled
    /// Stage 1 again instead of opening Aurora Installer in Recovery.
    func prepareForStartup() throws {
      try moveIfNeeded(
        active: ".IAPhysicalMedia", inactive: "IAPhysicalMedia-disabled.plist", activate: false)
      try prepareForAuthorization()
    }

    private func moveIfNeeded(active: String, inactive: String, activate: Bool) throws {
      guard protected else { throw NativeHandoffValidationError.unsafePath }
      let source = try existing(active: active, inactive: inactive)
      let destination = activate ? active : inactive
      if source == destination { return }
      if try !isAbsent(destination) {
        // An identical pair: the destination already holds the bytes.
        try withParent(source) { parent, leaf in
          guard unlinkat(parent, leaf, 0) == 0, fsync(parent) == 0 else {
            throw NativeHandoffValidationError.unsafePath
          }
        }
        return
      }
      try withParent(source) { parent, leaf in
        try withParent(destination) { targetParent, targetLeaf in
          guard renameatx_np(parent, leaf, targetParent, targetLeaf, UInt32(RENAME_EXCL)) == 0,
            fsync(parent) == 0, fsync(targetParent) == 0
          else {
            throw NativeHandoffValidationError.unsafePath
          }
        }
      }
    }

    /// The deferred Recovery launcher restores the media marker by copying its
    /// disabled name, so both names may exist when they hold identical bytes.
    /// The active name is then the current one.
    private func existing(active: String, inactive: String) throws -> String {
      let activeAbsent = try isAbsent(active)
      let inactiveAbsent = try isAbsent(inactive)
      guard !activeAbsent || !inactiveAbsent else { throw NativeHandoffValidationError.unsafePath }
      let source = activeAbsent ? inactive : active
      let bytes = try read(source, maximum: 65_536)
      guard !bytes.isEmpty else { throw NativeHandoffValidationError.unsafePath }
      if !activeAbsent, !inactiveAbsent, try read(inactive, maximum: 65_536) != bytes {
        throw NativeHandoffValidationError.unsafePath
      }
      return source
    }

    private func withParent<T>(
      _ path: String, missingParent: Bool = false, createParents: Bool = false,
      _ body: (Int32, String) throws -> T
    ) throws -> T {
      guard NativeHandoffEvidence.safeRelative(path) else {
        throw NativeHandoffValidationError.unsafePath
      }
      let parts = path.split(separator: "/").map(String.init)
      var current = dup(root)
      guard current >= 0 else { throw NativeHandoffValidationError.unsafePath }
      defer { close(current) }
      for component in parts.dropLast() {
        var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, createParents, errno == ENOENT {
          guard mkdirat(current, component, 0o755) == 0 else {
            throw NativeHandoffValidationError.unsafePath
          }
          next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          guard next >= 0, fchmod(next, 0o755) == 0, fsync(current) == 0 else {
            if next >= 0 { close(next) }
            throw NativeHandoffValidationError.unsafePath
          }
        }
        if next < 0, missingParent, errno == ENOENT { return try body(-1, parts.last!) }
        guard next >= 0 else { throw NativeHandoffValidationError.unsafePath }
        var info = stat()
        guard fstat(next, &info) == 0,
          !protected || (info.st_uid == owner && info.st_mode & 0o022 == 0)
        else {
          close(next)
          throw NativeHandoffValidationError.unsafePath
        }
        close(current)
        current = next
      }
      return try body(current, parts.last!)
    }
  }

  final class NativePayloadRangeReader: FirmwareRangeReading, @unchecked Sendable {
    let sizeBytes: Int
    private let descriptor: Int32
    private let identity: stat

    init(_ url: URL, owner: uid_t = 0) throws {
      let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw NativeHandoffValidationError.unsafePath }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
        info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size >= 22,
        info.st_size <= 128 << 30
      else {
        close(fd)
        throw NativeHandoffValidationError.unsafePath
      }
      descriptor = fd
      identity = info
      sizeBytes = Int(info.st_size)
    }
    deinit { close(descriptor) }

    func read(offset: Int, count: Int) async throws -> Data {
      try Task.checkCancellation()
      guard offset >= 0, count > 0, count <= 8 << 20, offset <= sizeBytes - count else {
        throw NativeHandoffValidationError.changedContent
      }
      var bytes = Data(count: count)
      try bytes.withUnsafeMutableBytes { buffer in
        var consumed = 0
        while consumed < count {
          let got = pread(
            descriptor, buffer.baseAddress!.advanced(by: consumed), count - consumed,
            off_t(offset + consumed))
          if got < 0 && errno == EINTR { continue }
          guard got > 0 else { throw NativeHandoffValidationError.changedContent }
          consumed += got
        }
      }
      var current = stat()
      guard fstat(descriptor, &current) == 0, current.st_size == identity.st_size,
        current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
        current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec
      else { throw NativeHandoffValidationError.changedContent }
      return bytes
    }
  }

  enum NativeHandoffRawReader {
    static func digest(partition: String, bytes: UInt64) throws -> String {
      guard partition.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil,
        bytes > 0, bytes <= 128 << 30
      else { throw NativeHandoffValidationError.changedContent }
      let fd = open("/dev/r" + partition, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw NativeHandoffValidationError.changedContent }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else {
        throw NativeHandoffValidationError.changedContent
      }
      return try digest(descriptor: fd, bytes: bytes)
    }

    /// Read the complete image into one reusable aligned buffer. A synchronous
    /// raw-device read must not retain every chunk until the XPC call returns.
    static func digest(descriptor: Int32, bytes: UInt64) throws -> String {
      guard bytes > 0, bytes <= 128 << 30 else {
        throw NativeHandoffValidationError.changedContent
      }
      let chunkSize = 4 << 20
      let scratch = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
      defer { scratch.deallocate() }
      var digest = SHA256()
      var offset: UInt64 = 0
      while offset < bytes {
        try Task.checkCancellation()
        let requested = Int(min(bytes - offset, UInt64(chunkSize)))
        let count = pread(descriptor, scratch, requested, off_t(offset))
        if count < 0 && errno == EINTR { continue }
        guard count > 0, count <= requested else {
          throw NativeHandoffValidationError.changedContent
        }
        digest.update(bufferPointer: UnsafeRawBufferPointer(start: scratch, count: count))
        offset += UInt64(count)
      }
      return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
