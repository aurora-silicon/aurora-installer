import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Replaces an existing stub's startup firmware in place from a restore
/// image (UPGRADE-FLOW.md section 4.2), with the same plan and writer as a
/// new stub (RestoreImageStubPlan, RestoreImageStubFiles), in this order:
///
/// 1. Preboot: the new restore bundle is written as `<group>/Restore.new`,
///    then swapped in (`Restore` -> `Restore.old`, `Restore.new` -> `Restore`,
///    RecoveryDirectorySwap.promote). `<group>/boot/`, where the old
///    personalized boot files Linux starts from live, and
///    `<group>/var/db/AdminUserRecoveryInfo.plist` are never touched.
/// 2. System: the files about to change are saved (RecoveryFileTransaction,
///    and the restore link's target in the journal), then bootcaches.plist
///    and PlatformSupport.plist are replaced, the stub's SystemVersion.plist
///    goes where it is now (aurora-upgrade hides it as
///    SystemVersion-disabled.plist while the launcher is armed) and the
///    restore link points at the group's `Restore`.
/// 3. `bless` with the owner (`Steps.bless`). It creates the LocalPolicy only
///    from the group's paired recoveryOS, the one running, so nothing of the
///    Recovery volume has changed yet. If it fails, Preboot and System are
///    put back exactly as they were (`Restore.old` -> `Restore`, the saved
///    System files and link), the Recovery volume is never touched, and the
///    run ends in `Failure.needsMacOSBless`: the main installer's own bless in
///    macOS is the way on. If it succeeds, the personalized boot files it
///    made are compared with before (`Steps.bootState`): the Preboot ones must
///    have changed; the Recovery ones tell whether the Recovery image is
///    swapped (4).
/// 4. Recovery: only when `bless` personalized the group's Recovery boot
///    files (from the new restore bundle, which carries the new Recovery
///    image's root hash and trust cache), the old
///    `<group>/usr/standalone/firmware/arm64eBaseSystem.dmg` is removed and
///    the new one decoded from its Apple Encrypted Archive and stored
///    compressed, old first so a 27.2 stub fits a 2.5 GB container. When they
///    are unchanged, the old image still pairs with them and is kept.
/// 5. `bputil -nc` and `kmutil configure-boot` (`Steps.enroll`).
///
/// Each step is recorded in a journal on the System volume once it is done,
/// so a run cut short (power loss) runs again from the next step, and within
/// a step the writer adopts every file already written. The journal binds the
/// run to one plan (`plan_sha256`), group and build; another one is refused,
/// as is one an earlier order wrote (schema 1). Removing `Restore.old` and
/// the receipts are the caller's (RecoveryActions.upgradeStub).
public enum RestoreImageStubUpgrade {
  public enum Phase: String, Codable, CaseIterable, Comparable {
    case started, prebootWritten, prebootSwapped, systemSaved, systemWritten, blessed
    case recoveryRemoved, recoveryWritten, enrolled
    /// The caller's records after enrolment.
    case finished

    public static func < (a: Phase, b: Phase) -> Bool {
      allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
  }

  public enum Failure: Error, Equatable {
    /// The journal belongs to another plan, group or build.
    case otherJournal
    /// A journal from an earlier order (Recovery before bless), which this
    /// one can't resume.
    case oldJournal
    /// Something in the way that no recorded step made (`Restore.new` or
    /// `Restore.old` before the first step, or two SystemVersion files).
    case foreignState
    /// The image's archives need a key and none was given.
    case keyRequired
    /// `bless` refused here; Preboot and System are back as they were and
    /// the Recovery volume is untouched. The main installer's bless in macOS
    /// approves the files instead.
    case needsMacOSBless
    /// `bless` returned but personalized no new boot files in Preboot.
    case blessChangedNothing
  }

  /// The commands around the files, injected so the order can be checked
  /// without bless, bputil or kmutil.
  public struct Steps {
    /// `bless --setBoot` with the owner's password.
    public var bless: () throws -> Void
    /// `bputil -nc` and `kmutil configure-boot` of the staged Stage 1.
    public var enroll: () throws -> Void
    /// The personalized boot files of a volume ("Preboot", "Recovery") as
    /// `bootState` reads them; compared before and after `bless`.
    public var bootState: (_ role: String) throws -> [String: String]
    public init(
      bless: @escaping () throws -> Void, enroll: @escaping () throws -> Void,
      bootState: @escaping (_ role: String) throws -> [String: String]
    ) {
      self.bless = bless
      self.enroll = enroll
      self.bootState = bootState
    }
  }

  public static let schema = 2
  public static let needsMacOSBlessState = "needs-macos-bless"

  public struct Journal: Codable, Equatable {
    public var schema = RestoreImageStubUpgrade.schema
    public let planSHA256: String
    public let group: String
    public let build: String
    public var phase: Phase
    /// Receipts of every file and link written, by step.
    public var installed: [RestoreImageStubFiles.Installed]
    /// The enrolled Stage 1's SHA-256, once enrolled.
    public var stage1SHA256: String?
    /// An in-place-grow upgrade grew the stub container (StubUpgradeGrow).
    public var containerGrown: Bool?
    /// The first file step found nothing of another run in Preboot.
    public var prebootChecked: Bool?
    /// The restore link's target before the System step; nil with
    /// `systemSaved` reached means there was no link.
    public var oldRestoreLink: String?
    /// nil, "rolling-back", or `needsMacOSBlessState`.
    public var state: String?
    /// Whether `bless` made new personalized boot files in Preboot and in
    /// Recovery (the latter decides the Recovery image swap).
    public var prebootPersonalized: Bool?
    public var recoveryPersonalized: Bool?
    /// The Recovery image was left as it was (its boot files weren't made again).
    public var recoveryKept: Bool?
    /// The main installer approved the files in macOS (StubUpgradeFallback).
    public var macOSBlessed: Bool?
    /// The System volume root's mode and group before this run made it the
    /// owner's alone; a put-back restores them.
    public var systemRootMode: UInt32?
    public var systemRootGroup: UInt32?

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
      let data = try Data(contentsOf: url)
      guard
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schema"] as? Int
          == RestoreImageStubUpgrade.schema
      else { throw Failure.oldJournal }
      return try JSONDecoder().decode(Journal.self, from: data)
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

  /// The System files a run may change, saved before it changes them.
  static func systemFiles(_ system: URL) -> [URL] {
    [
      "usr/standalone/bootcaches.plist", "System/Library/CoreServices/PlatformSupport.plist",
      "System/Library/CoreServices/SystemVersion.plist",
      "System/Library/CoreServices/SystemVersion-disabled.plist",
    ].map { system.appendingPathComponent($0) }
  }

  /// Where the saved System files go, beside the journal.
  static func savedSystem(_ url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent("upgrade-system-before")
  }

  /// Runs the upgrade (or what is left of it) through enrolment and returns
  /// the journal at `enrolled`. `checkpoint` sees each phase once it is
  /// recorded (tests stop runs there).
  @discardableResult public static func run(
    plan: RestoreImageStubPlan, directory: RestoreImageDirectory,
    read: @escaping RestoreImageDirectory.Read, roots: [String: URL], group: String,
    planSHA256: String, build: String, journal url: URL, owner: uid_t = geteuid(),
    chunkBytes: Int = RestoreImageDirectory.streamChunk,
    archiveKey: ((RestoreImageDirectory.Entry, [String: Data]) throws -> Data)?,
    steps: Steps, checkpoint: (Phase) throws -> Void = { _ in }
  ) throws -> Journal {
    let writer = try RestoreImageStubFiles.Writer(
      plan: plan, directory: directory, read: read, roots: roots, group: group, owner: owner,
      chunkBytes: chunkBytes, archiveKey: archiveKey)
    // Every archive is decoded here; nothing may be left for a later pass.
    guard archiveKey != nil else { throw Failure.keyRequired }
    let system = writer.trees["System"]!
    let restore = group + "/" + plan.restorePath
    let next = restore + newSuffix
    let old = restore + oldSuffix
    // An existing journal must be this run's (begin refuses another's).
    let found =
      try Journal.load(url) == nil
      ? nil : try begin(url, planSHA256: planSHA256, group: group, build: build)
    var journal: Journal
    if let found, found.state == "rolling-back" {
      // A put-back cut short finishes before anything else.
      journal = found
      try rollBack(
        plan: plan, writer: writer, roots: roots, group: group, journal: &journal, at: url)
      throw Failure.needsMacOSBless
    }
    if let found, found.prebootChecked == true {
      journal = found
    } else {
      // Nothing of a run is in Preboot before its first file step is; a
      // refusal here leaves no journal of its own behind.
      let preboot = writer.trees["Preboot"]!
      guard found.map({ $0.phase == .started && $0.installed.isEmpty }) ?? true,
        try !preboot.exists(next), try !preboot.exists(old)
      else { throw Failure.foreignState }
      journal = try found ?? begin(url, planSHA256: planSHA256, group: group, build: build)
      journal.prebootChecked = true
      if journal.systemRootMode == nil {
        journal.systemRootMode = UInt32(system.rootFound.mode)
        journal.systemRootGroup = UInt32(system.rootFound.group)
      }
      try journal.save(url)
      try checkpoint(.started)
    }
    func advance(_ phase: Phase, _ written: [RestoreImageStubFiles.Installed] = []) throws {
      // A step run again replaces its receipts rather than adding them twice.
      let paths = Set(written.map { $0.role + "/" + $0.path })
      journal.installed =
        journal.installed.filter { !paths.contains($0.role + "/" + $0.path) } + written
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
    let core = "System/Library/CoreServices/"
    if journal.phase < .systemSaved {
      // What the System step changes, saved first, so a refused bless can
      // put it back. Copies made before a cut-short save are of the same,
      // still unchanged, files.
      let visible = try system.exists(core + "SystemVersion.plist")
      let hidden = try system.exists(core + "SystemVersion-disabled.plist")
      guard visible != hidden else { throw Failure.foreignState }
      let saved = savedSystem(url)
      if FileManager.default.fileExists(atPath: saved.path) {
        try FileManager.default.removeItem(at: saved)
      }
      _ = try RecoveryFileTransaction(directory: saved, files: systemFiles(roots["System"]!))
      journal.oldRestoreLink = try system.linkTarget(plan.restorePath)
      try advance(.systemSaved)
    }
    if journal.phase < .systemWritten {
      let hidden = try system.exists(core + "SystemVersion-disabled.plist")
      writer.systemVersionPath =
        core + (hidden ? "SystemVersion-disabled.plist" : "SystemVersion.plist")
      writer.replaceSystemFiles = true
      var files = try written(["System"])
      // The System volume's link to the restore bundle, as the main installer makes it.
      let target = roots["Preboot"]!.appendingPathComponent(restore).path
      let current = try system.linkTarget(plan.restorePath)
      // A link to this group's bundle is kept, however it is spelled
      // (asahi-installer writes /Volumes/Preboot/<group>/./Restore).
      let wanted = restore.split(separator: "/").map(String.init)
      let kept =
        current.map { link in
          let parts = link.split(separator: "/").map(String.init).filter { $0 != "." }
          return link.hasPrefix("/") && !parts.contains("..")
            && parts.suffix(wanted.count) == wanted
        } ?? false
      let link = kept ? current! : target
      files.append(
        RestoreImageStubFiles.Installed(
          role: "System", path: plan.restorePath, installerDataName: nil,
          identity: try system.relink(plan.restorePath, target: link), linkTarget: link))
      try advance(.systemWritten, files)
    }
    if journal.phase < .blessed {
      let preboot = try steps.bootState("Preboot")
      let recovery = try steps.bootState("Recovery")
      do {
        try steps.bless()
      } catch {
        // Not approved here: the stub goes back to exactly what it was.
        try rollBack(
          plan: plan, writer: writer, roots: roots, group: group, journal: &journal, at: url)
        throw Failure.needsMacOSBless
      }
      guard try steps.bootState("Preboot") != preboot else { throw Failure.blessChangedNothing }
      journal.prebootPersonalized = true
      journal.recoveryPersonalized = try steps.bootState("Recovery") != recovery
      journal.state = nil
      try advance(.blessed)
    }
    // Approved: nothing is put back from here on.
    if FileManager.default.fileExists(atPath: savedSystem(url).path) {
      try FileManager.default.removeItem(at: savedSystem(url))
    }
    if journal.phase < .recoveryWritten {
      if journal.recoveryPersonalized == true {
        if journal.phase < .recoveryRemoved {
          // First, so the old and new images take the container's space at most once each.
          try writer.trees["Recovery"]!.remove(
            group + "/" + RestoreImageStubFiles.recoveryImagePath)
          try advance(.recoveryRemoved)
        }
        try advance(.recoveryWritten, written(["Recovery"]))
      } else {
        // bless left the Recovery boot files alone: they pair with the old
        // image, which stays.
        journal.recoveryKept = true
        try advance(.recoveryWritten)
      }
    }
    if journal.phase < .enrolled {
      try steps.enroll()
      try advance(.enrolled)
    }
    return journal
  }

  /// Puts Preboot and System back as they were before the run (each step
  /// can run again): the saved System files and restore link, `Restore.old`
  /// back to `Restore`, `Restore.new` and `Restore.old` gone. The Recovery
  /// volume isn't touched. The journal then says `needsMacOSBlessState`,
  /// back at its first step.
  static func rollBack(
    plan: RestoreImageStubPlan, writer: RestoreImageStubFiles.Writer, roots: [String: URL],
    group: String, journal: inout Journal, at url: URL
  ) throws {
    let reached = journal.phase
    journal.state = "rolling-back"
    try journal.save(url)
    let system = writer.trees["System"]!
    let saved = savedSystem(url)
    if reached >= .systemSaved, FileManager.default.fileExists(atPath: saved.path) {
      try RecoveryFileTransaction.resume(directory: saved, files: systemFiles(roots["System"]!))
        .restore()
      if let link = journal.oldRestoreLink {
        _ = try system.relink(plan.restorePath, target: link)
      } else {
        try system.removeLink(plan.restorePath)
      }
    }
    let preboot = roots["Preboot"]!
    let restore = group + "/" + plan.restorePath
    let oldBundle = preboot.appendingPathComponent(restore + oldSuffix)
    let newBundle = preboot.appendingPathComponent(restore + newSuffix)
    if FileManager.default.fileExists(atPath: oldBundle.path) {
      try RecoveryDirectorySwap.promote(
        next: oldBundle, target: preboot.appendingPathComponent(restore), backup: newBundle)
    }
    try RecoveryDirectorySwap.discard(backup: newBundle)
    if FileManager.default.fileExists(atPath: saved.path) {
      try FileManager.default.removeItem(at: saved)
    }
    if let mode = journal.systemRootMode, let group = journal.systemRootGroup {
      try system.restoreRoot(mode: mode_t(mode), group: gid_t(group))
    }
    var back = Journal(planSHA256: journal.planSHA256, group: journal.group, build: journal.build)
    back.containerGrown = journal.containerGrown
    back.state = needsMacOSBlessState
    journal = back
    try journal.save(url)
  }

  /// The personalized boot files under `<root>/<group>/boot`, each by its
  /// path with its type, size, change time and inode, for comparing before
  /// and after `bless`. Missing: empty.
  public static func bootState(root: URL, group: String) -> [String: String] {
    let base = root.appendingPathComponent(group + "/boot")
    var out = [String: String]()
    for path in FileManager.default.subpaths(atPath: base.path) ?? [] {
      var info = stat()
      guard lstat(base.appendingPathComponent(path).path, &info) == 0 else { continue }
      #if canImport(Darwin)
        let changed = "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
      #else
        let changed = "\(info.st_ctim.tv_sec).\(info.st_ctim.tv_nsec)"
      #endif
      out[path] = "\(info.st_mode & S_IFMT) \(info.st_size) \(changed) \(info.st_ino)"
    }
    return out
  }

  /// The run's journal at `url`, made (and saved) when there is none.
  /// Another plan's, group's or build's journal is refused. It opens no
  /// volume tree, so a step before the files (growing the container) can
  /// record itself before anything is checked or written in the volumes.
  public static func begin(_ url: URL, planSHA256: String, group: String, build: String) throws
    -> Journal
  {
    if let found = try Journal.load(url) {
      guard found.planSHA256 == planSHA256, found.group == group, found.build == build else {
        throw Failure.otherJournal
      }
      return found
    }
    let journal = Journal(planSHA256: planSHA256, group: group, build: build)
    try journal.save(url)
    return journal
  }

  /// Saves `journal` at `phase`, for the caller's steps after the files.
  public static func record(_ phase: Phase, _ journal: inout Journal, at url: URL) throws {
    journal.phase = phase
    try journal.save(url)
  }
}
