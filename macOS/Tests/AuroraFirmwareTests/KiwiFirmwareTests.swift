import Foundation
import XCTest

@testable import AuroraFirmware

/// Synthetic inputs only: no Apple firmware and no factory values.
final class KiwiFirmwareTests: XCTestCase {
  private func der(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    if content.count < 128 {
      out.append(UInt8(content.count))
    } else {
      let bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Data($0) }
        .drop(while: { $0 == 0 })
      out.append(0x80 | UInt8(bytes.count))
      out.append(contentsOf: bytes)
    }
    return out + content
  }
  private func ia5(_ text: String) -> Data { der(0x16, Data(text.utf8)) }

  private func image(_ xml: String) -> Data {
    der(0x30, ia5("IM4P") + ia5("tasf") + ia5("1") + der(0x04, Data(xml.utf8)))
  }

  /// A factory record shaped like the Mac's: IMG4 { IM4P 'GpCD' { SEQUENCE {
  /// INTEGER, INTEGER, [private, high tag number] { SET { entries } } } } }.
  private func factoryRecord(_ blobs: [(String, Data)]) -> Data {
    let entries = blobs.map { tag, blob in
      der(0x30, der(0x02, Data(tag.utf8.reversed())) + ia5(".") + der(0x04, blob))
    }
    let set = der(0x31, entries.reduce(Data(), +))
    var directory = Data([0xff, 0x85, 0x01])
    directory.append(der(0x30, set).dropFirst())
    let body = der(
      0x30, der(0x02, Data("DCpG".utf8)) + der(0x02, Data([3, 0, 3, 0])) + directory)
    let payload = der(0x30, ia5("IM4P") + ia5("GpCD") + ia5("1.0") + der(0x04, body))
    return der(0x30, ia5("IMG4") + payload + der(0xa0, Data([0x05, 0x00])))
  }

  /// A unit blob as the record checks want it: magic at 0, version at 0x40,
  /// the payload size (length minus the 0x4c footer) at 0x44.
  private func blob(magic: UInt32, version: UInt32 = 3, count: Int = 0x80) -> Data {
    var data = Data(repeating: 0x5c, count: count)
    func put(_ value: UInt32, _ at: Int) {
      for index in 0..<4 { data[at + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    put(magic, 0)
    put(version, 0x40)
    put(UInt32(count - 0x4c), 0x44)
    return data
  }

  private func plist(required: Bool = false) -> String {
    let big = Data(repeating: 0xa5, count: 70_000).base64EncodedString()
    let small = Data([1, 2, 3]).base64EncodedString()
    let defaultBlob = blob(magic: 0x4b31_3102).base64EncodedString()
    return """
      <dict><key>K999,1</key><array>
      <dict><key>Type</key><string ID="0">ReadModifyWrite</string><key>Address</key>\
      <integer size="64">0x40000298</integer><key>Mask</key><integer size="64">0x80</integer>\
      <key>SkipCheck</key><false/></dict>
      <dict><key>Type</key><string>Binary</string><key>Address</key><integer size="64">0x20420000</integer>\
      <key>Payload</key><data>\(big)</data></dict>
      <dict><key>Type</key><string>Binary</string><key>Address</key><integer size="64">0x400000</integer>\
      <key>Payload</key><data>\(small)</data></dict>
      <dict><key>Type</key><string>Property</string><key>Address</key><integer size="64">0x2064ce10</integer>\
      <key>MaxSize</key><integer size="64">0x2c0c</integer><key>Tag</key><string>CD00</string>\
      <key>Payload</key><data>\(defaultBlob)</data>\
      <key>Validation</key><array><dict><key>Address</key><integer size="64">0x0</integer>\
      <key>Size</key><integer size="64">0x4</integer><key>Value</key><integer size="64">0x4b313102</integer></dict>\
      <dict><key>Address</key><integer size="64">0x40</integer><key>Size</key><integer size="64">0x4</integer>\
      <key>MinValue</key><integer size="64">0x2</integer><key>MaxValue</key><integer size="64">0x3</integer></dict></array>\
      <key>Checksum</key><dict><key>FooterSize</key><integer size="64">0x4c</integer><key>PayloadSize</key>\
      <dict><key>Offset</key><integer size="64">0x44</integer><key>Size</key><integer size="64">0x4</integer></dict></dict></dict>
      <dict><key>Type</key><string>Property</string><key>Address</key><integer size="64">0x0</integer>\
      <key>Tag</key><string>MD00</string><key>MaxSize</key><integer size="64">0xffffffff</integer>\
      <key>Payload</key><data>AAAAAAAAAAA=</data><key>Requirement</key><dict><key>Type</key>\
      \(required ? "<true/>" : "<false/>")</dict></dict>
      <dict><key>Type</key><string>Config</string><key>Config</key><dict><key>Interface Config</key><array>\
      <dict><key>bInterfaceNumber</key><integer size="64">0x7</integer><key>InterfaceName</key>\
      <string>kiwi</string></dict></array></dict></dict>
      </array><key>K999,1-SelfTest</key><array></array></dict>
      """
  }

  func testConvertsTheOnlyPersonalityWithLongByteStringsAndThePlaceholder() throws {
    let result = try KiwiFirmware.convert(image(plist()), machine: "k999s", factory: [:])
    let file = try XCTUnwrap(result.files["apple/tpkiwifw-k999s.bin"])
    XCTAssertEqual(result.files.count, 1)
    XCTAssertEqual(file.prefix(4), Data("HIDF".utf8))
    XCTAssertEqual(try file.little(4, 4), 1)
    XCTAssertEqual(try file.little(8, 4), 32)
    XCTAssertEqual(try file.little(12, 4), file.count - 32)
    let blob = file.dropFirst(32)
    let interface = try file.little(16, 4)
    XCTAssertEqual(blob[blob.startIndex + interface], 0)
    // Five records: the address-0 placeholder is not sent.
    XCTAssertEqual(blob.first, 0x85)
    // The 70,000-byte payload: 0x5a, a four-byte length, contents on 4 bytes.
    let long = try XCTUnwrap(blob.firstRange(of: Data([0x5a, 0x00, 0x01, 0x11, 0x70])))
    XCTAssertEqual((long.lowerBound - blob.startIndex + 5) % 4, 0)
    XCTAssertNotNil(blob.firstRange(of: Data([0x59, 0x00, 0x03, 1, 2, 3])))
    XCTAssertNotNil(blob.firstRange(of: Data("SkipCheck\0".utf8) + Data([0xf4])))
    XCTAssertNil(blob.firstRange(of: Data("MD00\0".utf8)))
    XCTAssertEqual(result.unitTags, [])
    XCTAssertEqual(result.defaultTags, ["CD00"])
  }

  func testUnitCalibrationReplacesADefaultOnlyWhenItPassesTheRecordChecks() throws {
    let unit = blob(magic: 0x4b31_3102, version: 2, count: 0x90)
    let factory = ["GpCD-0": factoryRecord([("CD00", unit), ("MD00", blob(magic: 1))])]
    let result = try KiwiFirmware.convert(image(plist()), machine: "k999s", factory: factory)
    XCTAssertEqual(result.unitTags, ["CD00"])
    let file = try XCTUnwrap(result.files["apple/tpkiwifw-k999s.bin"])
    XCTAssertNotNil(file.firstRange(of: unit))

    for bad in [
      blob(magic: 0x4b31_3103),  // another tag's magic
      blob(magic: 0x4b31_3102, version: 4),  // version out of range
      blob(magic: 0x4b31_3102, count: 0x2c10),  // larger than the record allows
      blob(magic: 0x4b31_3102).dropLast(),  // payload size field disagrees
    ] {
      let refused = try KiwiFirmware.convert(
        image(plist()), machine: "k999s", factory: ["GpCD-0": factoryRecord([("CD00", bad)])])
      XCTAssertEqual(refused.unitTags, [])
      XCTAssertEqual(refused.defaultTags, ["CD00"])
    }
  }

  func testRejectsRequiredHostPropertiesAndAmbiguousInputs() throws {
    XCTAssertThrowsError(
      try KiwiFirmware.convert(image(plist(required: true)), machine: "k999s", factory: [:]))
    XCTAssertThrowsError(
      try KiwiFirmware.convert(
        image(plist()), machine: "k999s",
        factory: ["GpCD-0": factoryRecord([]), "GpCD-1": factoryRecord([])]))
    XCTAssertThrowsError(
      try KiwiFirmware.calibration(factoryRecord([("CD00", Data([1])), ("CD00", Data([2]))])))
    XCTAssertThrowsError(
      try KiwiFirmware.convert(image(plist()), machine: "../k999s", factory: [:]))
    let twoPersonalities = plist().replacingOccurrences(of: "K999,1-SelfTest", with: "K999,2")
    XCTAssertThrowsError(
      try KiwiFirmware.convert(image(twoPersonalities), machine: "k999s", factory: [:]))
  }
}
