import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Replaces an existing stub's startup firmware files in place from a
/// restore image (UPGRADE-FLOW.md section 4.2, steps 3 to 5), with the same
/// plan and writer as a new stub (RestoreImageStubPlan, RestoreImageStubFiles):
///
/// 3. Preboot: the new restore bundle is written as `<group>/Restore.new`,
///    then swapped in (`Restore` -> `Restore.old`, `Restore.new` -> `Restore`,
///    RecoveryDirectorySwap.promote). `<group>/boot/`, where the old
///    personalized boot files Linux starts from live, and
///    `<group>/var/db/AdminUserRecoveryInfo.plist` are never touched.
/// 4. Recovery: the old `<group>/usr/standalone/firmware/arm64eBaseSystem.dmg`
///    is removed first, then the new one is decoded from the image's Apple
///    Encrypted Archive and stored compressed. The order is what lets a 27.2
///    stub fit a 2.5 GB container.
/// 5. System: bootcaches.plist and PlatformSupport.plist are replaced, the
///    stub's SystemVersion.plist goes where it is now (aurora-upgrade hides it
///    as SystemVersion-disabled.plist while the launcher is armed, and the
///    disarm shows it again), and the System volume's restore link points at
///    the group's `Restore`.
///
/// Each step is recorded in a journal on the System volume once it is done,
/// so a run cut short (power loss) runs again from the next step, and within
/// a step the writer adopts every file already written. The journal binds the
/// run to one plan (`plan_sha256`), group and build; another one is refused.
/// Removing `Restore.old`, enrolment and the receipts are the caller's
/// (RecoveryActions.upgradeStub), after `bless`.
public enum RestoreImageStubUpgrade {
  public enum Phase: String, Codable, CaseIterable, Comparable {
    case started, prebootWritten, prebootSwapped, recoveryRemoved, recoveryWritten, systemWritten
    /// The caller's steps after the files: `bless`, then bputil and kmutil, then the receipts.
    case blessed, enrolled, finished

    public static func < (a: Phase, b: Phase) -> Bool {
      allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
  }

  public enum Failure: Error, Equatable {
    /// The journal belongs to another plan, group or build.
    case otherJournal
    /// Something in the way that no recorded step made (`Restore.new` or
    /// `Restore.old` before the first step, or two SystemVersion files).
    case foreignState
    /// The image's archives need a key and none was given.
    case keyRequired
  }

  public struct Journal: Codable, Equatable {
    public var schema = 1
    public let planSHA256: String
    public let group: String
    public let build: String
    public var phase: Phase
    /// Receipts of every file and link written, by step.
    public var installed: [RestoreImageStubFiles.Installed]
    /// The enrolled Stage 1's SHA-256, once enrolled.
    public var stage1SHA256: String?

    public init(planSHA256: String, group: String, build: String) {
      self.planSHA256 = planSHA256
      self.group = group
      self.build = build
      phase = .started
      installed = []
    }

    /// The journal at `url`, nil when there is none.
    public static func load(_ url: URL) throws -> Journal? {
      var info = stat()
      guard lstat(url.path, &info) == 0 else {
        guard errno == ENOENT else { throw Failure.foreignState }
        return nil
      }
      guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
        info.st_size <= 16 << 20
      else { throw Failure.foreignState }
      return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try RecoveryFileTransaction.write(try encoder.encode(self), to: url)
    }
  }

  public static let newSuffix = ".new"
  public static let oldSuffix = ".old"
  public static let linkPath = "Restore"

  /// Runs steps 3 to 5 (or what is left of them) and returns the journal at
  /// `systemWritten` or later. `checkpoint` sees each phase once it is
  /// recorded (tests stop runs there).
  @discardableResult public static func run(
    plan: RestoreImageStubPlan, directory: RestoreImageDirectory,
    read: @escaping RestoreImageDirectory.Read, roots: [String: URL], group: String,
    planSHA256: String, build: String, journal url: URL, owner: uid_t = geteuid(),
    chunkBytes: Int = RestoreImageDirectory.streamChunk,
    archiveKey: ((RestoreImageDirectory.Entry, [String: Data]) throws -> Data)?,
    checkpoint: (Phase) throws -> Void = { _ in }
  ) throws -> Journal {
    let writer = try RestoreImageStubFiles.Writer(
      plan: plan, directory: directory, read: read, roots: roots, group: group, owner: owner,
      chunkBytes: chunkBytes, archiveKey: archiveKey)
    // Every archive is decoded here; nothing may be left for a later pass.
    guard archiveKey != nil else { throw Failure.keyRequired }
    let preboot = writer.trees["Preboot"]!
    let system = writer.trees["System"]!
    let restore = group + "/" + plan.restorePath
    let next = restore + newSuffix
    let old = restore + oldSuffix
    var journal: Journal
    if let found = try Journal.load(url) {
      guard found.planSHA256 == planSHA256, found.group == group, found.build == build else {
        throw Failure.otherJournal
      }
      journal = found
    } else {
      // Nothing of a run is there before its journal is.
      guard try !preboot.exists(next), try !preboot.exists(old) else { throw Failure.foreignState }
      journal = Journal(planSHA256: planSHA256, group: group, build: build)
      try journal.save(url)
      try checkpoint(.started)
    }
    func advance(_ phase: Phase, _ written: [RestoreImageStubFiles.Installed] = []) throws {
      journal.installed += written
      journal.phase = phase
      try journal.save(url)
      try checkpoint(phase)
    }
    func written(_ roles: Set<String>) throws -> [RestoreImageStubFiles.Installed] {
      let before = writer.installed.count
      try writer.write(roles: roles)
      guard writer.pending.isEmpty else { throw Failure.keyRequired }
      return Array(writer.installed[before...])
    }
    if journal.phase < .prebootWritten {
      writer.restoreDirectory = plan.restorePath + newSuffix
      try advance(.prebootWritten, written(["Preboot"]))
    }
    if journal.phase < .prebootSwapped {
      try RecoveryDirectorySwap.promote(
        next: roots["Preboot"]!.appendingPathComponent(next),
        target: roots["Preboot"]!.appendingPathComponent(restore),
        backup: roots["Preboot"]!.appendingPathComponent(old))
      try advance(.prebootSwapped)
    }
    if journal.phase < .recoveryRemoved {
      // First, so the old and new images never take the container's space together.
      try writer.trees["Recovery"]!.remove(group + "/" + RestoreImageStubFiles.recoveryImagePath)
      try advance(.recoveryRemoved)
    }
    if journal.phase < .recoveryWritten {
      try advance(.recoveryWritten, written(["Recovery"]))
    }
    if journal.phase < .systemWritten {
      let core = "System/Library/CoreServices/"
      let visible = try system.exists(core + "SystemVersion.plist")
      let hidden = try system.exists(core + "SystemVersion-disabled.plist")
      guard visible != hidden else { throw Failure.foreignState }
      writer.systemVersionPath =
        core + (hidden ? "SystemVersion-disabled.plist" : "SystemVersion.plist")
      writer.replaceSystemFiles = true
      var files = try written(["System"])
      // The System volume's link to the restore bundle, as the main installer makes it.
      let target = roots["Preboot"]!.appendingPathComponent(restore).path
      let current = try system.linkTarget(plan.restorePath)
      let kept = current.map { $0.hasSuffix("/" + restore) } ?? false
      let link = kept ? current! : target
      files.append(
        RestoreImageStubFiles.Installed(
          role: "System", path: plan.restorePath, installerDataName: nil,
          identity: try system.relink(plan.restorePath, target: link), linkTarget: link))
      try advance(.systemWritten, files)
    }
    return journal
  }

  /// Saves `journal` at `phase`, for the caller's steps after the files.
  public static func record(_ phase: Phase, _ journal: inout Journal, at url: URL) throws {
    journal.phase = phase
    try journal.save(url)
  }
}
