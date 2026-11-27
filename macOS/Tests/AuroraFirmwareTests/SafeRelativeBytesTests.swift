import XCTest

@testable import AuroraFirmware

/// The firmware member-path rule is judged on the UTF-8 bytes the file system
/// sees. A Character can hide a separator, a dot, NUL or a line break inside a
/// grapheme cluster, and "\r\n" is a single Character.
final class SafeRelativeBytesTests: XCTestCase {
  func testPlainRelativePathsAreAdmitted() {
    for name in ["a", "a/b", "C-4388__s-C2/aruba.trx", "..a", "a..", ".hidden", "caf\u{E9}/x"] {
      XCTAssertTrue(safeRelative(name), name)
    }
  }

  func testLoneLineBreaksAreRefused() {
    for name in ["a\rb", "a\nb", "a\r\nb", "\r", "\n", "a/b\n"] {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
    }
  }

  func testCombiningMarksCannotHideSeparatorsOrDots() {
    for name in [
      "../\u{301}x", "./\u{20DD}x", "a/../\u{301}b", "/\u{301}a", "a\\\u{301}b",
      "a\u{0}\u{301}", "a\r\u{301}b", "a//\u{301}b",
    ] {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
    }
    // A combining mark after a dot is part of a component name.
    XCTAssertTrue(safeRelative(".\u{301}/b"))
    XCTAssertTrue(safeRelative("a\u{301}/b"))
  }

  /// Callers split admitted paths on Characters, so a separator that a
  /// grapheme cluster absorbs would be one component to them and two to the
  /// file system.
  func testSeparatorsAbsorbedIntoAGraphemeAreRefused() {
    for name in [
      "a/\u{301}b", "a/\u{20DD}b", "a/\u{200D}b", "a/\u{FE0F}b", "a\u{600}/b",
      "C-4388__s-C2/\u{301}aruba.trx",
    ] {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
      XCTAssertNotEqual(
        name.split(separator: "/").count, name.utf8.split(separator: UInt8(ascii: "/")).count)
    }
  }

  func testEmptyDotAndSeparatorTricksStayRefused() {
    for name in ["", "/", "/a", "a/", "a//b", ".", "..", "./a", "a/.", "a/../b", "a\\b", "a\u{0}b"]
    {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
    }
  }
}
