import Foundation
import XCTest

@testable import AuroraFirmware

final class FirmwarePackageTests: XCTestCase {
  private struct Fixture: Decodable {
    struct File: Decodable {
      let name: String
      let base64: String
    }
    let files: [File]
    let outputs: [String: String]
  }

  func testExactInteroperabilityWithExistingVendorFirmwareArchives() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "package-interop", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let inputs = try fixture.files.map {
      FirmwarePackageInput(name: $0.name, bytes: try XCTUnwrap(Data(base64Encoded: $0.base64)))
    }
    let result = try FirmwarePackageBuilder.build(inputs)
    for (name, bytes) in [
      "firmware.tar": result.tar, "firmware.cpio": result.cpio, "manifest.txt": result.manifest,
    ] {
      XCTAssertEqual(bytes, Data(base64Encoded: try XCTUnwrap(fixture.outputs[name])), name)
    }
  }

  func testFallbackReproducesStableRawInputsAndAliasesWithAStandardArchiver() throws {
    let files = [
      FirmwarePackageInput(name: "fud_firmware/Firmware/input.im4p", bytes: Data("raw firmware".utf8)),
      FirmwarePackageInput(name: "com.apple.factorydata/local", bytes: Data("local record".utf8)),
    ]
    let links = ["fud_firmware/j700/Multitouch.im4p": "../Firmware/input.im4p"]
    let first = try FirmwarePackageBuilder.fallback(files, symbolicLinks: links)
    XCTAssertEqual(first, try FirmwarePackageBuilder.fallback(Array(files.reversed()), symbolicLinks: links))
    XCTAssertEqual(Array(first.prefix(8)), [31, 139, 8, 0, 0, 0, 0, 0])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("fallback.tar.gz")
    try first.write(to: archive)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xzf", archive.path, "-C", root.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("fud_firmware/j700/Multitouch.im4p")), Data("raw firmware".utf8))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
      atPath: root.appendingPathComponent("fud_firmware/j700/Multitouch.im4p").path), "../Firmware/input.im4p")
    XCTAssertThrowsError(try FirmwarePackageBuilder.fallback(files, symbolicLinks: ["link": "../com.apple.factorydata/local"]))
    XCTAssertThrowsError(try FirmwarePackageBuilder.fallback(files, symbolicLinks: ["fud_firmware/j700/link": "../../outside"]))
    XCTAssertThrowsError(try FirmwarePackageBuilder.fallback([
      FirmwarePackageInput(name: "a", bytes: Data()), FirmwarePackageInput(name: "a-b", bytes: Data()),
      FirmwarePackageInput(name: "a/b", bytes: Data()),
    ], symbolicLinks: [:]))
  }

  func testUnsafePathsAndConflictingNamesAreRefused() throws {
    for name in [
      "", "/absolute", "../escape", "a/../escape", "a//b", "a\\b", "a b", "a\nFILE", "é",
      ".vendorfw.manifest", String(repeating: "x", count: 256),
    ] {
      XCTAssertThrowsError(
        try FirmwarePackageBuilder.build([FirmwarePackageInput(name: name, bytes: Data())]), name)
    }
    for names in [["a", "a"], ["a", "a/b"], ["a/b", "a"]] {
      XCTAssertThrowsError(
        try FirmwarePackageBuilder.build(
          names.map { FirmwarePackageInput(name: $0, bytes: Data()) }))
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
    XCTAssertEqual(
      String(decoding: result.tar[345..<465], as: UTF8.self), String(repeating: "p", count: 120))
    XCTAssertEqual(result.tar[156], UInt8(ascii: "0"))
    XCTAssertEqual(result.tar[1024 + 156], UInt8(ascii: "0"))
    XCTAssertFalse(String(decoding: result.manifest, as: UTF8.self).contains("LINK"))
  }
}
