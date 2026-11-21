import Foundation
import XCTest

@testable import AuroraFirmware

/// Synthetic N1 images and tickets, no Apple files. The vector is the one
/// `tests/test_centauri.py` checks against `asahi_firmware/centauri.py`.
final class CentauriFirmwareTests: XCTestCase {
  let image =
    Data(count: 0x20) + Data("rkosftab".utf8) + Data([1, 0, 0, 0]) + Data(count: 4)
    + Data("synthetic N1 image".utf8)
  // SEQUENCE { IA5String "IM4M", INTEGER 0 }
  let ticket = Data([0x30, 0x09, 0x16, 0x04]) + Data("IM4M".utf8) + Data([0x02, 0x01, 0x00])

  func testTheTicketIsAppendedAndNamedInTheHeader() throws {
    let output = try CentauriFirmware.personalize(image: image, ticket: ticket)
    XCTAssertEqual(output.count, image.count + ticket.count)
    XCTAssertEqual(try output.little(0x10, 4), image.count)
    XCTAssertEqual(try output.little(0x14, 4), ticket.count)
    XCTAssertEqual(output.suffix(ticket.count), ticket)
    XCTAssertEqual(output.prefix(0x10), image.prefix(0x10))
    XCTAssertEqual(output[0x18..<image.count], image[0x18..<image.count])
    XCTAssertEqual(
      output.sha256, "82f9fbcd0c2f700dde10f373f7b1d4aacae2bb0e20357dd2e78e1b8745f660af")
  }

  func testALongFormTicketIsAccepted() throws {
    let body = Data([0x16, 0x04]) + Data("IM4M".utf8) + Data([0x04, 0x81, 200]) + Data(count: 200)
    let long = Data([0x30, 0x81, UInt8(body.count)]) + body
    let output = try CentauriFirmware.personalize(image: image, ticket: long)
    XCTAssertEqual(output.suffix(long.count), long)
  }

  func testImagesTheDriverWouldRefuseAreRefused() {
    var notFTAB = image
    notFTAB[0x27] = UInt8(ascii: "_")
    var ticketed = image
    ticketed[0x10] = 0x40
    var sized = image
    sized[0x14] = 1
    for refused in [image.prefix(0x2f), notFTAB, ticketed, sized] {
      XCTAssertThrowsError(try CentauriFirmware.personalize(image: refused, ticket: ticket))
    }
    let oversized = image + Data(count: CentauriFirmware.maximumBytes - image.count)
    XCTAssertThrowsError(try CentauriFirmware.personalize(image: oversized, ticket: ticket))
  }

  func testTicketsThatAreNotOneManifestAreRefused() {
    var otherString = ticket
    otherString[7] = UInt8(ascii: "P")
    for refused in [
      Data(), ticket.dropFirst(), ticket + Data([0]), otherString,
      Data([0x30, 0x81, 0x05]) + ticket[2..<7], Data([0x30, 0x03, 0x02, 0x01, 0x00]),
    ] {
      XCTAssertThrowsError(try CentauriFirmware.personalize(image: image, ticket: Data(refused)))
    }
  }

  func testEachModelGetsTheNameItsDriverRequests() {
    XCTAssertEqual(CentauriFirmware.firmwareName(machine: "j714s"), "apple/centauri/j714s-ftab.bin")
    XCTAssertEqual(CentauriFirmware.firmwareName(machine: "k116s"), "apple/centauri/k116s-ftab.bin")
    XCTAssertEqual(CentauriFirmware.firmwareName(machine: "j813"), "apple/centauri/j813-ftab.bin")
    XCTAssertEqual(CentauriFirmware.firmwareName(machine: "j873g"), "apple/centauri/j873-ftab.bin")
    XCTAssertEqual(
      CentauriFirmware.ticketPath(deviceClass: "j714sap"), "centauri/centauri.j714sap.im4m")
    XCTAssertEqual(
      CentauriFirmware.fallback(machine: "j714s", image: image, ticket: ticket),
      ["centauri/j714s/ftab.bin": image, "centauri/j714s/centauri.j714sap.im4m": ticket])
  }
}
