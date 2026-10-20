import Foundation
import XCTest

@testable import AuroraFirmware

final class GenericFirmwareConversionTests: XCTestCase {
  struct Corpus: Decodable {
    struct Vector: Decodable {
      let name: String, operation: String, machine: String
      let inputs: [String: Data]
      let accepted: Bool
      let outputs: [String: String]?
    }
    let vectors: [Vector]
  }

  func testSharedFirmwareConversionsMatchTheAuthenticatedReference() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "generic-firmware", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    XCTAssertEqual(corpus.vectors.count, 28)
    for vector in corpus.vectors {
      var accepted = false
      do {
        let outputs: [String: Data]
        switch vector.operation {
        case "wifi": outputs = try BroadcomFirmware.wifi(vector.inputs)
        case "bluetooth": outputs = try BroadcomFirmware.bluetooth(vector.inputs)
        case "multitouch":
          outputs = try MultitouchFirmware.convert(
            XCTUnwrap(vector.inputs["image"]), machine: vector.machine)
        case "image":
          let result = try FirmwareImage.decode(XCTUnwrap(vector.inputs["image"]))
          outputs = [result.type: result.bytes]
        case "controller":
          outputs = try FirmwareImage.controllerFirmware(in: XCTUnwrap(vector.inputs["kernel"]))
        default:
          XCTFail("Unknown firmware vector operation")
          continue
        }
        accepted = true
        XCTAssertEqual(outputs.mapValues(\.sha256), vector.outputs, vector.name)
      } catch {
        if vector.accepted { XCTFail("\(vector.name): \(error)") }
      }
      XCTAssertEqual(accepted, vector.accepted, vector.name)
    }
  }

  func testFirmwareXMLRejectsExternalEntitiesDuplicateKeysAndCyclicReferences() throws {
    let inputs = [
      "<!DOCTYPE dict [<!ENTITY content SYSTEM 'file:///etc/passwd'>]><dict><key>x</key><string>&content;</string></dict>",
      "<!DOCTYPE dict [<!ENTITY x 'expanded'>]><dict><key>x</key><string>&x;</string></dict>",
      "<dict><key>same</key><integer>1</integer><key>same</key><integer>2</integer></dict>",
      "<dict ID='loop'><key>x</key><dict IDREF='loop'/></dict>",
      "<dict><key>x</key><data IDREF='missing'/></dict>",
    ]
    for input in inputs { XCTAssertThrowsError(try FirmwarePlist.decode(Data(input.utf8)), input) }
  }

  func testOrderedKeysAndValuesResolveOnlyEarlierReferencesOfTheSameType() throws {
    let xml =
      "<dict><key ID='key'>first</key><integer>1</integer><key>second</key><dict><key IDREF='key'/><integer>2</integer></dict></dict>"
    let result = try FirmwarePlist.decode(Data(xml.utf8))
    XCTAssertEqual(result["first"]?.integer, 1)
    XCTAssertEqual(result["second"]?["first"]?.integer, 2)
    let wrongType =
      "<dict><key>x</key><integer ID='n'>1</integer><key>y</key><string IDREF='n'/></dict>"
    XCTAssertThrowsError(try FirmwarePlist.decode(Data(wrongType.utf8)))
  }

  func testConflictingRadioInputsAndUnsafeNamesAreRejected() throws {
    XCTAssertThrowsError(try BroadcomFirmware.wifi(["../outside": Data()]))
    XCTAssertThrowsError(try BroadcomFirmware.bluetooth(["/outside": Data()]))
    XCTAssertThrowsError(
      try BroadcomFirmware.bluetooth([
        "BCM4388B0_PCIE_Tokara_MUR_one.bin": Data([1]),
        "BCM4388B0_PCIE_Tokara_MUR_two.bin": Data([2]),
      ]))
    let marker = Data("2214A_RCFG".utf8)
    var truncated = marker + Data(repeating: 0, count: 0x33 - marker.count)
    truncated.replaceSubrange(0x2f..<0x33, with: littleBytes(0x18000, count: 4))
    XCTAssertThrowsError(try FirmwareImage.controllerFirmware(in: truncated))
    XCTAssertThrowsError(try MultitouchFirmware.convert(Data(), machine: "../../outside"))
  }
}
