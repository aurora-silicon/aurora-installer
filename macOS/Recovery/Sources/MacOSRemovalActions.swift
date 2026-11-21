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
  static func findMyEnabled() -> Bool {
    (try? run("/usr/sbin/nvram", ["fmm-mobileme-token-FMM"])) != nil
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
    guard let record, record.phase == "finalized" else {
      throw RecoveryFailure(
        message:
          "This installation has no recovery account of its own yet. Create it first (Aurora Installer → Utilities → Create Recovery Account…), authorize it in Startup Disk, and come back. macOS was not removed, because without that account nobody could change this Mac’s startup security afterwards."
      )
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

  static func removeMacOS(dryRun: Bool) throws {
    try recoveryOnly()
    _ = try installed()
    // Paired Recovery of this installation: after removal it is the Mac's
    // only paired Recovery, so prove it works by running in it.
    try requireEnrollmentEnvironment()
    let installation = try wholeDiskInstallation()
    if let resumed = try resumeWholeDiskRemoval(installation) {
      print(resumed)
      return
    }
    let owner = try wholeDiskOwner()
    try check(
      try targetIsDefaultBoot(),
      "Choose \(volumeName) as the startup disk first (Apple menu → Startup Disk), so the Mac starts Aurora without macOS. macOS was not removed."
    )
    try check(
      !findMyEnabled(),
      "Find My is on for this Mac. Turn it off in macOS (System Settings → your name → iCloud → Find My Mac) or remove this Mac at icloud.com/find first: once macOS is gone, restoring this Mac would need that Apple Account. macOS was not removed."
    )
    let layout = try readWholeDisk()
    let plan = try MacOSRemoval.plan(layout, installation: installation)
    print(MacOSRemoval.describe(plan))
    print(
      "Owner for future startup changes: \(owner.username) (verified volume owner of \(volumeName))."
    )
    if dryRun {
      print("Dry run: nothing was changed.")
      return
    }
    print(
      """

      This deletes macOS, its apps and every file in it, for good. After this:
        - macOS and macOS apps are gone. Aurora is the only system on this Mac.
        - Apple's macOS and firmware updates no longer arrive by themselves. The Mac's
          system firmware stays at its current version; Aurora's startup firmware is
          updated by Aurora Installer's startup-firmware path.
        - Startup security changes need \(owner.username)'s password, in this Recovery.
        - To get macOS back you erase the Mac in DFU mode (a second Mac with Finder or
          Apple Configurator, or a Linux computer with idevicerestore) and restore it.
      To continue, type: \(MacOSRemoval.phrase)
      """)
    guard readLineTrimmed() == MacOSRemoval.phrase else {
      throw RecoveryFailure(message: "The confirmation didn’t match. macOS was not removed.")
    }
    var password = readSecret("Password for \(owner.username): ")
    defer { password.resetBytes(in: 0..<password.count) }
    try verifyOwnerPassword(owner, password)
    // The disk must still be the one reviewed, immediately before deletion.
    try MacOSRemoval.requireUnchanged(plan, now: try readWholeDisk(), installation: installation)
    var journal = MacOSRemoval.claimRecord(plan, removedAt: Date())
    journal["phase"] = "deleting"
    journal["kept"] = plan.kept.map { part -> [String: Any] in
      ["uuid": part.uuid, "offset": part.offset, "size": part.size]
    }
    try saveJSON(journal, to: wholeDiskJournal)
    do {
      try run(
        "/usr/sbin/diskutil", ["apfs", "deleteContainer", plan.partition.identifier],
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
    print(
      "macOS was removed. Restart into Aurora; it adds the freed space to Linux on its next start (or run `sudo aurora-whole-disk claim`)."
    )
  }

  /// The record Linux reads, written only after the deletion verified.
  private static func finishWholeDiskRemoval(_ plan: MacOSRemovalPlan, journal: [String: Any])
    throws
  {
    try MacOSRemoval.verifyRemoved(plan, after: try readWholeDisk())
    var record = journal
    record["phase"] = "removed"
    record.removeValue(forKey: "kept")
    try saveJSON(record, to: try esp().appendingPathComponent(claimRecordPath))
    var done = journal
    done["phase"] = "complete"
    try saveJSON(done, to: wholeDiskJournal)
  }

  /// A deletion interrupted after its journal was written: finish it only when
  /// the disk shows exactly the planned result.
  private static func resumeWholeDiskRemoval(_ installation: WholeDiskInstallation) throws
    -> String?
  {
    guard FileManager.default.fileExists(atPath: wholeDiskJournal.path) else { return nil }
    let data = try RecoveryAccountInstaller.protectedRead(wholeDiskJournal, limit: 1 << 16)
    guard let journal = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      journal["schema"] as? Int == 1, let phase = journal["phase"] as? String
    else {
      throw RecoveryFailure(message: "The macOS removal record is unreadable. Nothing was changed.")
    }
    if phase == "complete" { return "macOS was already removed from this Mac." }
    let layout = try readWholeDisk()
    let removed = journal["removedPartitionUUID"] as? String
    guard let removed, !layout.partitions.contains(where: { $0.uuid == removed }) else {
      // The container is still there: the deletion never happened.
      try FileManager.default.removeItem(at: wholeDiskJournal)
      return nil
    }
    let kept = (journal["kept"] as? [[String: Any]] ?? []).map {
      [
        ($0["uuid"] as? String) ?? "", "\(($0["offset"] as? NSNumber)?.uint64Value ?? 0)",
        "\(($0["size"] as? NSNumber)?.uint64Value ?? 0)",
      ]
    }
    try check(
      layout.partitions.map { [$0.uuid, String($0.offset), String($0.size)] } == kept,
      "The disk doesn’t match the interrupted removal’s record. Nothing more was changed; save Window → Installer Log and ask for help."
    )
    var record = journal
    record["phase"] = "removed"
    record.removeValue(forKey: "kept")
    try saveJSON(record, to: try esp().appendingPathComponent(claimRecordPath))
    var done = journal
    done["phase"] = "complete"
    try saveJSON(done, to: wholeDiskJournal)
    return "The interrupted removal of macOS is complete. Restart into Aurora."
  }
}
