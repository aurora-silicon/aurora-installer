import Foundation

/// What a finished upgrade records (UPGRADE-FLOW.md section 4.2 step 8),
/// kept apart from the commands so it can be checked on its own: the EFI
/// partition's `asahi/stub_info.json` and `aurora/upgrade/journal.json`, and
/// the Recovery baseline `aura recover` compares.
public enum StubUpgradeRecords {
  public enum Failure: Error, Equatable {
    case invalid
  }

  /// `asahi/stub_info.json` for the new firmware: the plan's `system_version`
  /// and `manifest_info` (as the installer writes them), everything else as it was.
  public static func stubInfo(_ old: Data, plan: RestoreImageStubPlan, group: String) throws
    -> Data
  {
    guard var info = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
      let new = try? JSONSerialization.jsonObject(with: plan.stubInfo) as? [String: Any]
    else { throw Failure.invalid }
    info["system_version"] = new["system_version"]
    info["manifest_info"] = new["manifest_info"]
    info["vgid"] = group
    return try JSONSerialization.data(
      withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  /// aurora-upgrade's journal with this visit's step and `state` "upgraded",
  /// which `aurora-upgrade finish` waits for (with the new firmware version).
  /// A journal that is missing is started; the step is recorded once.
  public static func espJournal(_ old: Data?, request: StubUpgradeRequest, time: Int) throws
    -> Data
  {
    var value: [String: Any] = ["schema": StubUpgradeRequest.schema, "steps": [[String: Any]]()]
    if let old {
      guard let parsed = try? JSONSerialization.jsonObject(with: old) as? [String: Any] else {
        throw Failure.invalid
      }
      value = parsed
    }
    var steps = value["steps"] as? [[String: Any]] ?? []
    if !steps.contains(where: {
      $0["kind"] as? String == "recovery-upgraded" && $0["build"] as? String == request.target.build
    }) {
      steps.append([
        "kind": "recovery-upgraded", "time": time, "build": request.target.build,
        "version": request.target.version, "group": request.group,
      ])
    }
    value["steps"] = steps
    value["state"] = "upgraded"
    value["plan_sha256"] = request.planSHA256
    return try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  }

  /// Records `stage1` (the enrolled Stage 1 before its keys, as Update
  /// startup software records a new one) as the Recovery baseline's
  /// `macho/aura-boot.macho` in `payloads` (InstallData/AuraPayloads): the
  /// file first, then its manifest entry, so `aura recover` and the pending
  /// update check agree with the receipt again. Other entries are kept.
  public static func updateBaseline(payloads: URL, stage1: Data, path: String) throws {
    let manifestURL = payloads.appendingPathComponent("manifest.json")
    guard
      var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        as? [String: Any], var files = manifest["files"] as? [String: [String: Any]]
    else { throw Failure.invalid }
    var entry = files[path] ?? [:]
    entry["bytes"] = stage1.count
    entry["sha256"] = RecoveryDigest.sha256(stage1)
    files[path] = entry
    manifest["files"] = files
    let file = payloads.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try RecoveryFileTransaction.write(stage1, to: file)
    try RecoveryFileTransaction.write(
      JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
      to: manifestURL)
  }
}
