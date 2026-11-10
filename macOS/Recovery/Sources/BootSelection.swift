import Foundation

enum AuraBootMode: String, Codable, CaseIterable {
  /// The unpadded Mach-O boot object, on chips without an execute window (M1 to M3).
  case standard = "macho-standard"
  /// The Mach-O boot object padded for the execute window (M4 and later).
  case macho

  /// A mode recorded in install-config.json or a receipt. Earlier installers
  /// recorded "raw" on M1 to M3; such an installation now enrolls the unpadded
  /// object, which loads the same Stage 2.
  init?(recorded: String) {
    if recorded == "raw" { self = .standard } else { self.init(rawValue: recorded) }
  }

  init(from decoder: Decoder) throws {
    let recorded = try decoder.singleValueContainer().decode(String.self)
    guard let mode = AuraBootMode(recorded: recorded) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unknown boot mode \(recorded)"))
    }
    self = mode
  }

  /// The only mode a chip may enroll.
  static func required(chipID: UInt64) -> AuraBootMode {
    AuraStage1Format.usesExecuteWindow(chipID: chipID) ? .macho : .standard
  }

  /// What every mode enrolls: the filled boot object.
  var stage1Path: String { "macho/aura-boot.macho" }
  /// The filled raw image the object carries. Recovery keeps it to check the
  /// object and for Reset; it is never enrolled.
  static let rawStage1Path = "raw/aura-raw.bin"

  /// The Recovery payload keeps the Stage 2 this installation chainloads under
  /// one name in both modes. `stage2Path` in its configuration says where it goes.
  var stage2Path: String { "raw/boot.bin" }

  /// The code window the object is padded for. An unpadded object has none.
  var executeWindowSize: UInt64? { self == .macho ? ExecuteWindow.size : nil }

  /// kmutil enrolls the object as a Mach-O boot object in every mode; nothing
  /// enrolls the raw image. A padded object is stored with `--compress` (LZFSE
  /// in Preboot, as the stock kernelcache is stored).
  func enrollmentArguments(stage1: String, volume: String) -> [String] {
    var arguments = ["configure-boot", "-c", stage1, "-v", volume]
    if self == .macho { arguments.append("--compress") }
    return arguments
  }
}

struct BootSelection: Codable {
  let mode: AuraBootMode
}

enum RecoveryBootPolicy {
  static func authorizationArguments(
    groupUUID: String, allowCustomBootArguments: Bool = false
  ) -> [String] {
    [allowCustomBootArguments ? "-nca" : "-nc", "-v", groupUUID]
  }
}
