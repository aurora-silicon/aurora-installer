import Foundation
import XCTest

@testable import AuroraFirmware

final class FirmwareImagePropertiesTests: XCTestCase {
  private func der(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    if content.count < 128 {
      out.append(UInt8(content.count))
    } else {
      let length = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) }
        .drop(while: { $0 == 0 })
      out.append(0x80 | UInt8(length.count))
      out.append(contentsOf: length)
    }
    out.append(content)
    return out
  }

  private func image(payload: Data, trailing: [Data]) -> Data {
    der(
      0x30,
      der(0x16, Data("IM4P".utf8)) + der(0x16, Data("krnl".utf8))
        + der(0x16, Data("KernelManagement".utf8)) + der(0x04, payload)
        + trailing.reduce(Data(), +))
  }

  private var properties: Data {
    der(0xA0, der(0x30, der(0x16, Data("PAYP".utf8)) + der(0x31, Data())))
  }

  private func compression(_ length: Int) -> Data {
    der(0x30, der(0x02, Data([1])) + der(0x02, withUnsafeBytes(of: UInt32(length).bigEndian) {
      Data($0) }.drop(while: { $0 == 0 })))
  }

  func testPayloadPropertiesAfterTheCompressionMetadataAreAccepted() throws {
    let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
    let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
    let decoded = try FirmwareImage.decode(
      image(payload: compressed, trailing: [compression(payload.count), properties]))
    XCTAssertEqual(decoded.type, "krnl")
    XCTAssertEqual(decoded.bytes, payload)
  }

  func testPayloadPropertiesWithoutCompressionAreAccepted() throws {
    let payload = Data("raw firmware".utf8)
    let decoded = try FirmwareImage.decode(image(payload: payload, trailing: [properties]))
    XCTAssertEqual(decoded.bytes, payload)
  }

  func testMatchHeavyLZFSEWithinItsDeclaredSizeDecodes() throws {
    // Kernel caches decode to about 110 MB through millions of short matches.
    let words = (0..<64).map { "w\($0 * 7919 % 1000)-" }
    var state: UInt32 = 1
    var text = ""
    while text.utf8.count < 16 << 20 {
      state = state &* 1_664_525 &+ 1_013_904_223
      text += words[Int(state >> 26)]
    }
    let plain = Data(text.utf8)
    let compressed = try (plain as NSData).compressed(using: .lzfse) as Data
    XCTAssertEqual(try boundedLZFSE(compressed, maximum: plain.count), plain)
  }

  func testMisplacedOrUnknownTrailingFieldsAreRefused() {
    let payload = Data("raw firmware".utf8)
    XCTAssertThrowsError(
      try FirmwareImage.decode(
        image(payload: payload, trailing: [properties, compression(payload.count)])))
    XCTAssertThrowsError(
      try FirmwareImage.decode(
        image(payload: payload, trailing: [compression(payload.count), der(0x04, Data([1]))])))
    XCTAssertThrowsError(
      try FirmwareImage.decode(image(payload: payload, trailing: [properties, properties])))
  }
}
