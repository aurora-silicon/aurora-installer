import Foundation

/// A Stage 1 the macOS installer staged in this installation's Recovery
/// payload that differs from the enrolled one. Recovery enrolls only it: the
/// EFI partition, Stage 2 and Linux stay as they are.
struct Stage1Reenrollment: Equatable {
  let mode: AuraBootMode
  /// The staged object's hash, which the receipt records once it's enrolled.
  let stage1SHA256: String
  /// The ESP file it chainloads, from install-config.json.
  let stage2Path: String
}

enum Stage1ReenrollmentError: Error, Equatable, LocalizedError {
  case wrongMode
  case tooLarge(bytes: Int)
  case wrongTarget
  case missingStage2(path: String)

  var errorDescription: String? {
    switch self {
    case .wrongMode:
      return
        "This Mac can't start from the startup software in this installation's files. Nothing was changed."
    case .tooLarge(let bytes):
      return
        "The new startup software is \((bytes + 999_999) / 1_000_000) MB, larger than Recovery accepts. Nothing was changed."
    case .wrongTarget:
      return
        "The new startup software doesn't load this installation's startup partition. Run Update Boot Loader in the Aurora installer again. Nothing was changed."
    case .missingStage2(let path):
      return
        "The startup partition has no \(path) for the new startup software to load. Start Linux and install its updates first. Nothing was changed."
    }
  }
}

extension Stage1Reenrollment {
  /// Matches the installer's limit for a Stage 1.
  static let maximumBytes = 64 << 20

  /// The staged Stage 1 when it isn't the enrolled one. Reads only records:
  /// the bytes are checked against the manifest before anything is enrolled.
  static func pending(
    receipt: [String: Any]?, hasPendingInstallation: Bool, bootMode: String, stage2Path: String,
    manifest: [String: Any]?
  ) -> Stage1Reenrollment? {
    guard !hasPendingInstallation, let receipt, receipt["status"] as? String == "installed",
      let mode = AuraBootMode(rawValue: bootMode), let manifest,
      manifest["defaultMode"] as? String == bootMode,
      (manifest["modes"] as? [String: [String: Any]])?[bootMode]?["espPath"] as? String
        == stage2Path,
      let staged = (manifest["files"] as? [String: [String: Any]])?[mode.stage1Path]?["sha256"]
        as? String
    else { return nil }
    let enrolled =
      receipt["stage1SHA256"] as? String == staged && receipt["stage2Path"] as? String == stage2Path
      && receipt["mode"] as? String == bootMode
    return enrolled
      ? nil : Stage1Reenrollment(mode: mode, stage1SHA256: staged, stage2Path: stage2Path)
  }

  /// Checks the staged bytes before any boot policy change, returning nil when
  /// the receipt already records them. `stage2Bytes` is the size of the ESP file
  /// it loads, nil when there's none.
  static func verify(
    stage1: Data, mode: AuraBootMode, chipID: UInt64, espUUID: String, stage2Path: String,
    receipt: [String: Any], stage2Bytes: Int?
  ) throws -> Stage1Reenrollment? {
    guard AuraBootMode.required(chipID: chipID) == mode else {
      throw Stage1ReenrollmentError.wrongMode
    }
    guard !stage1.isEmpty, stage1.count <= maximumBytes else {
      throw Stage1ReenrollmentError.tooLarge(bytes: stage1.count)
    }
    if mode == .macho { try MachOBootObject.check(stage1) }
    guard let configuration = try? Stage1Configuration.read(stage1),
      configuration.espUUID.lowercased() == espUUID.lowercased(),
      configuration.stage2Path == stage2Path,
      stage2Path == AuraStage1Format.stage2Path(machO: mode == .macho)
    else { throw Stage1ReenrollmentError.wrongTarget }
    let hash = RecoveryDigest.sha256(stage1)
    if receipt["stage1SHA256"] as? String == hash, receipt["stage2Path"] as? String == stage2Path,
      receipt["mode"] as? String == mode.rawValue
    {
      return nil
    }
    let limit =
      mode == .macho ? Int(ExecuteWindow.auraSlot) : 64 << 20
    guard let stage2Bytes, stage2Bytes > 0, stage2Bytes <= limit else {
      throw Stage1ReenrollmentError.missingStage2(path: stage2Path)
    }
    return Stage1Reenrollment(mode: mode, stage1SHA256: hash, stage2Path: stage2Path)
  }

  /// The receipt once this Stage 1 is enrolled; every other field is kept.
  func receipt(after receipt: [String: Any], stage2SHA256: String) -> [String: Any] {
    var updated = receipt
    updated["mode"] = mode.rawValue
    updated["stage1SHA256"] = stage1SHA256
    updated["stage2Path"] = stage2Path
    updated["stage2SHA256"] = stage2SHA256
    if let window = mode.executeWindowSize {
      updated["executeWindowSize"] = window
    } else {
      updated.removeValue(forKey: "executeWindowSize")
    }
    return updated
  }
}

/// Commands and writes are injected so the order can be tested without bputil,
/// kmutil or a live volume. Nothing is recorded unless enrollment succeeded; a
/// kmutil that stopped leaves the receipt as it was, so the next attempt
/// enrolls again.
enum Stage1ReenrollmentRunner {
  static func run(
    stage: () throws -> Void, authorizePolicy: () throws -> Void, enroll: () throws -> Void,
    record: () throws -> Void, finish: () throws -> Void
  ) throws {
    try stage()
    try authorizePolicy()
    try enroll()
    try record()
    try finish()
  }
}
