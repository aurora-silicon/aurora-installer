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
      FirmwarePackageInput(
        name: "fud_firmware/Firmware/input.im4p", bytes: Data("raw firmware".utf8)),
      FirmwarePackageInput(name: "com.apple.factorydata/local", bytes: Data("local record".utf8)),
    ]
    let links = ["fud_firmware/j700/Multitouch.im4p": "../Firmware/input.im4p"]
    let first = try FirmwarePackageBuilder.fallback(files, symbolicLinks: links)
    XCTAssertEqual(
      first, try FirmwarePackageBuilder.fallback(Array(files.reversed()), symbolicLinks: links))
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
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("fud_firmware/j700/Multitouch.im4p")),
      Data("raw firmware".utf8))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appendingPathComponent("fud_firmware/j700/Multitouch.im4p").path),
      "../Firmware/input.im4p")
    XCTAssertThrowsError(
      try FirmwarePackageBuilder.fallback(
        files, symbolicLinks: ["link": "../com.apple.factorydata/local"]))
    // Radio aliases name a file in their own directory, and nothing else.
    let radio = [FirmwarePackageInput(name: "firmware/wifi/C-1/a.trx", bytes: Data("trx".utf8))]
    let aliased = try FirmwarePackageBuilder.fallback(
      radio, symbolicLinks: ["firmware/wifi/C-1/a-X0.trx": "a.trx"])
    try aliased.write(to: archive)
    let radioProcess = Process()
    radioProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    radioProcess.arguments = ["-xzf", archive.path, "-C", root.path]
    try radioProcess.run()
    radioProcess.waitUntilExit()
    XCTAssertEqual(radioProcess.terminationStatus, 0)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appendingPathComponent("firmware/wifi/C-1/a-X0.trx").path), "a.trx")
    XCTAssertThrowsError(
      try FirmwarePackageBuilder.fallback(
        radio, symbolicLinks: ["firmware/wifi/C-1/b.trx": "C-1/a.trx"]))
    XCTAssertThrowsError(
      try FirmwarePackageBuilder.fallback(
        radio, symbolicLinks: ["firmware/wifi/C-1/b.trx": "missing.trx"]))
    XCTAssertThrowsError(
      try FirmwarePackageBuilder.fallback(
        files, symbolicLinks: ["fud_firmware/j700/link": "../../outside"]))
    XCTAssertThrowsError(
      try FirmwarePackageBuilder.fallback(
        [
          FirmwarePackageInput(name: "a", bytes: Data()),
          FirmwarePackageInput(name: "a-b", bytes: Data()),
          FirmwarePackageInput(name: "a/b", bytes: Data()),
        ], symbolicLinks: [:]))
  }

  /// macOS's radio aliases may name another alias, as an antenna SKU's names
  /// its board's, which names a shared file. The archive keeps them so.
  func testFallbackKeepsRadioAliasesThatNameAnAlias() throws {
    let radio = [
      FirmwarePackageInput(name: "firmware/wifi/C-1/guam.trx", bytes: Data("trx".utf8))
    ]
    let archive = try FirmwarePackageBuilder.fallback(
      radio,
      symbolicLinks: [
        "firmware/wifi/C-1/hostomel.trx": "guam.trx",
        "firmware/wifi/C-1/hostomel-X0.trx": "hostomel.trx",
      ])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fallback.tar.gz")
    try archive.write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xzf", file.path, "-C", root.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let alias = root.appendingPathComponent("firmware/wifi/C-1/hostomel-X0.trx")
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), "hostomel.trx")
    XCTAssertEqual(try Data(contentsOf: alias), Data("trx".utf8))
    // Every chain ends at a file: a loop, or a chain into nothing, is refused.
    for target in ["a.trx", "missing.trx"] {
      XCTAssertThrowsError(
        try FirmwarePackageBuilder.fallback(
          radio,
          symbolicLinks: [
            "firmware/wifi/C-1/a.trx": "b.trx", "firmware/wifi/C-1/b.trx": target,
          ]), target)
    }
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

  func testSensorRootKeysAreOwnerOnlyInBothArchives() throws {
    // Synthetic bytes. The calibration shares the J700 key's bytes, which
    // must not make the key a hard link to a world-readable file.
    let shared = Data("synthetic record".utf8)
    let result = try FirmwarePackageBuilder.build([
      FirmwarePackageInput(name: "apple/mesacal-j700.bin", bytes: shared),
      FirmwarePackageInput(name: "apple/msrk-j616c.bin", bytes: Data("other record".utf8)),
      FirmwarePackageInput(name: "apple/msrk-j700.bin", bytes: shared),
      FirmwarePackageInput(name: "brcm/msrk-j700.bin", bytes: Data("not a key".utf8)),
    ])
    XCTAssertFalse(String(decoding: result.manifest, as: UTF8.self).contains("LINK"))
    XCTAssertEqual(
      try Self.tarModes(result.tar),
      [
        "apple/mesacal-j700.bin": 0o644, "apple/msrk-j616c.bin": 0o600,
        "apple/msrk-j700.bin": 0o600, "brcm/msrk-j700.bin": 0o644,
      ])
    XCTAssertEqual(
      try Self.cpioModes(result.cpio),
      [
        "vendorfw": 0o040755, "vendorfw/apple": 0o040755, "vendorfw/brcm": 0o040755,
        "vendorfw/apple/mesacal-j700.bin": 0o100644, "vendorfw/apple/msrk-j616c.bin": 0o100600,
        "vendorfw/apple/msrk-j700.bin": 0o100600, "vendorfw/brcm/msrk-j700.bin": 0o100644,
        "vendorfw/.vendorfw.manifest": 0o100644,
      ])
    for name in ["apple/sub/msrk-j700.bin", "apple/msrk-j700.txt", "msrk-j700.bin"] {
      XCTAssertEqual(FirmwarePackageBuilder.mode(of: name), 0o644, name)
    }
  }

  /// Each USTAR member's permission bits; every member must be owned by root.
  private static func tarModes(_ archive: Data) throws -> [String: Int] {
    var modes = [String: Int]()
    var offset = 0
    while offset + 512 <= archive.count {
      let header = Data(archive[offset..<(offset + 512)])
      if header.allSatisfy({ $0 == 0 }) { break }
      func text(_ start: Int, _ width: Int) -> String {
        String(decoding: header[start..<(start + width)].prefix { $0 != 0 }, as: UTF8.self)
      }
      func number(_ start: Int, _ width: Int) throws -> Int {
        try XCTUnwrap(Int(text(start, width), radix: 8))
      }
      let prefix = text(345, 155)
      let name = (prefix.isEmpty ? "" : prefix + "/") + text(0, 100)
      XCTAssertEqual(try number(108, 8), 0, name)
      XCTAssertEqual(try number(116, 8), 0, name)
      modes[name] = try number(100, 8)
      offset += 512 + (try number(124, 12) + 511) / 512 * 512
    }
    return modes
  }

  /// Each newc entry's mode; every entry must be owned by root.
  private static func cpioModes(_ archive: Data) throws -> [String: Int] {
    var modes = [String: Int]()
    var offset = 0
    while offset + 110 <= archive.count {
      let header = Data(archive[offset..<(offset + 110)])
      XCTAssertEqual(String(decoding: header.prefix(6), as: UTF8.self), "070701")
      func field(_ index: Int) throws -> Int {
        let start = 6 + 8 * index
        return try XCTUnwrap(
          Int(String(decoding: header[start..<(start + 8)], as: UTF8.self), radix: 16))
      }
      let nameBytes = try field(11)
      let name = String(
        decoding: archive[(offset + 110)..<(offset + 109 + nameBytes)], as: UTF8.self)
      if name == "TRAILER!!!" { return modes }
      XCTAssertEqual(try field(2), 0, name)
      XCTAssertEqual(try field(3), 0, name)
      modes[name] = try field(1)
      let data = (offset + 110 + nameBytes + 3) & ~3
      offset = (data + (try field(6)) + 3) & ~3
    }
    XCTFail("newc archive has no trailer")
    return modes
  }
}
