#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativePeripheralInputPathTests: XCTestCase {
    private var macOSDirectory: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func supportedModels() throws -> [String] {
      let manifest = try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: macOSDirectory.appendingPathComponent("scripts/supported-models.json")))
      return try XCTUnwrap((manifest as? [String: Any])?["supported"] as? [String])
    }

    /// The decision for every supported Mac is the one the per-site
    /// `== "apple,j700"` comparisons made: only the MacBook Neo prepares its
    /// peripheral inputs from a sealed recipe.
    func testOnlyTheMacBookNeoPreparesItsPeripheralInputs() throws {
      let supported = try supportedModels()
      XCTAssertEqual(supported.count, Set(supported).count)
      XCTAssertTrue(supported.contains("apple,j700"))
      for device in supported {
        let expected = device == "apple,j700"
        XCTAssertEqual(
          NativePeripheralInputPath.needsPreparation(deviceIdentifier: device), expected, device)
        XCTAssertEqual(
          NativePeripheralInputPath.needsPreparation(machine: String(device.dropFirst(6))),
          expected, device)
        XCTAssertEqual(FirmwareExtractionPlan.hasBundledRecipe(for: device), expected, device)
      }
    }

    func testIdentifiersOutsideTheListDoNotPrepare() {
      for device in [
        "", "apple,", "apple,J700", "APPLE,j700", "apple,j700 ", "j700", "apple,j7000",
      ] {
        XCTAssertFalse(
          NativePeripheralInputPath.needsPreparation(deviceIdentifier: device), device)
      }
      XCTAssertFalse(NativePeripheralInputPath.needsPreparation(machine: "J700"))
      XCTAssertFalse(NativePeripheralInputPath.needsPreparation(machine: ""))
    }

    /// The fact and the recipe cannot drift apart: a Mac prepares exactly
    /// when the build can open a sealed recipe for it.
    func testTheDecisionIsTheBundledRecipe() throws {
      for device in try supportedModels() {
        let opens = (try? FirmwareExtractionPlan.bundled(for: device)) != nil
        XCTAssertEqual(
          NativePeripheralInputPath.needsPreparation(deviceIdentifier: device), opens, device)
      }
      let recipes = try FileManager.default.contentsOfDirectory(
        atPath: macOSDirectory.appendingPathComponent("Sources/AuroraFirmware/Resources").path
      ).filter { $0.hasSuffix("-ranges.json") }
      XCTAssertEqual(recipes, ["j700-25G83-ranges.json"])
    }
  }
#endif
