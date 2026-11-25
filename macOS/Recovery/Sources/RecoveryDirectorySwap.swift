import Foundation

/// Replace a whole metadata tree on its own filesystem. The original directory
/// remains a sibling until the caller's durable enrollment record commits.
enum RecoveryDirectorySwap {
  static func paths(target: URL, operation: String) -> (URL, URL) {
    let parent = target.deletingLastPathComponent()
    return (
      parent.appendingPathComponent(".aurora-var-before-" + operation),
      parent.appendingPathComponent(".aurora-var-next-" + operation)
    )
  }

  static func replace(
    source: URL, target: URL, operation: String, wasPresent: Bool,
    copy: (URL, URL) throws -> Void,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    let fm = FileManager.default
    let (backup, next) = paths(target: target, operation: operation)
    guard !fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: next.path) else {
      throw AccountSetupFailure("An earlier iSC metadata copy needs recovery first.")
    }
    try copy(source, next)
    try RecoveryFileTransaction.flushTree(next)
    try RecoveryFileTransaction.flushDirectory(next.deletingLastPathComponent())
    try checkpoint("copied")
    if wasPresent { try fm.moveItem(at: target, to: backup) }
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
    try checkpoint("saved")
    try fm.moveItem(at: next, to: target)
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
    try checkpoint("published")
  }

  static func restore(target: URL, operation: String, wasPresent: Bool) throws {
    let fm = FileManager.default
    let (backup, next) = paths(target: target, operation: operation)
    if fm.fileExists(atPath: backup.path) {
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      try fm.moveItem(at: backup, to: target)
    } else if !wasPresent && fm.fileExists(atPath: target.path) {
      try fm.removeItem(at: target)
    }
    if fm.fileExists(atPath: next.path) { try fm.removeItem(at: next) }
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
  }
  static func commit(target: URL, operation: String) throws {
    let fm = FileManager.default
    let (backup, next) = paths(target: target, operation: operation)
    for path in [backup, next] where fm.fileExists(atPath: path.path) {
      try fm.removeItem(at: path)
    }
    try RecoveryFileTransaction.flushDirectory(target.deletingLastPathComponent())
  }

  /// Puts the finished directory `next` in place of `target`, keeping the
  /// old one as `backup`, by two renames. Run again after either rename was
  /// interrupted, it finishes the swap; once `next` is gone and `backup` and
  /// `target` both exist, it is done. Any other state is refused unchanged.
  static func promote(next: URL, target: URL, backup: URL) throws {
    let fm = FileManager.default
    func present(_ url: URL) throws -> Bool {
      var info = stat()
      if lstat(url.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw AccountSetupFailure("\(url.lastPathComponent) is not a directory.")
        }
        return true
      }
      guard errno == ENOENT else {
        throw AccountSetupFailure("Cannot inspect \(url.lastPathComponent).")
      }
      return false
    }
    let parent = target.deletingLastPathComponent()
    switch (try present(next), try present(target), try present(backup)) {
    case (true, true, false):
      try fm.moveItem(at: target, to: backup)
      try RecoveryFileTransaction.flushDirectory(parent)
      fallthrough
    case (true, false, _):
      try fm.moveItem(at: next, to: target)
      try RecoveryFileTransaction.flushDirectory(parent)
    case (false, true, true):
      return
    default:
      throw AccountSetupFailure(
        "\(target.lastPathComponent) can't be swapped: \(next.lastPathComponent) or \(backup.lastPathComponent) is missing or in the way."
      )
    }
  }

  /// Removes the directory `backup` an earlier `promote` kept, once nothing
  /// needs it; nothing there is not an error.
  static func discard(backup: URL) throws {
    let fm = FileManager.default
    var info = stat()
    guard lstat(backup.path, &info) == 0 else {
      guard errno == ENOENT else { throw AccountSetupFailure("Cannot inspect the old directory.") }
      return
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw AccountSetupFailure("\(backup.lastPathComponent) is not a directory.")
    }
    try fm.removeItem(at: backup)
    try RecoveryFileTransaction.flushDirectory(backup.deletingLastPathComponent())
  }
}
