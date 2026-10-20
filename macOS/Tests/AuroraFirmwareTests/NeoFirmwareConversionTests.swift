import Foundation
import NativeFirmwareFixtureSupport
import XCTest
@testable import AuroraFirmware

final class NeoFirmwareConversionTests: XCTestCase, @unchecked Sendable {
  struct Fixture: Decodable {
    struct Registry: Decodable { let magic: Int; let name: String; let size: Int }
    struct Vector: Decodable {
      let name: String, operation: String, country: String
      let data: Data
      let success: Bool
      let sha256: String?
      let files: [String: String]?
    }
    let registry: [Registry]
    let vectors: [Vector]
    let rawFiles: [String: Data]
    let local: [String: Data]
    let outputSHA256: [String: String]
  }
  func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: NeoFirmwareFixture.data()) }

  func testAllSevenCameraEntriesMatchTheAuthenticatedRegistry() throws {
    let fixture = try fixture()
    XCTAssertEqual(fixture.registry.count, 7)
    XCTAssertEqual(NeoFirmwareConversions.cameraRegistry.map(\.magic), fixture.registry.map(\.magic))
    XCTAssertEqual(NeoFirmwareConversions.cameraRegistry.map(\.name), fixture.registry.map(\.name))
    XCTAssertEqual(NeoFirmwareConversions.cameraRegistry.map(\.size), fixture.registry.map(\.size))
  }

  func testConvertersMatchTheLockedReferenceBytesAndRejections() throws {
    let fixture = try fixture()
    XCTAssertEqual(fixture.vectors.count, 41)
    for vector in fixture.vectors {
      var accepted = false
      do {
        var bytes: Data?
        var files: [String: Data]?
        switch vector.operation {
        case "camera": files = try NeoFirmwareConversions.camera(vector.data, requireNeoSet: false)
        case "factory": files = try NeoFirmwareConversions.factoryFields(vector.data)
        case "oca": try NeoFirmwareConversions.validateOCA2(vector.data); bytes = vector.data
        case "config": bytes = try NeoFirmwareConversions.configuration(vector.data)
        case "bluetooth": try NeoFirmwareConversions.validateBluetooth(vector.data); bytes = vector.data
        case "ptx": try NeoFirmwareConversions.validatePTX(vector.data); bytes = vector.data
        case "address": bytes = try NeoFirmwareConversions.bluetoothAddress(vector.data)
        case "als": bytes = try NeoFirmwareConversions.alsCalibration(vector.data)
        case "policy": bytes = try NeoFirmwareConversions.policy(vector.data, country: vector.country)
        default: XCTFail("Unknown vector operation"); continue
        }
        accepted = true
        if let bytes { XCTAssertEqual(bytes.sha256, vector.sha256, vector.name) }
        if let files { XCTAssertEqual(files.mapValues(\.sha256), vector.files, vector.name) }
      } catch {}
      XCTAssertEqual(accepted, vector.success, vector.name)
    }
  }

  func testCompleteRadioOutputPreservesEveryRequiredCalibrationAndAddressByte() throws {
    let fixture = try fixture()
    let files = fixture.rawFiles
    let output = try NeoFirmwareConversions.radio(.init(
      patch: XCTUnwrap(files["sunrise/" + NeoFirmwareConversions.wifiPatch]),
      ram: XCTUnwrap(files["sunrise/" + NeoFirmwareConversions.wifiRAM]),
      ppr: XCTUnwrap(files["sunrise/IZUBA_PPR_MT7932.bin"]), config: XCTUnwrap(files["sunrise/IZUBA_wifi.cfg"]),
      bluetooth: NeoFirmwareConversions.bluetoothNames.map { try XCTUnwrap(files["bluetooth/" + $0]) },
      ptx: XCTUnwrap(files["bluetooth/" + NeoFirmwareConversions.ptxName]),
      factory: XCTUnwrap(fixture.local["factory"]), address: XCTUnwrap(fixture.local["address"])))
    XCTAssertEqual(Set(output.keys), NeoFirmwareConversions.requiredRadioNames)
    XCTAssertEqual(output.count, 11)
    for (name, bytes) in output { XCTAssertEqual(bytes.sha256, fixture.outputSHA256[name], name) }
    XCTAssertEqual(output["mediatek/j700-mt7932-bdaddr.bin"], fixture.local["address"])
  }

  func testNativeBoundsRejectEscapingNestedFactoryRecordsAndAliasedDataSlices() throws {
    let fixture = try fixture()
    let source = try XCTUnwrap(fixture.local["factory"])
    for bytes in [Data(), source + Data([0]), Data([0x30, 0x80]), Data([0x30, 1, 0x30, 0]) ] {
      XCTAssertThrowsError(try NeoFirmwareConversions.factoryFields(bytes))
    }
    func der(_ tag: UInt8, _ contents: Data) -> Data {
      Data([tag, 0x82, UInt8(truncatingIfNeeded: contents.count >> 8), UInt8(truncatingIfNeeded: contents.count)]) + contents
    }
    var nesting = der(0x30, Data())
    for _ in 0..<40 {
      nesting = der(0x30, nesting)
    }
    let payload = der(0x16, Data("IM4P".utf8)) + der(0x16, Data("BWC2".utf8))
      + der(0x16, Data()) + der(4, nesting)
    let envelope = der(0x30, der(0x16, Data("IMG4".utf8)) + der(0x30, payload))
    XCTAssertThrowsError(try NeoFirmwareConversions.factoryFields(envelope)) { error in
      XCTAssertTrue(error.localizedDescription.contains("nesting exceeds its budget"))
    }
    var lsci = Data([0]) + (try XCTUnwrap(fixture.local["lsci"]))
    lsci.removeFirst()
    if lsci.startIndex != 0 { XCTAssertThrowsError(try NeoFirmwareConversions.alsCalibration(lsci)) }
    let camera = try XCTUnwrap(fixture.rawFiles["camera/synthetic.bin"])
    XCTAssertThrowsError(try NeoFirmwareConversions.camera(Data(camera.prefix(4096))))
  }
}
