import Foundation
import XCTest

@testable import AuroraFirmware

final class FirmwarePackageTests: XCTestCase {
  private struct Fixture: Decodable {
    struct File: Decodable { let name: String; let base64: String }
    let files: [File]
    let outputs: [String: String]
  }

  func testExactInteroperabilityWithExistingVendorFirmwareArchives() throws {
    let url = try XCTUnwrap(Bundle.module.url(
      forResource: "package-interop", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let inputs = try fixture.files.map {
      FirmwarePackageInput(name: $0.name, bytes: try XCTUnwrap(Data(base64Encoded: $0.base64)))
    }
    let result = try FirmwarePackageBuilder.build(inputs)
    for (name, bytes) in ["firmware.tar": result.tar, "firmware.cpio": result.cpio, "manifest.txt": result.manifest] {
      XCTAssertEqual(bytes, Data(base64Encoded: try XCTUnwrap(fixture.outputs[name])), name)
    }
  }

  func testUnsafePathsAndConflictingNamesAreRefused() throws {
    for name in ["", "/absolute", "../escape", "a/../escape", "a//b", "a\\b", "a b", "a\nFILE", "é", ".vendorfw.manifest", String(repeating: "x", count: 256)] {
      XCTAssertThrowsError(try FirmwarePackageBuilder.build([FirmwarePackageInput(name: name, bytes: Data())]), name)
    }
    for names in [["a", "a"], ["a", "a/b"], ["a/b", "a"]] {
      XCTAssertThrowsError(try FirmwarePackageBuilder.build(names.map { FirmwarePackageInput(name: $0, bytes: Data()) }))
    }
    XCTAssertThrowsError(try FirmwarePackageBuilder.build([]))
  }

  func testLongUSTARPathsAndDuplicateContentHaveDefinedHeaders() throws {
    let name = String(repeating: "p", count: 120) + "/firmware.bin"
    let bytes = Data("content".utf8)
    let result = try FirmwarePackageBuilder.build([
      FirmwarePackageInput(name: name, bytes: bytes),
      FirmwarePackageInput(name: "alias.bin", bytes: bytes),
    ])
    XCTAssertEqual(String(decoding: result.tar[0..<12], as: UTF8.self), "firmware.bin")
    XCTAssertEqual(String(decoding: result.tar[345..<465], as: UTF8.self), String(repeating: "p", count: 120))
    XCTAssertEqual(result.tar[156], UInt8(ascii: "0"))
    XCTAssertEqual(result.tar[1024 + 156], UInt8(ascii: "0"))
    XCTAssertFalse(String(decoding: result.manifest, as: UTF8.self).contains("LINK"))
  }
}
