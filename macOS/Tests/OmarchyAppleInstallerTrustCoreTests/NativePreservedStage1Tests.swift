#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedStage1Tests: XCTestCase {
    func testModernAndLegacyStageOneRequireAnExactExistingBootImage() async throws {
      for device in ["apple,j700", "apple,j314s"] {
        let plan = try await NativeESPFileTests.plan(deviceIdentifier: device)
        let uuid = UUID().uuidString.lowercased()
        let installed =
          plan.usesLegacyStage1
          ? try NativeLegacyStage1.fill(
            plan.stage1, uuid: uuid, path: "m1n1/boot.bin")
          : try NativeBootChain.fillStage1(
            plan.stage1, uuid: uuid, path: "m1n1/boot.bin",
            windowMilliseconds: plan.windowMilliseconds)
        let admitted = try plan.admitPreservedStage1(installed, espUUID: uuid)
        XCTAssertEqual(admitted.bytes, installed.count)
        XCTAssertEqual(admitted.sha256, NativeStubFileStore.hash(installed))

        var changed = installed
        changed[0] ^= 1
        XCTAssertThrowsError(try plan.admitPreservedStage1(changed, espUUID: uuid))
        XCTAssertThrowsError(
          try plan.admitPreservedStage1(installed, espUUID: UUID().uuidString))
      }
    }
  }
#endif
