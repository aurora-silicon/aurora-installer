#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation

  /// A pinned directory, with every relative component opened without links.
  /// FAT contents are authenticated by bytes; System paths additionally require
  /// protected ownership and permissions before filename transitions.
  final class NativeHandoffFileTree: @unchecked Sendable {
    private let root: Int32
    private let protected: Bool
    private let owner: uid_t

    init(_ url: URL, protected: Bool, owner: uid_t = 0, volumeRoot: Bool = false,
      volumeDevice: String? = nil,
      verifyMount: @Sendable (Int32, URL, String) throws -> Void = NativeHandoffFileTree.verifyVolumeRoot) throws {
      self.protected = protected
      self.owner = owner
      let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw NativeHandoffValidationError.unsafePath }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        !protected || (info.st_uid == owner && info.st_mode & (volumeRoot ? 0o002 : 0o022) == 0) else {
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

    static func verifyVolumeRoot(_ fd: Int32, url: URL, device: String) throws {
      var filesystem = statfs(), opened = stat(), named = stat()
      func text<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) {
          $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
      }
      guard device.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil,
        fstatfs(fd, &filesystem) == 0, fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        text(&filesystem.f_mntfromname) == "/dev/" + device,
        text(&filesystem.f_mntonname) == url.path else { throw NativeHandoffValidationError.invalidTarget }
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
          !protected || (info.st_uid == owner && info.st_mode & 0o022 == 0 && info.st_nlink == 1)
        else { throw NativeHandoffValidationError.unsafePath }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var bytes = Data()
        while bytes.count < info.st_size {
          let chunk = try file.read(upToCount: min(4 << 20, Int(info.st_size) - bytes.count)) ?? Data()
          guard !chunk.isEmpty else { throw NativeHandoffValidationError.changedContent }
          bytes.append(chunk)
        }
        var after = stat()
        guard bytes.count == info.st_size, fstat(fd, &after) == 0,
          info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
          throw NativeHandoffValidationError.changedContent
        }
        return bytes
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

    func prepareForAuthorization() throws {
      try moveIfNeeded(active: "System/Library/CoreServices/SystemVersion.plist",
        inactive: "System/Library/CoreServices/SystemVersion-disabled.plist", activate: true)
    }

    func prepareForRecovery() throws {
      try moveIfNeeded(active: "System/Library/CoreServices/SystemVersion.plist",
        inactive: "System/Library/CoreServices/SystemVersion-disabled.plist", activate: false)
      try moveIfNeeded(active: ".IAPhysicalMedia", inactive: "IAPhysicalMedia-disabled.plist", activate: true)
    }

    private func moveIfNeeded(active: String, inactive: String, activate: Bool) throws {
      guard protected else { throw NativeHandoffValidationError.unsafePath }
      let activeAbsent = try isAbsent(active), inactiveAbsent = try isAbsent(inactive)
      guard activeAbsent != inactiveAbsent else { throw NativeHandoffValidationError.unsafePath }
      let source = activeAbsent ? inactive : active
      _ = try read(source, maximum: 65_536)
      let destination = activate ? active : inactive
      if source == destination { return }
      try withParent(source) { parent, leaf in
        try withParent(destination) { targetParent, targetLeaf in
          guard renameatx_np(parent, leaf, targetParent, targetLeaf, UInt32(RENAME_EXCL)) == 0,
            fsync(parent) == 0, fsync(targetParent) == 0 else {
            throw NativeHandoffValidationError.unsafePath
          }
        }
      }
    }

    private func withParent<T>(_ path: String, missingParent: Bool = false,
      _ body: (Int32, String) throws -> T) throws -> T {
      guard NativeHandoffEvidence.safeRelative(path) else { throw NativeHandoffValidationError.unsafePath }
      let parts = path.split(separator: "/").map(String.init)
      var current = dup(root)
      guard current >= 0 else { throw NativeHandoffValidationError.unsafePath }
      defer { close(current) }
      for component in parts.dropLast() {
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, missingParent, errno == ENOENT { return try body(-1, parts.last!) }
        guard next >= 0 else { throw NativeHandoffValidationError.unsafePath }
        var info = stat()
        guard fstat(next, &info) == 0,
          !protected || (info.st_uid == owner && info.st_mode & 0o022 == 0) else {
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
        info.st_size <= 128 << 30 else {
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
          let got = pread(descriptor, buffer.baseAddress!.advanced(by: consumed), count - consumed,
            off_t(offset + consumed))
          if got < 0 && errno == EINTR { continue }
          guard got > 0 else { throw NativeHandoffValidationError.changedContent }
          consumed += got
        }
      }
      var current = stat()
      guard fstat(descriptor, &current) == 0, current.st_size == identity.st_size,
        current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
        current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec else { throw NativeHandoffValidationError.changedContent }
      return bytes
    }
  }

  enum NativeHandoffRawReader {
    static func digest(partition: String, bytes: UInt64) throws -> String {
      guard partition.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil,
        bytes > 0, bytes <= 128 << 30 else { throw NativeHandoffValidationError.changedContent }
      let fd = open("/dev/r" + partition, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw NativeHandoffValidationError.changedContent }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else {
        throw NativeHandoffValidationError.changedContent
      }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var digest = SHA256(), remaining = bytes
      while remaining > 0 {
        try Task.checkCancellation()
        let chunk = try file.read(upToCount: Int(min(remaining, 4 << 20))) ?? Data()
        guard !chunk.isEmpty, chunk.count <= remaining else { throw NativeHandoffValidationError.changedContent }
        digest.update(data: chunk)
        remaining -= UInt64(chunk.count)
      }
      return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
