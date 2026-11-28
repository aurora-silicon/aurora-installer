import Darwin
import Foundation

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

@main struct RecoveryFileTransactionCheck {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let existing = root.appendingPathComponent("metadata.plist")
    let missing = root.appendingPathComponent("new-token.plist")
    let before = Data("original metadata".utf8)
    try before.write(to: existing)
    precondition(chmod(existing.path, 0o640) == 0)
    let backup = root.appendingPathComponent("snapshot")
    let transaction = try RecoveryFileTransaction(directory: backup, files: [existing, missing])
    try Data("partial native update".utf8).write(to: existing, options: .atomic)
    try Data("partial token".utf8).write(to: missing)
    let resumed = try RecoveryFileTransaction.resume(directory: backup, files: [existing, missing])
    try resumed.restore()
    let restored = try Data(contentsOf: existing)
    precondition(restored == before)
    precondition(!fm.fileExists(atPath: missing.path))
    var info = stat()
    precondition(lstat(existing.path, &info) == 0 && (info.st_mode & 0o7777) == 0o640)
    do {
      _ = try RecoveryFileTransaction.resume(directory: backup, files: [missing, existing])
      preconditionFailure("Changed rollback target accepted")
    } catch {}
    // Repeating an interrupted restoration is safe and keeps original bytes.
    try transaction.restore()
    let restoredAgain = try Data(contentsOf: existing)
    precondition(restoredAgain == before)
    // A damaged backup must be rejected before any target is restored.
    try Data("tampered".utf8).write(to: backup.appendingPathComponent("0.before"))
    try Data("keep until valid rollback".utf8).write(to: existing)
    do {
      try transaction.restore()
      preconditionFailure("Damaged backup accepted")
    } catch {}
    let notRestored = try Data(contentsOf: existing)
    precondition(notRestored == Data("keep until valid rollback".utf8))
    try before.write(to: backup.appendingPathComponent("0.before"))
    try transaction.restore()
    // UUID-validated callers can remap the same relative files after a mount rename.
    let newMount = root.appendingPathComponent("renamed-mount")
    try fm.createDirectory(at: newMount, withIntermediateDirectories: false)
    let relocated = newMount.appendingPathComponent("metadata.plist")
    let relocatedMissing = newMount.appendingPathComponent("new-token.plist")
    let remapped = try RecoveryFileTransaction.resume(
      directory: backup, files: [relocated, relocatedMissing], originalFiles: [existing, missing])
    try remapped.restore()
    let remappedBytes = try Data(contentsOf: relocated)
    precondition(remappedBytes == before)
    let moved = root.appendingPathComponent("metadata-disabled.plist")
    precondition(chflags(existing.path, UInt32(UF_NODUMP)) == 0)
    let commitBackup = root.appendingPathComponent("commit-snapshot")
    let committing = try RecoveryFileTransaction(directory: commitBackup, files: [existing])
    try committing.clearImmutableFlags()
    try fm.moveItem(at: existing, to: moved)
    try committing.commit(relocated: [existing.standardizedFileURL.path: moved])
    precondition(lstat(moved.path, &info) == 0 && info.st_flags & UInt32(UF_NODUMP) != 0)
    let status = try Data(contentsOf: commitBackup.appendingPathComponent("status"))
    precondition(status == Data("committed\n".utf8))
    precondition(chflags(moved.path, 0) == 0)
    let newCommit = root.appendingPathComponent("new-commit")
    let newSnapshot = root.appendingPathComponent("new-snapshot")
    let newTransaction = try RecoveryFileTransaction(directory: newSnapshot, files: [newCommit])
    try Data("newly created".utf8).write(to: newCommit)
    try newTransaction.commit()
    let newStatus = try Data(contentsOf: newSnapshot.appendingPathComponent("status"))
    precondition(newStatus == Data("committed\n".utf8))
    // Metadata reaches the opened file, never what its name has become.
    let other = root.appendingPathComponent("other.plist")
    let linked = root.appendingPathComponent("linked.plist")
    try Data("other".utf8).write(to: other)
    precondition(chmod(other.path, 0o644) == 0)
    try fm.createSymbolicLink(at: linked, withDestinationURL: other)
    do {
      try RecoveryFileTransaction.setMetadata(linked, mode: 0o600, flags: UInt32(UF_NODUMP))
      preconditionFailure("Metadata followed a symbolic link")
    } catch {}
    precondition(lstat(other.path, &info) == 0 && (info.st_mode & 0o7777) == 0o644)
    precondition(info.st_flags & UInt32(UF_NODUMP) == 0)
    try fm.removeItem(at: linked)
    precondition(link(other.path, linked.path) == 0)
    do {
      try RecoveryFileTransaction.setMetadata(linked, mode: 0o600, singleName: true)
      preconditionFailure("Metadata reached a file with another name")
    } catch {}
    precondition(lstat(other.path, &info) == 0 && (info.st_mode & 0o7777) == 0o644)
    try fm.removeItem(at: linked)
    try RecoveryFileTransaction.setMetadata(other, mode: 0o600, singleName: true)
    precondition(lstat(other.path, &info) == 0 && (info.st_mode & 0o7777) == 0o600)
    // A protected file is 0600 from its creation, whatever the umask, and
    // replaces its name, never what a link there points at.
    let written = root.appendingPathComponent("written.plist")
    let previous = umask(0)
    try RecoveryFileTransaction.write(Data("first".utf8), to: written)
    precondition(lstat(written.path, &info) == 0 && (info.st_mode & 0o7777) == 0o600)
    precondition(info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1)
    let first = try Data(contentsOf: written)
    precondition(first == Data("first".utf8))
    try RecoveryFileTransaction.write(Data(), to: written)
    let empty = try Data(contentsOf: written)
    precondition(empty.isEmpty)
    let target = root.appendingPathComponent("link-target.plist")
    try Data("target".utf8).write(to: target)
    precondition(chmod(target.path, 0o644) == 0)
    try fm.removeItem(at: written)
    try fm.createSymbolicLink(at: written, withDestinationURL: target)
    try RecoveryFileTransaction.write(Data("replaced".utf8), to: written)
    precondition(lstat(written.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
    precondition((info.st_mode & 0o7777) == 0o600)
    let replaced = try Data(contentsOf: written)
    let untouched = try Data(contentsOf: target)
    precondition(replaced == Data("replaced".utf8) && untouched == Data("target".utf8))
    precondition(lstat(target.path, &info) == 0 && (info.st_mode & 0o7777) == 0o644)
    _ = umask(0o022)
    let plain = root.appendingPathComponent("unprotected.plist")
    try RecoveryFileTransaction.write(Data("plain".utf8), to: plain, protect: false)
    precondition(lstat(plain.path, &info) == 0 && (info.st_mode & 0o7777) == 0o644)
    _ = umask(previous)
    // A folder under the name is not replaced, and no temporary file is left.
    let folder = root.appendingPathComponent("folder.plist")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    try fm.createDirectory(
      at: folder.appendingPathComponent("inside"), withIntermediateDirectories: false)
    do {
      try RecoveryFileTransaction.write(Data("x".utf8), to: folder)
      preconditionFailure("A folder was replaced")
    } catch {}
    let names = try fm.contentsOfDirectory(atPath: root.path)
    precondition(names.allSatisfy { !$0.hasSuffix(".tmp") })
    print(
      "PASS file rollback bytes, original absence, mode, interruption resume, target binding, "
        + "metadata through the opened file and protected creation")
  }
}
