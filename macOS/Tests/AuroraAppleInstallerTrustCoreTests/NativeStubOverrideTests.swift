#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativeStubOverrideTests: XCTestCase {
    private let neo = NativeInspectionHardware(
      chipID: 0x8140, bootVersion: "mBoot-18000.161.10", macOSVersion: "26.6.2",
      recoveryVersion: "25.7.83.0.0,0")
    private let oldNeo = NativeInspectionHardware(
      chipID: 0x8140, bootVersion: "mBoot-18000.161.9", macOSVersion: "26.6",
      recoveryVersion: "25.7.72.0.0,0")

    private func metadata(supported: [String]?) throws -> NativeInstallationMetadata {
      var template: [String: Any] = [
        "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
        "partitions": [["size": "1GiB"]],
      ]
      if let supported { template["supported_fw"] = supported }
      return try NativeInstallationMetadata(
        data: JSONSerialization.data(withJSONObject: ["os_list": [template]]))
    }

    private func choose(
      _ hardware: NativeInspectionHardware, supported: [String]? = nil,
      override: StubOverrideChoice?
    ) throws -> NativeFirmwareSelection {
      try NativeFirmwareSelection.choose(
        deviceIdentifier: "apple,j700",
        facts: .init(deviceIdentifier: "apple,j700", hardware: hardware),
        metadata: metadata(supported: supported), policy: NativeInspectionPolicy.sealed(),
        stubOverride: override)
    }

    func testTheCandidatesAreThisMacsPolicyEntriesOnly() throws {
      let policy = try NativeInspectionPolicy.sealed()
      XCTAssertEqual(
        try NativeStubOverride.candidates(
          deviceIdentifier: "apple,j700", hardware: neo, policy: policy),
        [
          StubOverrideChoice(version: "26.6", build: "25G72"),
          StubOverrideChoice(version: "26.6.2", build: "25G83"),
        ])
      // Every candidate of every Mac the policy knows is one of its entries.
      let known = Set(policy.firmware.map(\.stubChoice))
      for (model, _) in policy.devices {
        for (chip, _) in policy.chipMinimum {
          let hardware = NativeInspectionHardware(
            chipID: UInt64(chip)!, bootVersion: nil, macOSVersion: nil, recoveryVersion: nil)
          let choices =
            (try? NativeStubOverride.candidates(
              deviceIdentifier: "apple," + model, hardware: hardware, policy: policy)) ?? []
          XCTAssertTrue(Set(choices).isSubset(of: known), model)
        }
      }
    }

    func testNoOverrideKeepsTheDefault() throws {
      let standard = try choose(neo, override: nil)
      XCTAssertEqual(standard.version, "26.6.2")
      XCTAssertEqual(standard.stubChoice, StubOverrideChoice(version: "26.6.2", build: "25G83"))
      // Naming the default is the default.
      XCTAssertEqual(try choose(neo, override: standard.stubChoice), standard)
    }

    func testTheOverridePicksTheNamedEntryAndKeepsItsChecks() throws {
      let picked = try choose(neo, override: StubOverrideChoice(version: "26.6", build: "25G72"))
      XCTAssertEqual(picked.version, "26.6")
      XCTAssertTrue(picked.sourceURL.lastPathComponent.hasSuffix("_25G72_Restore.ipsw"))
      XCTAssertEqual(picked.stubBytes, 5_999_951_872)
      // The entry's own minimums still apply: an older Neo is told to update.
      XCTAssertThrowsError(
        try choose(oldNeo, override: StubOverrideChoice(version: "26.6.2", build: "25G83"))
      ) {
        XCTAssertEqual(
          $0 as? NativeFirmwareSelectionError, .macOSUpdateRequired(version: "26.6.2"))
      }
    }

    func testAnUnknownOrUnreleasedOverrideIsRefused() throws {
      XCTAssertThrowsError(
        try choose(neo, override: StubOverrideChoice(version: "27.2", build: "26B123"))
      ) {
        guard
          case .stubOverride(.unknown(let requested, let known))? =
            $0 as? NativeFirmwareSelectionError
        else { return XCTFail("\($0)") }
        XCTAssertEqual(requested, "macOS 27.2 (26B123)")
        XCTAssertEqual(known, ["macOS 26.6 (25G72)", "macOS 26.6.2 (25G83)"])
      }
      XCTAssertThrowsError(
        try choose(
          neo, supported: ["26.6"], override: StubOverrideChoice(version: "26.6.2", build: "25G83"))
      ) {
        XCTAssertEqual(
          $0 as? NativeFirmwareSelectionError,
          .stubOverride(.notInRelease("macOS 26.6.2 (25G83)")))
      }
    }

    func testResolveTakesAVersionOrABuildAndRefusesTheRest() throws {
      let policy = try NativeInspectionPolicy.sealed()
      func resolve(_ text: String) throws -> StubOverrideChoice {
        try NativeStubOverride.resolve(
          text, deviceIdentifier: "apple,j700", hardware: neo, policy: policy)
      }
      XCTAssertEqual(try resolve("26.6"), StubOverrideChoice(version: "26.6", build: "25G72"))
      XCTAssertEqual(try resolve("25g83"), StubOverrideChoice(version: "26.6.2", build: "25G83"))
      XCTAssertThrowsError(try resolve("26.7")) {
        XCTAssertTrue(
          ($0 as? NativeStubOverrideError)?.message.contains("not one this Mac’s policy knows")
            ?? false)
      }
    }

    func testTheWarningNamesBothStubs() {
      XCTAssertEqual(
        NativeStubOverride.warning(
          chosen: StubOverrideChoice(version: "26.6", build: "25G72"),
          default: StubOverrideChoice(version: "26.6.2", build: "25G83")),
        "macOS stub override: 26.6 (25G72) instead of the default 26.6.2 (25G83); this combination is untested"
      )
    }

    func testTheBuildComesFromThePinOrTheRestoreImageName() {
      XCTAssertEqual(
        NativeStubOverride.build(
          inSourceURL: "https://updates.cdn-apple.com/x/UniversalMac_26.6.2_25G83_Restore.ipsw"),
        "25G83")
      XCTAssertEqual(
        NativeStubOverride.build(inSourceURL: "https://updates.cdn-apple.com/x/f6d1.zip"), "")
    }
  }
#endif
