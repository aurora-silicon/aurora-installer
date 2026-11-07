#if os(macOS)
  import Foundation
  import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

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

    func testAResetAdmitsOnlyTheStage2PathOfItsMode() async throws {
      var plan = try await NativeESPFileTests.plan(deviceIdentifier: "apple,j700")
      let uuid = UUID().uuidString.lowercased()
      func filled(_ path: String) throws -> Data {
        try NativeBootChain.fillStage1(
          plan.stage1, uuid: uuid, path: path, windowMilliseconds: plan.windowMilliseconds)
      }
      let standard = try filled(AuraStage1Format.standardStage2Path)
      let confined = try filled(AuraStage1Format.confinedStage2Path)
      let other = try filled("m1n1/other.bin")
      // A raw Stage 1 loads m1n1/boot.bin; a Mach-O one is always padded and
      // loads m1n1/boot-ctxr.bin.
      for (machO, own, foreign) in [(false, standard, confined), (true, confined, standard)] {
        plan.stage1MachO = machO ? Data() : nil
        let admitted = try plan.admitPreservedStage1(own, espUUID: uuid)
        XCTAssertEqual(admitted.sha256, NativeStubFileStore.hash(own))
        var rebuilt = own
        rebuilt[0] ^= 1
        XCTAssertThrowsError(try plan.admitPreservedStage1(rebuilt, espUUID: uuid))
        _ = try plan.admitPreservedStage1(rebuilt, espUUID: uuid, allowDifferentStage1Code: true)
        for refused in [foreign, other] {
          XCTAssertThrowsError(try plan.admitPreservedStage1(refused, espUUID: uuid))
          XCTAssertThrowsError(
            try plan.admitPreservedStage1(refused, espUUID: uuid, allowDifferentStage1Code: true))
        }
      }
    }

    func testAnEarlierInstallersUnpaddedMachOStage1IsRefusedWithWhatToDo() async throws {
      var plan = try await NativeESPFileTests.plan(deviceIdentifier: "apple,j700")
      plan.stage1MachO = Data()
      let uuid = UUID().uuidString.lowercased()
      let unpadded = try NativeBootChain.fillStage1(
        plan.stage1, uuid: uuid, path: AuraStage1Format.standardStage2Path,
        windowMilliseconds: plan.windowMilliseconds)
      for different in [false, true] {
        XCTAssertThrowsError(
          try plan.admitPreservedStage1(
            unpadded, espUUID: uuid, allowDifferentStage1Code: different)
        ) {
          XCTAssertEqual($0 as? NativePreservedInstallError, .earlierStage1)
        }
      }
      let summary = try XCTUnwrap(
        PinnedAsahiEngineExecutor.preservedSummary(for: NativePreservedInstallError.earlierStage1))
      XCTAssertTrue(summary.contains("Update its boot loader first"), summary)
      // Its screen leads with Update Boot Loader rather than Check again.
      XCTAssertEqual(
        PinnedAsahiEngineExecutor.preservedReason(for: NativePreservedInstallError.earlierStage1),
        .reinstallRequired)
      // A raw chip's Stage 1 on that path is its own, and is admitted.
      plan.stage1MachO = nil
      _ = try plan.admitPreservedStage1(unpadded, espUUID: uuid)
    }

    func testCrossDistroResetKeepsAValidEnrolledModernStageOne() async throws {
      let plan = try await NativeESPFileTests.plan(deviceIdentifier: "apple,j700")
      XCTAssertFalse(plan.usesLegacyStage1)
      let uuid = UUID().uuidString.lowercased()
      var installed = try NativeBootChain.fillStage1(
        plan.stage1, uuid: uuid, path: "m1n1/boot.bin",
        windowMilliseconds: plan.windowMilliseconds)
      installed[0] ^= 1  // Another distro built the enrolled code differently.
      XCTAssertThrowsError(try plan.admitPreservedStage1(installed, espUUID: uuid))
      let admitted = try plan.admitPreservedStage1(
        installed, espUUID: uuid, allowDifferentStage1Code: true)
      XCTAssertEqual(admitted.sha256, NativeStubFileStore.hash(installed))
      XCTAssertThrowsError(
        try plan.admitPreservedStage1(
          installed, espUUID: UUID().uuidString, allowDifferentStage1Code: true))

      let magic = Data("AURORA-S1-CFG01\0".utf8)
      let offset = try XCTUnwrap(installed.range(of: magic)?.upperBound)
      installed[offset + 48] ^= 1
      XCTAssertThrowsError(
        try plan.admitPreservedStage1(
          installed, espUUID: uuid, allowDifferentStage1Code: true))
    }
  }
#endif
