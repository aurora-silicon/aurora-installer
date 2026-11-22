#if os(macOS)
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  /// The handoff member-path rule is judged on UTF-8 bytes, so a combining
  /// mark after "/" cannot hide a separator from it ("../\u{301}x" has a ".."
  /// component on disk).
  final class NativeHandoffSafeRelativeBytesTests: XCTestCase {
    func testCombiningMarksCannotHideSeparatorsOrDots() {
      for path in [
        "../\u{301}x", "./\u{20DD}x", "esp/../\u{301}b", "/\u{301}a", "a\\\u{301}b",
        "a\u{0}\u{301}", "a//\u{301}b",
      ] {
        XCTAssertFalse(NativeHandoffEvidence.safeRelative(path), path.debugDescription)
      }
      XCTAssertTrue(NativeHandoffEvidence.safeRelative("esp\u{301}/b"))
      XCTAssertTrue(NativeHandoffEvidence.safeRelative("esp/m1n1/boot.bin"))
    }

    /// Handoff files walk admitted paths one Character component at a time
    /// with O_NOFOLLOW; a separator absorbed into a grapheme would reach
    /// openat() inside one "leaf" and let it follow an intermediate symlink.
    func testSeparatorsAbsorbedIntoAGraphemeAreRefused() {
      for path in ["esp/\u{301}b", "a/\u{200D}b", "a/\u{FE0F}b", "a\u{600}/b", "a/b/\u{20DD}c"] {
        XCTAssertFalse(NativeHandoffEvidence.safeRelative(path), path.debugDescription)
      }
    }

    func testAbsoluteEmptyAndDotPathsStayRefused() {
      for path in [
        "", "/", "/a", "a/", "a//b", ".", "..", "./a", "a/.", "a/../b", "a\\b", "a\u{0}b",
      ] {
        XCTAssertFalse(NativeHandoffEvidence.safeRelative(path), path.debugDescription)
      }
    }

    func testThePathBudgetIsCountedInUTF8Bytes() {
      XCTAssertTrue(NativeHandoffEvidence.safeRelative(String(repeating: "a", count: 4096)))
      XCTAssertFalse(NativeHandoffEvidence.safeRelative(String(repeating: "a", count: 4097)))
      XCTAssertFalse(
        NativeHandoffEvidence.safeRelative(String(repeating: "\u{E9}", count: 2048) + "a"))
    }
  }
#endif
