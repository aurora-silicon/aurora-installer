#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  /// The handoff evidence path rule every ESP, boot-chain, sensor and vendor
  /// firmware member name passes before it is joined to a mounted root.
  final class NativeHandoffSafeRelativeTests: XCTestCase {
    func testPlainRelativePathsAreAdmitted() {
      for path in ["a", "esp/m1n1/boot.bin", "vendorfw/firmware.cpio", "..a", "a..", ".hidden"] {
        XCTAssertTrue(NativeHandoffEvidence.safeRelative(path), path)
      }
    }

    func testAbsoluteEmptyDotAndSeparatorTricksAreRefused() {
      for path in [
        "", "/", "/a", "a/", "a//b", ".", "..", "./a", "a/.", "a/./b", "a/../b", "../a",
        "a\\b", "a\u{0}b",
      ] {
        XCTAssertFalse(NativeHandoffEvidence.safeRelative(path), path.debugDescription)
      }
    }

    func testThePathBudgetIsCountedInUTF8Bytes() {
      XCTAssertTrue(NativeHandoffEvidence.safeRelative(String(repeating: "a", count: 4096)))
      XCTAssertFalse(NativeHandoffEvidence.safeRelative(String(repeating: "a", count: 4097)))
      XCTAssertTrue(NativeHandoffEvidence.safeRelative(String(repeating: "\u{E9}", count: 2048)))
      XCTAssertFalse(
        NativeHandoffEvidence.safeRelative(String(repeating: "\u{E9}", count: 2048) + "a"))
    }
  }
#endif
