import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// `aurora-restore-key`: the archive key of a restore image's Apple Encrypted
/// Archive, without CryptoKit, for recoveryOS (see RestoreImageKey).
///
///     aurora-restore-key key-url ARCHIVE
///     aurora-restore-key unwrap ARCHIVE RELEASE_KEY_PEM OUTPUT
///
/// ARCHIVE needs only the archive's first bytes (header, metadata, salt and
/// root header). `key-url` prints where its private key is fetched from;
/// `unwrap` writes the 32-byte archive key that `aea decrypt -key` takes to a
/// new file OUTPUT (mode 0600, never replacing one) once it authenticates the
/// archive's root header. Exit 64 is a usage error.
@main struct RestoreImageKeyTool {
  static func fail(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("aurora-restore-key: " + message + "\n").utf8))
    exit(status)
  }

  /// At most `limit` bytes from the start of `path`; a read error is
  /// reported, not taken for a short file.
  static func read(_ path: String, limit: Int) -> Data {
    do {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      return try handle.read(upToCount: limit) ?? Data()
    } catch {
      fail("can't read \(path): \(error.localizedDescription)")
    }
  }

  /// Header, metadata (at most 1 MiB), salt and root header.
  static func head(_ path: String) -> Data { read(path, limit: 12 + 1024 * 1024 + 32 + 112) }

  /// The release key PEM: a P-256 PKCS#8 key is a few hundred bytes; the
  /// restore image helper caps the same download at 16 KiB.
  static func releaseKey(_ path: String) -> Data {
    let pem = read(path, limit: 16384 + 1)
    guard pem.count <= 16384 else { fail("\(path) is larger than a release key (16 KiB)") }
    return pem
  }

  /// Writes all of `bytes` to a new file at `path` (mode 0600; an existing
  /// file or symlink there is refused) and syncs it; on any failure the
  /// file is removed if it is still the one created here.
  static func create(_ path: String, _ bytes: Data) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { fail("can't create \(path): \(String(cString: strerror(errno)))") }
    var created = stat()
    guard fstat(descriptor, &created) == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      fail("can't create \(path): \(reason) (an empty file may be left)")
    }
    /// Removes `path` only while it is still the file this created.
    func remove() {
      var now = stat()
      if lstat(path, &now) == 0, now.st_dev == created.st_dev, now.st_ino == created.st_ino {
        unlink(path)
      }
    }
    func abandon(_ what: String) -> Never {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      remove()
      fail("can't \(what) \(path): \(reason)")
    }
    var done = 0
    while done < bytes.count {
      let written = bytes.withUnsafeBytes {
        write(descriptor, $0.baseAddress! + done, bytes.count - done)
      }
      if written < 0 {
        if errno == EINTR { continue }
        abandon("write")
      }
      if written == 0 {
        errno = EIO
        abandon("write")
      }
      done += written
    }
    guard fsync(descriptor) == 0 else { abandon("sync") }
    guard close(descriptor) == 0 else {
      let reason = String(cString: strerror(errno))
      remove()
      fail("can't close \(path): \(reason)")
    }
  }

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch arguments.first {
      case "key-url" where arguments.count == 2:
        print(
          try RestoreImageKey.keyURL(RestoreImageKey.metadata(head(arguments[1]))).absoluteString)
      case "unwrap" where arguments.count == 4:
        let archive = head(arguments[1])
        let metadata = try RestoreImageKey.metadata(archive)
        let key = try RestoreImageKey.unwrap(metadata, releaseKey: releaseKey(arguments[2]))
        // The key must open this archive, not only unwrap.
        try RestoreImageKey.authenticateRoot(archive, archiveKey: key)
        create(arguments[3], key)
      default:
        fail(
          "usage: aurora-restore-key key-url ARCHIVE | unwrap ARCHIVE RELEASE_KEY_PEM OUTPUT", 64)
      }
    } catch {
      fail("\(error)")
    }
  }
}
