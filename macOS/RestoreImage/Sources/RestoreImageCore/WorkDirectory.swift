// SPDX-License-Identifier: MIT
import Darwin
import Foundation

/// A private workspace with a process lease. A decoder inherits the same open
/// file description on stdin, so killing the parent cannot make live work stale.
final class RestoreWorkspace {
  let url: URL
  let lease: FileHandle
  private static let prefix = ".omarchy-restore-"
  private static let marker = Data("omarchy-restore-workspace-v1\n".utf8)

  init(beside output: URL) throws {
    Self.removeAbandoned(beside: output)
    let directory = try privateDirectory(beside: output, prefix: Self.prefix)
    let path = directory.appendingPathComponent(".lease")
    let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw RestoreFailure("Cannot create restore workspace lease.")
    }
    url = directory
    lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "Cannot lock restore workspace.")
      try writePrivate(Self.marker, to: url.appendingPathComponent(".workspace"))
    } catch {
      try? lease.close()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  deinit {
    // Keep the lease held through cleanup. Children have finished before a
    // successful run returns; after SIGKILL the next invocation owns cleanup.
    try? FileManager.default.removeItem(at: url)
    try? lease.close()
  }

  static func removeAbandoned(beside output: URL) {
    let parent = output.deletingLastPathComponent()
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
    else { return }
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(prefix) else { continue }
      let suffix = name.dropFirst(prefix.count)
      guard
        suffix.count == 6
          && suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          })
      else { continue }
      var before = stat()
      guard lstat(entry.path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
        before.st_uid == geteuid(), before.st_mode & 0o777 == 0o700,
        (try? readRegular(entry.appendingPathComponent(".workspace"), maximum: 128)) == marker
      else { continue }
      let fd = open(
        entry.appendingPathComponent(".lease").path,
        O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { continue }
      defer { _ = close(fd) }
      var leaseInfo = stat()
      guard fstat(fd, &leaseInfo) == 0, leaseInfo.st_mode & S_IFMT == S_IFREG,
        leaseInfo.st_uid == geteuid(), leaseInfo.st_mode & 0o777 == 0o600,
        leaseInfo.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0
      else { continue }
      var after = stat()
      guard lstat(entry.path, &after) == 0,
        before.st_dev == after.st_dev, before.st_ino == after.st_ino
      else { continue }
      let quarantine = parent.appendingPathComponent(".restore-cleanup-" + UUID().uuidString)
      guard renamex_np(entry.path, quarantine.path, UInt32(RENAME_EXCL)) == 0 else { continue }
      var moved = stat()
      if lstat(quarantine.path, &moved) == 0,
        moved.st_dev == before.st_dev, moved.st_ino == before.st_ino
      {
        try? fm.removeItem(at: quarantine)
      } else {
        // Preserve anything whose identity changed, rather than deleting it.
        _ = renamex_np(quarantine.path, entry.path, UInt32(RENAME_EXCL))
      }
    }
  }
}
