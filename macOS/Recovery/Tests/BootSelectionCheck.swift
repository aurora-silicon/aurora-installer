import Foundation

@main struct BootSelectionCheck {
  /// The chips the conformance fixtures record, so a newly recorded Mac is checked too.
  static func recordedChips() throws -> [UInt64] {
    let constraints = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../test/conformance/fixtures/constraints.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: constraints))
    guard let chips = (object as? [String: Any])?["chip_ids"] as? [String: Int], !chips.isEmpty
    else { preconditionFailure("constraints.json has no chip_ids") }
    return chips.values.map { UInt64($0) }
  }

  static func main() throws {
    precondition(
      RecoveryBootPolicy.authorizationArguments(groupUUID: "target") == ["-nc", "-v", "target"])
    precondition(
      RecoveryBootPolicy.authorizationArguments(
        groupUUID: "target", allowCustomBootArguments: true) == ["-nca", "-v", "target"])
    let volume = "/Volumes/Volume With Spaces"
    // No mode enrolls a raw image: kmutil always gets the Mach-O boot object.
    for mode in AuraBootMode.allCases {
      let stage1 = "/payloads/" + mode.stage1Path
      let arguments = mode.enrollmentArguments(stage1: stage1, volume: volume)
      precondition(!arguments.contains("--raw"), mode.rawValue)
      precondition(!arguments.contains("--entry-point"), mode.rawValue)
      precondition(!arguments.contains("--lowest-virtual-address"), mode.rawValue)
      precondition(mode.stage1Path == "macho/aura-boot.macho", mode.rawValue)
    }
    let window: [UInt64] = [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050, 0x6051, 0x6052, 0x8150]
    let standard: [UInt64] = [
      0x8103, 0x6000, 0x6001, 0x6002, 0x8112, 0x6020, 0x6021, 0x6022, 0x8122, 0x6030, 0x6031,
      0x6032, 0x6034,
    ]
    let recorded = try recordedChips()
    precondition(Set(recorded).isSubset(of: Set(window + standard)), "a recorded chip is unlisted")
    for chip in Set(window + standard + recorded) {
      let mode = AuraBootMode.required(chipID: chip)
      let stage1 = "/payloads/" + mode.stage1Path
      let arguments = mode.enrollmentArguments(stage1: stage1, volume: volume)
      precondition(!arguments.contains("--raw"), String(chip, radix: 16))
      if window.contains(chip) {
        // M4 and later: the object padded for the window, stored compressed, loading boot-ctxr.bin.
        precondition(mode == .macho, String(chip, radix: 16))
        precondition(mode.executeWindowSize == 128 << 20)
        precondition(arguments == ["configure-boot", "-c", stage1, "-v", volume, "--compress"])
        precondition(
          AuraStage1Format.stage2Path(executeWindow: mode == .macho) == "m1n1/boot-ctxr.bin")
      } else {
        // M1 to M3: the same object unpadded, as kmutil takes any boot object, loading boot.bin.
        precondition(mode == .standard, String(chip, radix: 16))
        precondition(mode.executeWindowSize == nil)
        precondition(arguments == ["configure-boot", "-c", stage1, "-v", volume])
        precondition(AuraStage1Format.stage2Path(executeWindow: mode == .macho) == "m1n1/boot.bin")
      }
    }
    // The payload keeps one Stage 2 under one name; the configuration says where it goes.
    for mode in AuraBootMode.allCases {
      precondition(mode.stage2Path == "raw/boot.bin")
      let restored = try JSONDecoder().decode(
        BootSelection.self, from: JSONEncoder().encode(BootSelection(mode: mode)))
      precondition(restored.mode == mode)
    }
    // An installation an earlier installer recorded as raw enrolls the unpadded object.
    precondition(AuraBootMode(recorded: "raw") == .standard)
    precondition(AuraBootMode(recorded: "macho-standard") == .standard)
    precondition(AuraBootMode(recorded: "macho") == .macho)
    precondition(AuraBootMode(recorded: "other") == nil)
    let legacy = try JSONDecoder().decode(BootSelection.self, from: Data(#"{"mode":"raw"}"#.utf8))
    precondition(legacy.mode == .standard)
    let encoded = try JSONEncoder().encode(BootSelection(mode: .standard))
    precondition(String(decoding: encoded, as: UTF8.self) == #"{"mode":"macho-standard"}"#)
    precondition(AuraStage1Format.stage2Path(executeWindow: true) == "m1n1/boot-ctxr.bin")
    precondition(AuraStage1Format.stage2Path(executeWindow: false) == "m1n1/boot.bin")
    print(
      "PASS no mode or chip enrolls a raw image; M4 and later pad and compress, M1 to M3 enroll the unpadded object; recorded raw reads as unpadded; Stage 2 path per mode; paths with spaces; JSON round trip"
    )
  }
}
