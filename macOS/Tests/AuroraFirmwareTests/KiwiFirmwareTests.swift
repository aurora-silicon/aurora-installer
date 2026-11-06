import Foundation
import XCTest

@testable import AuroraFirmware

final class KiwiFirmwareTests: XCTestCase {
  private let reference = Data([1, 2, 3, 4])
  private let calibration = Data([0xca, 0xfe, 0xba, 0xbe])

  private func plist(
    personality: String = "K114,2", requirement: String = "<true/>",
    reference: String? = nil, extraRecords: Int = 24
  ) -> Data {
    let reference = reference ?? "<data>\(self.reference.base64EncodedString())</data>"
    let extras = (0..<extraRecords).map { index in
      """
      <dict><key>Type</key><string>Binary</string><key>Address</key><integer>\(index + 32)</integer><key>Payload</key><data>AQ==</data></dict>
      """
    }.joined()
    let wideConfig = (0..<24).map {
      "<key>Field\($0)</key><integer>\($0)</integer>"
    }.joined()
    return Data(
      """
      <plist><dict>
      <key>\(personality)</key><array>
        <dict><key>Type</key><string>Config</string><key>Config</key><dict>
          <key>Interface Config</key><array><dict><key>bInterfaceNumber</key><integer>9</integer><key>Enabled</key><false/></dict></array>
          \(wideConfig)
        </dict></dict>
        <dict><key>Type</key><string>Property</string><key>Address</key><integer>4096</integer><key>TargetId</key><integer>2</integer><key>SysConfigKey</key><string>GpCD/touch</string><key>Reference</key>\(reference)<key>DefaultPath</key><string>/factory/cal.bin</string><key>Requirement</key>\(requirement)</dict>
        <dict><key>Type</key><string>Binary</string><key>Address</key><integer>8192</integer><key>Payload</key><data>3q2+7w==</data><key>Requirement</key><false/></dict>
        \(extras)
      </array>
      <key>K114,2-SelfTest</key><array><dict><key>Type</key><string>Binary</string><key>Payload</key><data>3q2+7w==</data></dict></array>
      </dict></plist>
      """.utf8)
  }

  func testSyntheticContainerProducesLinuxHIDFAndRuntimeCalibration() throws {
    let converted = try KiwiFirmware.convertPayload(
      plist(), machine: "k114c", factory: ["cal.bin": calibration])
    let firmware = try XCTUnwrap(converted.files[KiwiFirmware.firmwareName])
    XCTAssertEqual(firmware.prefix(4), Data("HIDF".utf8))
    XCTAssertEqual(try firmware.little(4, 4), 1)
    XCTAssertEqual(try firmware.little(8, 4), 32)
    XCTAssertEqual(try firmware.little(12, 4), firmware.count - 32)
    let interface = try firmware.little(16, 4)
    XCTAssertGreaterThan(interface, 0)
    XCTAssertLessThan(interface, firmware.count - 32)
    XCTAssertEqual(firmware[32 + interface], 0)

    let payload = Data(firmware.dropFirst(32))
    XCTAssertEqual(payload.prefix(2), Data([0x98, 26]))
    XCTAssertNotNil(payload.range(of: Data([0xb8, 25])))
    XCTAssertNotNil(payload.range(of: Data([0xf4])))
    XCTAssertNotNil(payload.range(of: calibration))
    XCTAssertNil(payload.range(of: Data([0xde, 0xad, 0xbe, 0xef])))

    let runtime = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: XCTUnwrap(converted.files[KiwiFirmware.calibrationName])) as? [String: Any])
    XCTAssertEqual(runtime["schema"] as? Int, 1)
    XCTAssertEqual(runtime["machine"] as? String, "k114c")
    XCTAssertEqual(runtime["personality"] as? String, "K114,2")
    let properties = try XCTUnwrap(runtime["properties"] as? [String: [String: Any]])
    let property = try XCTUnwrap(properties["GpCD/touch"])
    XCTAssertEqual(property["byte_count"] as? Int, calibration.count)
    XCTAssertEqual(property["value"] as? String, calibration.base64EncodedString())
    XCTAssertEqual(property["sha256"] as? String, calibration.sha256)

    XCTAssertEqual(converted.receipt.schema, 1)
    XCTAssertEqual(converted.receipt.firmwareSHA256, firmware.sha256)
    XCTAssertEqual(converted.receipt.propertySHA256, ["GpCD/touch": calibration.sha256])
    let privateReceipt = try JSONEncoder().encode(converted.receipt)
    XCTAssertNil(privateReceipt.range(of: calibration))
    XCTAssertNil(privateReceipt.range(of: Data(calibration.base64EncodedString().utf8)))
  }

  func testExactK116PersonalityAndMachineAreSelected() throws {
    let converted = try KiwiFirmware.convertPayload(
      plist(personality: "K116,0", extraRecords: 0), machine: "k116s",
      factory: ["GpCD/touch": calibration])
    let runtime = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: XCTUnwrap(converted.files[KiwiFirmware.calibrationName])) as? [String: Any])
    XCTAssertEqual(runtime["machine"] as? String, "k116s")
    XCTAssertEqual(runtime["personality"] as? String, "K116,0")
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(personality: "K116,0", extraRecords: 0), machine: "k114s",
        factory: ["cal.bin": calibration]))
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(), machine: "j314s", factory: ["cal.bin": calibration]))
  }

  func testMissingAmbiguousAndMismatchedFactoryPropertiesFailClosed() throws {
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(plist(), machine: "k114c", factory: [:]))
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(), machine: "k114c",
        factory: ["GpCD/touch": calibration, "cal.bin": Data([9, 9, 9, 9])]))
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(), machine: "k114c", factory: ["cal.bin": Data([1, 2, 3])]))
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(reference: "<string>wrong type</string>"), machine: "k114c",
        factory: ["cal.bin": calibration]))
  }

  func testRequirementMustBeBooleanAndFalseRecordsAreOmitted() throws {
    XCTAssertThrowsError(
      try KiwiFirmware.convertPayload(
        plist(requirement: "<integer>1</integer>"), machine: "k114c",
        factory: ["cal.bin": calibration]))
    let onlyFalse = plist(requirement: "<false/>")
    let converted = try KiwiFirmware.convertPayload(
      onlyFalse, machine: "k114c", factory: [:])
    XCTAssertTrue(converted.receipt.propertySHA256.isEmpty)
    let runtime = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: XCTUnwrap(converted.files[KiwiFirmware.calibrationName])) as? [String: Any])
    XCTAssertEqual((runtime["properties"] as? [String: Any])?.count, 0)
  }
}
