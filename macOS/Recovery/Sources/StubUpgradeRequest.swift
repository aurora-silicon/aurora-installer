import Foundation

/// The startup firmware upgrade Linux staged (`aurora-upgrade stage`,
/// tools/upgrade/aurora_upgrade.py `Plan.to_json`): the same JSON in
/// `Aurora/Recovery/UpgradeData/upgrade-config.json` on the stub's System
/// volume and `aurora/upgrade/request.json` on the EFI partition, ending in
/// `plan_sha256`, the SHA-256 of the rest as Python's `json.dumps(...,
/// sort_keys=True)` writes it. Only an in-place upgrade is read here: a
/// second startup volume ("slot") has its own Recovery do the work.
public struct StubUpgradeRequest: Equatable {
  public struct Target: Equatable {
    public let version: String
    public let build: String
    public let url: URL
    public let sourceBytes: Int
    /// The restore image's BuildManifest.plist SHA-256, in hex.
    public let manifestSHA256: String
    public let minimumBoot: String
    public let caution: String
  }

  public struct Space: Equatable {
    public let container: Int
    public let used: Int
    public let recoveryImage: Int
    public let preboot: Int
    public let newRecoveryImage: Int
    public let peak: Int
  }

  public enum Failure: Error, Equatable {
    /// Not the JSON aurora-upgrade writes, or not an in-place upgrade.
    case invalid
    /// `plan_sha256` isn't the digest of the rest.
    case digest
  }

  /// The schema aurora-upgrade writes.
  public static let schema = 1
  public static let configPath = "Aurora/Recovery/UpgradeData/upgrade-config.json"
  public static let stage1Directory = "Aurora/Recovery/UpgradeData"
  public static let espRequestPath = "aurora/upgrade/request.json"
  public static let espJournalPath = "aurora/upgrade/journal.json"

  public let board: String
  public let chipID: UInt64
  public let systemFirmware: String
  public let currentVersion: String
  public let currentBuild: String
  /// The stub's APFS volume group, upper case.
  public let group: String
  public let target: Target
  public let space: Space
  /// The EFI partition's GPT partition UUID, lower case.
  public let espPartitionUUID: String
  /// The release's unfilled Stage 1, relative to the UpgradeData directory.
  public let stage1Path: String
  public let stage1SHA256: String
  public let stage1Version: String
  public let planSHA256: String

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= 65536,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Failure.invalid }
    func dictionary(_ value: Any?, _ keys: Set<String>) throws -> [String: Any] {
      guard let value = value as? [String: Any], Set(value.keys) == keys else {
        throw Failure.invalid
      }
      return value
    }
    func string(_ value: Any?) throws -> String {
      guard let value = value as? String, !value.utf8.contains(0) else { throw Failure.invalid }
      return value
    }
    func integer(_ value: Any?) throws -> Int {
      guard let value = value as? Int, value >= 0 else { throw Failure.invalid }
      return value
    }
    func uuid(_ value: Any?) throws -> String {
      let text = try string(value)
      guard let parsed = UUID(uuidString: text),
        parsed.uuidString.lowercased() == text.lowercased(),
        parsed.uuidString != "00000000-0000-0000-0000-000000000000"
      else { throw Failure.invalid }
      return text
    }
    let top = try dictionary(
      object,
      [
        "schema", "mode", "board", "chip", "system_firmware", "current", "target", "space",
        "esp_partuuid", "stage1", "plan_sha256",
      ])
    guard try integer(top["schema"]) == schema, try string(top["mode"]) == "in-place" else {
      throw Failure.invalid
    }
    let current = try dictionary(top["current"], ["version", "build", "group", "device"])
    let target = try dictionary(
      top["target"],
      [
        "version", "build", "url", "source_bytes", "manifest_sha256", "minimum_boot",
        "stub_bytes", "caution",
      ])
    let space = try dictionary(
      top["space"],
      ["container", "used", "recovery_image", "preboot", "new_recovery_image", "peak"])
    let stage1 = try dictionary(top["stage1"], ["path", "sha256", "version"])
    let board = try string(top["board"])
    let chip = try string(top["chip"])
    let manifest = try string(target["manifest_sha256"])
    let digest = try string(top["plan_sha256"])
    let stage1Digest = try string(stage1["sha256"])
    let stage1Path = try string(stage1["path"])
    func hex(_ value: String) -> Bool {
      value.utf8.count == 64
        && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
    guard board.range(of: #"\A[jk][0-9]+[a-z]*\z"#, options: .regularExpression) != nil,
      chip.hasPrefix("0x"), let chipID = UInt64(chip.dropFirst(2), radix: 16),
      "0x" + String(chipID, radix: 16) == chip,
      manifest.hasPrefix("sha256:"), hex(String(manifest.dropFirst(7))), hex(digest),
      hex(stage1Digest), RestoreImageDirectory.safeRelative(Array(stage1Path.utf8)),
      let url = URLComponents(string: try string(target["url"])), url.scheme == "https",
      url.host == RestoreImageRemote.imageHost, url.port == nil, url.user == nil,
      url.password == nil, url.query == nil, url.fragment == nil, let location = url.url
    else { throw Failure.invalid }
    var unsigned = object
    unsigned.removeValue(forKey: "plan_sha256")
    guard let canonical = Self.pythonJSON(unsigned) else { throw Failure.invalid }
    guard RecoveryDigest.sha256(Data(canonical.utf8)) == digest else { throw Failure.digest }
    return Self(
      board: board, chipID: chipID, systemFirmware: try string(top["system_firmware"]),
      currentVersion: try string(current["version"]), currentBuild: try string(current["build"]),
      group: try uuid(current["group"]).uppercased(),
      target: Target(
        version: try string(target["version"]), build: try string(target["build"]),
        url: location, sourceBytes: try integer(target["source_bytes"]),
        manifestSHA256: String(manifest.dropFirst(7)),
        minimumBoot: try string(target["minimum_boot"]), caution: try string(target["caution"])),
      space: Space(
        container: try integer(space["container"]), used: try integer(space["used"]),
        recoveryImage: try integer(space["recovery_image"]), preboot: try integer(space["preboot"]),
        newRecoveryImage: try integer(space["new_recovery_image"]),
        peak: try integer(space["peak"])),
      espPartitionUUID: try uuid(top["esp_partuuid"]).lowercased(),
      stage1Path: stage1Path, stage1SHA256: stage1Digest,
      stage1Version: try string(stage1["version"]), planSHA256: digest)
  }

  /// `value` as Python's `json.dumps(value, sort_keys=True)` writes it, for
  /// the types a plan holds (objects, arrays, strings, non-negative integers);
  /// nil for anything else.
  static func pythonJSON(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
      // Python sorts keys by code point.
      let keys = object.keys.sorted {
        Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(
          $1.unicodeScalars.map(\.value))
      }
      var parts = [String]()
      for key in keys {
        guard let item = pythonJSON(object[key]!) else { return nil }
        parts.append(pythonString(key) + ": " + item)
      }
      return "{" + parts.joined(separator: ", ") + "}"
    }
    if let array = value as? [Any] {
      var parts = [String]()
      for item in array {
        guard let text = pythonJSON(item) else { return nil }
        parts.append(text)
      }
      return "[" + parts.joined(separator: ", ") + "]"
    }
    if let text = value as? String { return pythonString(text) }
    if let number = value as? Int, number >= 0 { return String(number) }
    return nil
  }

  /// A string as `json.dumps` writes it with `ensure_ascii`: printable ASCII
  /// as it is, the usual short escapes, everything else as UTF-16 `\uXXXX`.
  static func pythonString(_ text: String) -> String {
    var out = "\""
    for unit in text.utf16 {
      switch unit {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
      default:
        let digits = String(unit, radix: 16)
        out += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
      }
    }
    return out + "\""
  }

  /// The Mac's device class as restore images name it.
  public var deviceClass: String { board + "ap" }
}
