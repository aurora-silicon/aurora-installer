#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativeExperimentalHardwareTests: XCTestCase {
    private let mac27 = NativeInspectionHardware(
      chipID: 0x6040, bootVersion: "mBoot-20457.1.29", macOSVersion: "27.0",
      recoveryVersion: "26.1.0.0.0,0")

    private func payload() throws -> NativeInstallationMetadata {
      try NativeInstallationMetadata(
        data: Data(
          #"{"os_list":[{"omarchy_target":"apple-silicon-full-os","default_os_name":"Fixture","partitions":[{"size":"1GiB"}]}]}"#
            .utf8))
    }

    func testSupportedMacsAreNeverOffered() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let m2 = NativeInspectionHardware(
        chipID: 0x8112, bootVersion: "iBoot-13822.61.10", macOSVersion: "26.0",
        recoveryVersion: "25.1.354.0.0,0")
      XCTAssertEqual(
        NativeExperimentalHardware.refusal("apple,j413", hardware: m2, policy: policy), .supported)
      XCTAssertEqual(
        NativeExperimentalHardware.refusal("apple,j616s", hardware: mac27, policy: policy),
        .supported)
    }

    func testKnownBrokenStaysRefusedWithItsReason() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let t6000 = NativeInspectionHardware(
        chipID: 0x6000, bootVersion: "iBoot-13822.61.10", macOSVersion: "26.0",
        recoveryVersion: "25.1.354.0.0,0")
      for device in ["apple,j316s", "apple,j314s", "apple,j399x"] {
        guard
          case .knownBroken(let reason)? = NativeExperimentalHardware.refusal(
            device, hardware: t6000, policy: policy)
        else { return XCTFail(device) }
        XCTAssertTrue(reason.contains("4,390,912"), device)
      }
    }

    func testAnUnknownBoardOnAKnownChipIsOfferedWithWarnings() throws {
      let policy = try NativeInspectionPolicy.sealed()
      XCTAssertNil(
        NativeExperimentalHardware.refusal("apple,j614s", hardware: mac27, policy: policy))
      let assessment = try NativeExperimentalHardware.assess(
        "apple,j614s", hardware: mac27, policy: policy, metadata: payload(), level: .fullSend)
      XCTAssertEqual(assessment.firmwareVersion, "26.6.2")
      XCTAssertTrue(assessment.policy.supports("apple,j614s", hardware: mac27))
      XCTAssertFalse(policy.supports("apple,j614s", hardware: mac27))
      XCTAssertTrue(assessment.warnings.contains { $0.contains("not listed for this board") })
      let selected = try NativeFirmwareSelection.choose(
        deviceIdentifier: "apple,j614s",
        facts: .init(deviceIdentifier: "apple,j614s", hardware: mac27), metadata: payload(),
        policy: assessment.policy, experimental: true)
      XCTAssertEqual(selected.version, "26.6.2")
      XCTAssertThrowsError(
        try NativeFirmwareSelection.choose(
          deviceIdentifier: "apple,j614s",
          facts: .init(deviceIdentifier: "apple,j614s", hardware: mac27), metadata: payload(),
          policy: assessment.policy))
    }

    func testAnUnknownChipGetsTheNewestStubItsFirmwareAccepts() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let unknown = NativeInspectionHardware(
        chipID: 0x9001, bootVersion: "mBoot-20457.1.29", macOSVersion: "27.0",
        recoveryVersion: "26.1.0.0.0,0")
      let assessment = try NativeExperimentalHardware.assess(
        "apple,j999", hardware: unknown, policy: policy, metadata: payload(),
        level: .bootloaderOnly)
      XCTAssertEqual(assessment.firmwareVersion, "26.6.2")
      XCTAssertEqual(assessment.policy.chipMinimum["36865"], "26.6.2")
      let old = NativeInspectionHardware(
        chipID: 0x9001, bootVersion: "iBoot-1", macOSVersion: "11.0",
        recoveryVersion: "20.1.0.0.0,0")
      XCTAssertThrowsError(
        try NativeExperimentalHardware.assess(
          "apple,j999", hardware: old, policy: policy, metadata: payload(), level: .fullSend))
    }

    func testStageTwoPrefersOwnThenSameChipThenNone() {
      let files = [
        "esp/m1n1/boot-j616s.bin": [["apple,j616s", "apple,t6040", "apple,arm-platform"]],
        "esp/m1n1/boot-j773s.bin": [["apple,j773s", "apple,t6040", "apple,arm-platform"]],
        "esp/m1n1/boot-j413.bin": [["apple,j413", "apple,t8112", "apple,arm-platform"]],
      ]
      XCTAssertEqual(
        NativeExperimentalHardware.stage2Source(
          deviceIdentifier: "apple,j614s", chipID: 0x6040, boardFiles: files),
        .sibling(board: "j616s", member: "esp/m1n1/boot-j616s.bin"))
      XCTAssertEqual(
        NativeExperimentalHardware.stage2Source(
          deviceIdentifier: "apple,j413", chipID: 0x8112, boardFiles: files),
        .own(member: "esp/m1n1/boot-j413.bin"))
      XCTAssertEqual(
        NativeExperimentalHardware.stage2Source(
          deviceIdentifier: "apple,j999", chipID: 0x9001, boardFiles: files), .none)
    }

    func testRetargetNamesThisBoardFirstAndKeepsTheTree() throws {
      let tree = Self.fdt(["apple,j616s", "apple,t6040", "apple,arm-platform"])
      var stage2 = Data("aura".utf8) + Data("STACKBOT".utf8)
      stage2 += tree
      stage2 += Data([0x1f, 0x8b, 0x08, 0])
      let retargeted = try NativeExperimentalHardware.retarget(
        stage2: stage2, sibling: "j616s", deviceIdentifier: "apple,j614s")
      XCTAssertEqual(
        NativeExperimentalHardware.deviceTrees(inStage2: retargeted),
        [["apple,j614s", "apple,j616s", "apple,t6040", "apple,arm-platform"]])
      XCTAssertTrue(retargeted.suffix(4).elementsEqual([0x1f, 0x8b, 0x08, 0]))
      XCTAssertThrowsError(
        try NativeExperimentalHardware.retarget(
          stage2: stage2, sibling: "j413", deviceIdentifier: "apple,j614s"))
    }

    func testTheRecordAndReportSayExperimental() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let assessment = try NativeExperimentalHardware.assess(
        "apple,j614s", hardware: mac27, policy: policy, metadata: payload(),
        level: .bootloaderOnly)
      let record =
        try JSONSerialization.jsonObject(
          with: NativeExperimentalHardware.record(
            assessment, stage2: .sibling(board: "j616s", member: "esp/m1n1/boot-j616s.bin"),
            stage1Bytes: 1, stage1SHA256: nil)) as! [String: Any]
      XCTAssertEqual(record["experimental"] as? Bool, true)
      XCTAssertEqual(record["level"] as? String, "bootloader-only")
      XCTAssertEqual(record["proxy_marker"] as? Bool, true)
      let facts = ExperimentalBringUpFacts(
        model: "Fixture", deviceIdentifier: "apple,j614s", chipID: 0x6040, systemBoot: "b",
        systemMacOS: "27.0", stubBoot: nil, stubMacOS: nil, level: .bootloaderOnly,
        stage2: "sibling", stage1: nil, warnings: ["w"])
      XCTAssertTrue(facts.report.contains("aura-proxy"))
      XCTAssertTrue(facts.report.contains("Nothing in this report was sent anywhere."))
    }

    /// A one-node tree with only a root compatible property.
    static func fdt(_ compatible: [String]) -> Data {
      func be(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
      }
      let strings = Array("compatible\0".utf8)
      var value = compatible.flatMap { Array($0.utf8) + [0] }
      let length = value.count
      value += [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
      let body = be(1) + [0, 0, 0, 0] + be(3) + be(length) + be(0) + value + be(2) + be(9)
      let reserve = [UInt8](repeating: 0, count: 16)
      let structOffset = 40 + reserve.count
      let total = structOffset + body.count + strings.count
      let header =
        be(0xd00d_feed) + be(total) + be(structOffset) + be(structOffset + body.count) + be(40)
        + be(17) + be(16) + be(0) + be(strings.count) + be(body.count)
      return Data(header + reserve + body + strings)
    }
  }
#endif
