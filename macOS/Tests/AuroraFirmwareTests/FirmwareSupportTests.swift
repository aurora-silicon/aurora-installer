import Foundation
import XCTest

@testable import AuroraFirmware

/// The byte, digest and member-name helpers the firmware readers share.
/// All inputs are synthetic.
final class FirmwareSupportTests: XCTestCase {
  private func assertFailure(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual(($0 as? RestoreFailure)?.message, message, file: file, line: line)
    }
  }

  func testPartReturnsOnlyRangesInsideTheInput() throws {
    let data = Data([1, 2, 3, 4, 5])
    XCTAssertEqual(try data.part(0, 5), data)
    XCTAssertEqual(try data.part(1, 3), Data([2, 3, 4]))
    XCTAssertEqual(try data.part(5, 0), Data())
    for (offset, count) in [(-1, 1), (0, -1), (0, 6), (4, 2), (6, 0), (1, Int.max), (Int.max, 1)] {
      assertFailure("Truncated input.") { _ = try data.part(offset, count) }
    }
  }

  func testLittleEndianIntegersStayWithinInt() throws {
    let data = Data([0x01, 0x02, 0x03, 0x04])
    XCTAssertEqual(try data.little(0, 4), 0x0403_0201)
    XCTAssertEqual(try data.little(1, 2), 0x0302)
    XCTAssertEqual(try data.little(3, 1), 0x04)
    XCTAssertEqual(try data.little(0, 0), 0)
    let largest = Data(repeating: 0xFF, count: 7) + Data([0x7F])
    XCTAssertEqual(try largest.little(0, 8), Int.max)
    assertFailure("Integer exceeds supported bounds.") {
      _ = try Data(repeating: 0xFF, count: 8).little(0, 8)
    }
    assertFailure("Truncated input.") { _ = try data.little(2, 4) }
  }

  func testBig32ReadsFourBytesMostSignificantFirst() throws {
    let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])
    XCTAssertEqual(try data.big32(1), 0x0102_0304)
    XCTAssertEqual(try Data(repeating: 0xFF, count: 4).big32(0), 0xFFFF_FFFF)
    assertFailure("Truncated input.") { _ = try data.big32(2) }
  }

  func testLittleBytesRoundTripsAndTruncates() throws {
    XCTAssertEqual(littleBytes(0x0403_0201, count: 4), Data([1, 2, 3, 4]))
    XCTAssertEqual(littleBytes(0x0403_0201, count: 2), Data([1, 2]))
    XCTAssertEqual(littleBytes(0x18000, count: 4), Data([0x00, 0x80, 0x01, 0x00]))
    XCTAssertEqual(littleBytes(7, count: 0), Data())
    for value in [0, 1, 0x7F, 0x80, 0xFFFF, 0x0123_4567_89AB] {
      XCTAssertEqual(try littleBytes(value, count: 8).little(0, 8), value)
    }
  }

  func testValidHashIsExactlySixtyFourLowercaseHexDigits() {
    let hash = String(repeating: "0123456789abcdef", count: 4)
    XCTAssertTrue(validHash(hash))
    XCTAssertFalse(validHash(hash.uppercased()))
    XCTAssertFalse(validHash(String(hash.dropLast())))
    XCTAssertFalse(validHash(hash + "0"))
    XCTAssertFalse(validHash(String(hash.dropLast()) + "g"))
    XCTAssertFalse(validHash(String(hash.dropLast()) + "/"))
    XCTAssertFalse(validHash(String(hash.dropLast()) + ":"))
    XCTAssertFalse(validHash(""))
  }

  func testUnhexDecodesEveryDigitAndRefusesInvalidText() throws {
    let hash = String(repeating: "0123456789abcdef", count: 4)
    XCTAssertEqual(
      try unhex(hash),
      Data((0..<4).flatMap { _ in [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF] as [UInt8] }))
    XCTAssertEqual(try unhex(String(repeating: "f0", count: 32)), Data(repeating: 0xF0, count: 32))
    for text in [hash.uppercased(), String(hash.dropLast(2)), ""] {
      assertFailure("Invalid SHA-256 or MAC.") { _ = try unhex(text) }
    }
  }

  func testSafeRelativeAdmitsOnlyPlainRelativeMemberNames() {
    for name in ["a", "a/b", "firmware/wifi/example.bin", "..a", "a..", ".hidden", "a b"] {
      XCTAssertTrue(safeRelative(name), name)
    }
    for name in [
      "", "/a", "a/", "a//b", ".", "..", "./a", "a/.", "a/./b", "a/../b", "../a",
      "a\\b", "a\u{0}b", "a\r\nb",
    ] {
      XCTAssertFalse(safeRelative(name), name.debugDescription)
    }
  }
}
