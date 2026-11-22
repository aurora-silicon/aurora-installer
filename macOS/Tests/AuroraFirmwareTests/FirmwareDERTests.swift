import Foundation
import XCTest

@testable import AuroraFirmware

/// Synthetic byte strings only: these pin the bounds and canonical-length
/// rules every IM4P, IMG4 and sensor record read goes through.
final class FirmwareDERTests: XCTestCase {
  private func assertFailure(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual(($0 as? RestoreFailure)?.message, message, file: file, line: line)
    }
  }

  func testShortFormElementReportsTagContentAndWholeRange() throws {
    let data = Data([0x16, 0x03, 0x61, 0x62, 0x63])
    let element = try FirmwareDER.element(data, at: 0, limit: data.count)
    XCTAssertEqual(element.tag, 0x16)
    XCTAssertEqual(element.content, 2..<5)
    XCTAssertEqual(element.whole, 0..<5)

    let inner = Data([0xFF, 0x04, 0x01, 0x00, 0xEE])
    let offset = try FirmwareDER.element(inner, at: 1, limit: 4)
    XCTAssertEqual(offset.tag, 0x04)
    XCTAssertEqual(offset.content, 3..<4)
    XCTAssertEqual(offset.whole, 1..<4)
  }

  func testAnEmptyElementMayEndExactlyAtTheLimit() throws {
    let data = Data([0x05, 0x00])
    let element = try FirmwareDER.element(data, at: 0, limit: 2)
    XCTAssertEqual(element.content, 2..<2)
    XCTAssertEqual(element.whole, 0..<2)
  }

  func testLongFormLengthsAreReadBigEndian() throws {
    let one = Data([0x04, 0x81, 0x80]) + Data(repeating: 0xAA, count: 128)
    let a = try FirmwareDER.element(one, at: 0, limit: one.count)
    XCTAssertEqual(a.content, 3..<131)
    XCTAssertEqual(a.whole, 0..<131)

    let two = Data([0x04, 0x82, 0x01, 0x02]) + Data(repeating: 0xBB, count: 258)
    let b = try FirmwareDER.element(two, at: 0, limit: two.count)
    XCTAssertEqual(b.content, 4..<262)
    XCTAssertEqual(b.whole, 0..<262)
  }

  func testRecordsWithoutATagAndLengthAreTruncated() {
    let pair = Data([0x04, 0x00])
    let truncated = "Truncated firmware record."
    assertFailure(truncated) { _ = try FirmwareDER.element(Data(), at: 0, limit: 0) }
    assertFailure(truncated) { _ = try FirmwareDER.element(Data([0x04]), at: 0, limit: 1) }
    assertFailure(truncated) { _ = try FirmwareDER.element(pair, at: 1, limit: 2) }
    assertFailure(truncated) { _ = try FirmwareDER.element(pair, at: -1, limit: 2) }
    assertFailure(truncated) { _ = try FirmwareDER.element(pair, at: 0, limit: 3) }
    assertFailure(truncated) { _ = try FirmwareDER.element(pair, at: 0, limit: 1) }
  }

  func testIndefiniteOversizedOrZeroPaddedLengthsAreInvalid() {
    let invalid = "Invalid firmware record length."
    // Indefinite length (followed by a zero and by a nonzero byte), five
    // length bytes, a leading zero, and length bytes that run past the limit.
    for data in [
      Data([0x04, 0x80, 0x00]),
      Data([0x04, 0x80, 0x01]),
      Data([0x04, 0x85, 0x01, 0x00, 0x00, 0x00, 0x00]),
      Data([0x04, 0x82, 0x00, 0x80]) + Data(repeating: 0, count: 128),
      Data([0x04, 0x82, 0x01]),
    ] {
      assertFailure(invalid) { _ = try FirmwareDER.element(data, at: 0, limit: data.count) }
    }
  }

  func testLongFormForAShortLengthIsNoncanonical() {
    let data = Data([0x04, 0x81, 0x7F]) + Data(repeating: 0, count: 127)
    assertFailure("Noncanonical firmware record length.") {
      _ = try FirmwareDER.element(data, at: 0, limit: data.count)
    }
  }

  func testContentPastTheLimitEscapesItsRecord() throws {
    let escape = "Firmware record escapes its enclosing record."
    let data = Data([0x04, 0x02, 0x01, 0x02])
    XCTAssertEqual(try FirmwareDER.element(data, at: 0, limit: 4).whole, 0..<4)
    assertFailure(escape) { _ = try FirmwareDER.element(data, at: 0, limit: 3) }
    assertFailure(escape) { _ = try FirmwareDER.element(Data([0x04, 0x03, 0x01, 0x02]), at: 0, limit: 4) }
    let huge = Data([0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])
    assertFailure(escape) { _ = try FirmwareDER.element(huge, at: 0, limit: huge.count) }
  }

  func testChildrenWalkTheContentInOrder() throws {
    let data = Data([0x30, 0x09, 0x16, 0x02, 0x41, 0x42, 0x04, 0x00, 0x02, 0x01, 0x07])
    let outer = try FirmwareDER.element(data, at: 0, limit: data.count)
    let children = try FirmwareDER.children(data, outer)
    XCTAssertEqual(children.map(\.tag), [0x16, 0x04, 0x02])
    XCTAssertEqual(children.map(\.whole), [2..<6, 6..<8, 8..<11])
    XCTAssertEqual(children.map(\.content), [4..<6, 8..<8, 10..<11])

    let empty = Data([0x30, 0x00])
    XCTAssertEqual(try FirmwareDER.children(empty, FirmwareDER.element(empty, at: 0, limit: 2)).count, 0)
  }

  func testAChildCannotReadPastItsParentEvenWhenTheInputContinues() throws {
    // The parent ends after three bytes; the child claims a fourth that only
    // the trailing input holds.
    let data = Data([0x30, 0x03, 0x04, 0x02, 0xAA, 0xBB])
    let outer = try FirmwareDER.element(data, at: 0, limit: data.count)
    assertFailure("Firmware record escapes its enclosing record.") {
      _ = try FirmwareDER.children(data, outer)
    }
  }

  func testAtMost1024ChildrenAreRead() throws {
    func sequence(_ count: Int) -> Data {
      let content = count * 2
      return Data([0x30, 0x82, UInt8(content >> 8), UInt8(content & 0xFF)])
        + Data((0..<count).flatMap { _ in [0x05, 0x00] as [UInt8] })
    }
    let most = sequence(1024)
    let read = try FirmwareDER.children(most, FirmwareDER.element(most, at: 0, limit: most.count))
    XCTAssertEqual(read.count, 1024)
    XCTAssertEqual(read.last?.whole, 2050..<2052)

    let over = sequence(1025)
    let outer = try FirmwareDER.element(over, at: 0, limit: over.count)
    assertFailure("Too many firmware record fields.") { _ = try FirmwareDER.children(over, outer) }
  }

  func testTextMatchesOnlyAnIA5StringWithExactlyTheExpectedBytes() throws {
    func element(_ tag: UInt8, _ text: String) throws -> (Data, FirmwareDER.Element) {
      let data = Data([tag, UInt8(text.utf8.count)]) + Data(text.utf8)
      return (data, try FirmwareDER.element(data, at: 0, limit: data.count))
    }
    let (data, im4p) = try element(0x16, "IM4P")
    XCTAssertTrue(FirmwareDER.text(data, im4p, "IM4P"))
    XCTAssertFalse(FirmwareDER.text(data, im4p, "IM4"))
    XCTAssertFalse(FirmwareDER.text(data, im4p, "IM4PX"))
    XCTAssertFalse(FirmwareDER.text(data, im4p, "IMG4"))
    let (utf8, string) = try element(0x0C, "IM4P")
    XCTAssertFalse(FirmwareDER.text(utf8, string, "IM4P"))
    let (octets, bytes) = try element(0x04, "IM4P")
    XCTAssertFalse(FirmwareDER.text(octets, bytes, "IM4P"))
  }
}
