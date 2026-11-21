import Darwin
import Foundation
import RecoveryAuthorization

/// `aura remove-macos [--dry-run]`: deletes the Mac's macOS so Aurora can use
/// the whole internal disk. Runs only in this installation's paired Recovery,
/// and only once this installation has its own working owner: with macOS gone,
/// every later startup-security change (bputil, kmutil, bless, a new Stage 1 or
/// startup firmware) needs that owner's password, and nothing else can supply it.
extension RecoveryActions {
  static var wholeDiskJournal: URL { state.appendingPathComponent("whole-disk-removal.json") }
  static let claimRecordPath = "aurora/whole-disk/removed.json"

  static func wholeDiskInstallation() throws -> WholeDiskInstallation {
    let config = try configuration.get()
    return WholeDiskInstallation(
      systemUUID: config.systemUUID.uppercased(), groupUUID: config.groupUUID.uppercased(),
      espUUID: config.espUUID.uppercased())
  }

  private static func plist(_ arguments: [String]) throws -> [String: Any] {
    let data = try run("/usr/sbin/diskutil", arguments, timeout: 120)
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw RecoveryFailure(
        message: "diskutil \(arguments.joined(separator: " ")) returned no listing.")
    }
    return value
  }

  /// One reading of the internal disk that holds this installation.
  static func readWholeDisk() throws -> WholeDiskLayout {
    let system = try disk(systemUUID)
    guard let stores = system["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
      let store = stores[0]["APFSPhysicalStore"] as? String
    else {
      throw RecoveryFailure(
        message: "This installation’s startup container couldn’t be identified.")
    }
    let wholeName = try disk(store)["ParentWholeDisk"] as? String ?? ""
    let whole = try disk(wholeName)
    try check(
      whole["Internal"] as? Bool == true && whole["WholeDisk"] as? Bool == true
        && whole["Content"] as? String == "GUID_partition_scheme",
      "This installation isn’t on the Mac’s internal disk. Nothing was changed.")
    let list = try plist(["list", "-plist", "internal", "physical"])
    let entries = (list["AllDisksAndPartitions"] as? [[String: Any]] ?? []).filter {
      $0["DeviceIdentifier"] as? String == wholeName
    }
    var infos = [String: [String: Any]]()
    for record in entries.first?["Partitions"] as? [[String: Any]] ?? [] {
      if let id = record["DeviceIdentifier"] as? String { infos[id] = try disk(id) }
    }
    return try WholeDiskLayout.parse(
      disk: wholeName, diskSize: (whole["Size"] as? NSNumber)?.uint64Value ?? 0, list: list,
      infos: infos, apfs: try plist(["apfs", "list", "-plist"]),
      groups: try plist(["apfs", "listVolumeGroups", "-plist"]))
  }

  /// Find My keeps Activation Lock on this Mac after macOS is gone, and then
  /// only the Apple Account's password can restore it. Turn it off first.
  /// Fails closed: when the firmware variables can't be read, removal stops.
  static func findMyEnabled() throws -> Bool {
    let unknown = RecoveryFailure(
      message:
        "This Mac’s firmware variables couldn’t be read, so it isn’t known whether Find My is on. macOS was not removed."
    )
    guard let data = try? run("/usr/sbin/nvram", ["-x", "-p"]),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any], !values.isEmpty
    else { throw unknown }
    return MacOSRemoval.findMyOn(nvram: values)
  }

  /// The journal holds what the deletion was about to do; only root may
  /// change it, so `protectedRead` accepts it on resume.
  static func saveJournal(_ object: [String: Any]) throws {
    try saveJSON(object, to: wholeDiskJournal)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: wholeDiskJournal.path)
    try check(
      chown(wholeDiskJournal.path, 0, 0) == 0,
      "The macOS removal record couldn’t be protected. Nothing was changed.")
  }

  /// The owner that authorizes this installation's startup security from now
  /// on: the recovery account, finalized and an APFS volume owner.
  static func wholeDiskOwner() throws -> RecoveryAccountRecord {
    let record: RecoveryAccountRecord?
    do { record = try recoveryAccount() } catch {
      throw RecoveryFailure(
        message:
          "This installation’s recovery account isn’t a working owner yet: \(error.localizedDescription) macOS was not removed."
      )
    }
    if let gate = MacOSRemoval.ownerGate(phase: record?.phase) { throw gate }
    guard let record else {
      throw RecoveryFailure(
        message: "This installation has no recovery account. macOS was not removed.")
    }
    return record
  }

  static func verifyOwnerPassword(_ record: RecoveryAccountRecord, _ password: Data) throws {
    var secret = password
    secret.append(10)
    defer { secret.resetBytes(in: 0..<secret.count) }
    let args = [
      "apfs", "unlockVolume", record.target.dataUUID, "-user", record.generatedUID, "-verify",
      "-stdinpassphrase",
    ]
    let verified = try AccountNativeCommand.run("/usr/sbin/diskutil", args, input: secret)
    try check(
      verified.status == 0
        && String(decoding: verified.output, as: UTF8.self).contains("Passphrase valid"),
      "That isn’t \(record.username)’s password. macOS was not removed.")
  }

  private static func readLineTrimmed() -> String {
    (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
  }
  private static func readSecret(_ prompt: String) -> Data {
    let size = 1024
    var buffer = [CChar](repeating: 0, count: size)
    defer { buffer.withUnsafeMutableBytes { aurora_account_wipe($0.baseAddress, $0.count) } }
    guard readpassphrase(prompt, &buffer, size, RPP_ECHO_OFF) != nil else { return Data() }
    let length = buffer.firstIndex(of: 0) ?? 0
    return Data(buffer[..<length].map { UInt8(bitPattern: $0) })
  }

  /// What the owner reviews before removal: one reading of the disk, planned,
  /// and the owner who stays. Nothing is written to get it.
  struct MacOSRemovalReview {
    let installation: WholeDiskInstallation
    let plan: MacOSRemovalPlan
    let owner: RecoveryAccountRecord
    var text: String {
      MacOSRemoval.describe(plan)
        + "\nOwner for future startup changes: \(owner.username) (verified volume owner of \(RecoveryActions.volumeName))."
    }
  }

  enum MacOSRemovalPreparation {
    /// An interrupted removal was checked and finished; nothing to review.
    case resumed(String)
    case review(MacOSRemovalReview)
  }

  /// Every check before the confirmation, shared by `aura remove-macos` and
  /// Utilities → Remove macOS…. Throws `MacOSRemovalNeedsOwner` when the owner
  /// step comes first.
  static func prepareMacOSRemoval() throws -> MacOSRemovalPreparation {
    try recoveryOnly()
    _ = try installed()
    // Paired Recovery of this installation: after removal it is the Mac's
    // only paired Recovery, so prove it works by running in it.
    try requireEnrollmentEnvironment()
    // The journal lives on this volume; the app may get here before its
    // background setup made the volume writable.
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let installation = try wholeDiskInstallation()
    if let resumed = try resumeWholeDiskRemoval(installation) { return .resumed(resumed) }
    let owner = try wholeDiskOwner()
    try check(
      try targetIsDefaultBoot(),
      "Choose \(volumeName) as the startup disk first (Apple menu → Startup Disk), so the Mac starts Aurora without macOS. macOS was not removed."
    )
    try check(
      !(try findMyEnabled()),
      "Find My is on for this Mac. Turn it off in macOS (System Settings → your name → iCloud → Find My Mac) or remove this Mac at icloud.com/find first: once macOS is gone, restoring this Mac would need that Apple Account. macOS was not removed."
    )
    let plan = try MacOSRemoval.plan(try readWholeDisk(), installation: installation)
    return .review(MacOSRemovalReview(installation: installation, plan: plan, owner: owner))
  }

  /// Deletes the reviewed macOS container. The phrase and the owner's password
  /// are checked here, and the disk must still be the one reviewed.
  static func performMacOSRemoval(_ review: MacOSRemovalReview, phrase: String, password: Data)
    throws -> String
  {
    guard MacOSRemoval.confirms(phrase) else {
      throw RecoveryFailure(message: "The confirmation didn’t match. macOS was not removed.")
    }
    try verifyOwnerPassword(review.owner, password)
    let plan = review.plan
    let installation = review.installation
    // The disk must still be the one reviewed, immediately before deletion.
    try MacOSRemoval.requireUnchanged(plan, now: try readWholeDisk(), installation: installation)
    // Delete by the partition's UUID, not its position: resolve it once more
    // and require it to be the reviewed partition of the reviewed disk.
    let target = try disk(plan.partition.uuid)
    try check(
      target["DeviceIdentifier"] as? String == plan.partition.identifier
        && target["ParentWholeDisk"] as? String == plan.disk,
      "The macOS partition’s identity changed since it was reviewed. Nothing was changed; review it again."
    )
    let journal = MacOSRemoval.journal(plan, removedAt: Date())
    try saveJournal(journal)
    InstallerLog.shared.append("Removing macOS: deleting container \(plan.macOS.uuid).")
    do {
      try run(
        "/usr/sbin/diskutil", ["apfs", "deleteContainer", plan.partition.uuid],
        timeout: 600)
    } catch {
      let now = try readWholeDisk()
      if (try? MacOSRemoval.requireUnchanged(plan, now: now, installation: installation)) != nil {
        try FileManager.default.removeItem(at: wholeDiskJournal)
        throw RecoveryFailure(
          message:
            "diskutil couldn’t delete macOS (\(error.localizedDescription)). Nothing was changed.")
      }
      throw RecoveryFailure(
        message:
          "diskutil stopped part way (\(error.localizedDescription)). Don’t restart: run `aura remove-macos` again to check the disk, and save Window → Installer Log."
      )
    }
    try finishWholeDiskRemoval(plan, journal: journal)
    InstallerLog.shared.append("macOS was removed; every kept partition verified.")
    return
      "macOS was removed. Restart into Aurora; it adds the freed space to Linux on its next start (or run `sudo aurora-whole-disk claim`)."
  }

  static func removeMacOS(dryRun: Bool) throws {
    let review: MacOSRemovalReview
    switch try prepareMacOSRemoval() {
    case .resumed(let message):
      print(message)
      return
    case .review(let value): review = value
    }
    print(review.text)
    if dryRun {
      print("Dry run: nothing was changed.")
      return
    }
    print("\n" + MacOSRemoval.consequences(owner: review.owner.username))
    print("To continue, type: \(MacOSRemoval.phrase)")
    let typed = readLineTrimmed()
    guard MacOSRemoval.confirms(typed) else {
      throw RecoveryFailure(message: "The confirmation didn’t match. macOS was not removed.")
    }
    var password = readSecret("Password for \(review.owner.username): ")
    defer { password.resetBytes(in: 0..<password.count) }
    print(try performMacOSRemoval(review, phrase: typed, password: password))
  }

  /// The record Linux reads, written only after the deletion verified.
  private static func finishWholeDiskRemoval(_ plan: MacOSRemovalPlan, journal: [String: Any])
    throws
  {
    try MacOSRemoval.verifyRemoved(plan, after: try readWholeDisk())
    try saveJSON(
      MacOSRemoval.linuxRecord(journal), to: try esp().appendingPathComponent(claimRecordPath))
    var done = journal
    done["phase"] = "complete"
    try saveJournal(done)
  }

  /// A deletion interrupted after its journal was written: finish it only when
  /// the disk shows exactly the planned result (MacOSRemoval.resume).
  private static func resumeWholeDiskRemoval(_ installation: WholeDiskInstallation) throws
    -> String?
  {
    guard FileManager.default.fileExists(atPath: wholeDiskJournal.path) else { return nil }
    let journal: [String: Any]
    do {
      let data = try RecoveryAccountInstaller.protectedRead(wholeDiskJournal, limit: 1 << 16)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RecoveryFailure(message: "not an object")
      }
      journal = object
    } catch {
      throw RecoveryFailure(
        message:
          "The macOS removal record is unreadable (\(error.localizedDescription)). Nothing was changed; save Window → Installer Log and ask for help."
      )
    }
    switch try MacOSRemoval.resume(
      journal: journal, installation: installation, now: try readWholeDisk())
    {
    case .complete:
      return "macOS was already removed from this Mac."
    case .notStarted:
      try FileManager.default.removeItem(at: wholeDiskJournal)
      InstallerLog.shared.append("Removing macOS: the earlier attempt never started deleting.")
      return nil
    case .finish:
      try saveJSON(
        MacOSRemoval.linuxRecord(journal), to: try esp().appendingPathComponent(claimRecordPath))
      var done = journal
      done["phase"] = "complete"
      try saveJournal(done)
      return "The interrupted removal of macOS is complete. Restart into Aurora."
    }
  }
}
