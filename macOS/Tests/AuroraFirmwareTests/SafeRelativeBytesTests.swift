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
    // A combining mark after a dot or separator is part of a component name.
    XCTAssertTrue(safeRelative("a/\u{301}b"))
    XCTAssertTrue(safeRelative(".\u{301}/b"))
  }

  func testEmptyDotAndSeparatorTricksStayRefused() {
    for name in ["", "/", "/a", "a/", "a//b", ".", "..", "./a", "a/.", "a/../b", "a\\b", "a\u{0}b"]
    {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
    }
  }
}
