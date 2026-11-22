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

  static func head(_ path: String) -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else { fail("can't read \(path)") }
    defer { try? handle.close() }
    // Header, metadata (at most 1 MiB), salt and root header.
    return (try? handle.read(upToCount: 12 + 1024 * 1024 + 32 + 112)) ?? Data()
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
        guard let pem = FileManager.default.contents(atPath: arguments[2]) else {
          fail("can't read \(arguments[2])")
        }
        let key = try RestoreImageKey.unwrap(metadata, releaseKey: pem)
        // The key must open this archive, not only unwrap.
        try RestoreImageKey.authenticateRoot(archive, archiveKey: key)
        let descriptor = open(arguments[3], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
          fail("can't create \(arguments[3]): \(String(cString: strerror(errno)))")
        }
        let written = key.withUnsafeBytes { write(descriptor, $0.baseAddress, key.count) }
        guard written == key.count, fsync(descriptor) == 0, close(descriptor) == 0 else {
          unlink(arguments[3])
          fail("can't write \(arguments[3])")
        }
      default:
        fail(
          "usage: aurora-restore-key key-url ARCHIVE | unwrap ARCHIVE RELEASE_KEY_PEM OUTPUT", 64)
      }
    } catch {
      fail("\(error)")
    }
  }
}
