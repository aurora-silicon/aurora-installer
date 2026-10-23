#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  private struct BootFixtureSource: FirmwareRangeReading {
    let bytes: Data
    var sizeBytes: Int { bytes.count }
    func read(offset: Int, count: Int) async throws -> Data {
      guard offset >= 0, count > 0, offset <= bytes.count - count else {
        throw NativeBootChainError.invalidStage1
      }
      return bytes.subdata(in: offset..<(offset + count))
    }
  }

  final class NativeFirmwareSelectionTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Decodable, Sendable {
      struct Firmware: Decodable, Sendable {
        struct Expected: Decodable, Sendable {
          let version: String
          let sourceURL: URL
          let stubBytes: UInt64
        }
        let name: String
        let device: String
        let hardware: NativeInspectionHardware
        let metadata: String
        let expected: Expected?
      }
      struct Boot: Decodable, Sendable {
        struct Expected: Decodable, Sendable {
          let member: String?
          let window: UInt32
          let layout: [String: String]
        }
        let name: String
        let device: String
        let firmware: String
        let metadata: String
        let archive: String
        let expected: Expected?
      }
      struct Filled: Decodable, Sendable {
        let window: UInt32
        let sha256: String
      }
      let firmware: [Firmware]
      let boot: [Boot]
      let archives: [String: Data]
      let stage1: Data
      let filled: [Filled]
      let completeArchive: Data
      let completeMetadata: String
    }

    private func fixture() throws -> Fixture {
      let url = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-firmware-selection-vectors", withExtension: "json",
          subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testFirmwareVersionURLAndStubMatchTheAuthenticatedChooser() throws {
      let fixture = try fixture()
      let policy = try NativeInspectionPolicy.sealed()
      XCTAssertEqual(fixture.firmware.count, 144)
      for vector in fixture.firmware {
        let metadata = try NativeInstallationMetadata(data: Data(vector.metadata.utf8))
        let facts = NativeFirmwareSelection.Facts(
          deviceIdentifier: vector.device, hardware: vector.hardware)
        if let expected = vector.expected {
          let selected = try NativeFirmwareSelection.choose(
            deviceIdentifier: vector.device, facts: facts, metadata: metadata, policy: policy)
          XCTAssertEqual(selected.version, expected.version, vector.name)
          XCTAssertEqual(selected.sourceURL, expected.sourceURL, vector.name)
          XCTAssertEqual(selected.stubBytes, expected.stubBytes, vector.name)
        } else {
          XCTAssertThrowsError(
            try NativeFirmwareSelection.choose(
              deviceIdentifier: vector.device, facts: facts, metadata: metadata, policy: policy),
            vector.name)
        }
      }
    }

    func testFollowingTheNamedMacOSUpdateMakesTheFirmwareSelectable() throws {
      let fixture = try fixture()
      let policy = try NativeInspectionPolicy.sealed()
      var named = 0
      for vector in fixture.firmware where vector.expected == nil {
        let metadata = try NativeInstallationMetadata(data: Data(vector.metadata.utf8))
        func choose(_ hardware: NativeInspectionHardware) throws -> NativeFirmwareSelection {
          try NativeFirmwareSelection.choose(
            deviceIdentifier: vector.device,
            facts: .init(deviceIdentifier: vector.device, hardware: hardware),
            metadata: metadata, policy: policy)
        }
        do {
          _ = try choose(vector.hardware)
          XCTFail("\(vector.name): firmware admitted")
        } catch NativeFirmwareSelectionError.macOSUpdateRequired(let version) {
          // A Mac updated to the named macOS has at least that release's
          // boot firmware, macOS and recovery versions.
          named += 1
          let entry = try XCTUnwrap(policy.firmware.first { $0.version == version }, vector.name)
          let updated = NativeInspectionHardware(
            chipID: vector.hardware.chipID, bootVersion: entry.minimumBoot,
            macOSVersion: version, recoveryVersion: entry.minimumRecovery)
          XCTAssertNoThrow(try choose(updated), vector.name)
        } catch NativeFirmwareSelectionError.noCompatibleFirmware {
          // No macOS update helps when the release offers this Mac nothing.
          let newest = NativeInspectionHardware(
            chipID: vector.hardware.chipID, bootVersion: "mBoot-99999", macOSVersion: "99.0",
            recoveryVersion: "99.0.0.0.0,0")
          XCTAssertThrowsError(try choose(newest), vector.name) {
            XCTAssertEqual(
              $0 as? NativeFirmwareSelectionError, .noCompatibleFirmware, vector.name)
          }
        } catch {}
      }
      XCTAssertEqual(named, 27)
    }

    func testAMacOnOlderFirmwareIsToldWhichMacOSToInstall() throws {
      let policy = try NativeInspectionPolicy.sealed()
      func choose(
        _ device: String, _ hardware: NativeInspectionHardware, supported: [String]?,
        policy changed: NativeInspectionPolicy? = nil
      ) throws -> NativeFirmwareSelection {
        var template: [String: Any] = [
          "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
          "partitions": [["size": "1GiB"]],
        ]
        if let supported { template["supported_fw"] = supported }
        return try NativeFirmwareSelection.choose(
          deviceIdentifier: device, facts: .init(deviceIdentifier: device, hardware: hardware),
          metadata: NativeInstallationMetadata(
            data: JSONSerialization.data(withJSONObject: ["os_list": [template]])),
          policy: changed ?? policy)
      }
      func assertUpdate(
        _ expected: NativeFirmwareSelectionError, _ selection: @autoclosure () throws -> Any,
        line: UInt = #line
      ) {
        XCTAssertThrowsError(try selection(), line: line) {
          XCTAssertEqual($0 as? NativeFirmwareSelectionError, expected, line: line)
        }
      }
      // A MacBook Neo on macOS 26.6 (25G72) has mBoot-18000.161.9; the 26.6.2
      // firmware needs mBoot-18000.161.10, so the Neo must update to 26.6.2.
      let neo = NativeInspectionHardware(
        chipID: 0x8140, bootVersion: "mBoot-18000.161.9", macOSVersion: "26.6",
        recoveryVersion: "25.7.72.0.0,0")
      assertUpdate(
        .macOSUpdateRequired(version: "26.6.2"),
        try choose("apple,j700", neo, supported: ["26.6.2"]))
      XCTAssertEqual(try choose("apple,j700", neo, supported: nil).version, "26.6")
      let updatedNeo = NativeInspectionHardware(
        chipID: 0x8140, bootVersion: "mBoot-18000.161.10", macOSVersion: "26.6.2",
        recoveryVersion: "25.7.83.0.0,0")
      XCTAssertEqual(try choose("apple,j700", updatedNeo, supported: ["26.6.2"]).version, "26.6.2")
      assertUpdate(.noCompatibleFirmware, try choose("apple,j700", neo, supported: ["13.5"]))

      // The lowest firmware this Mac may use names the update, not the newest.
      let air = NativeInspectionHardware(
        chipID: 0x8122, bootVersion: "iBoot-10151.121.1", macOSVersion: "14.6",
        recoveryVersion: "23.6.74.0.0,0")
      assertUpdate(
        .macOSUpdateRequired(version: "14.8.3"),
        try choose("apple,j613", air, supported: ["14.8.3", "26.6.2"]))
      assertUpdate(
        .macOSUpdateRequired(version: "26.6.2"),
        try choose("apple,j613", air, supported: ["26.6.2"]))

      // Expert-only firmware is never a reason to update macOS.
      var object =
        try JSONSerialization.jsonObject(with: Data(NativeInspectionPolicySource.json.utf8))
        as! [String: Any]
      var entries = object["firmware"] as! [[String: Any]]
      for index in entries.indices where entries[index]["version"] as? String == "26.6.2" {
        entries[index]["expert"] = true
      }
      object["firmware"] = entries
      let expert = try JSONDecoder().decode(
        NativeInspectionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
      assertUpdate(
        .noCompatibleFirmware,
        try choose("apple,j700", neo, supported: ["26.6.2"], policy: expert))
    }

    func testBoardBootObjectsAndESPLayoutMatchTheLockedBackend() async throws {
      let fixture = try fixture()
      XCTAssertEqual(fixture.boot.count, 56)
      for vector in fixture.boot {
        let archive = try await IPSWArchive.open(
          BootFixtureSource(
            bytes: try XCTUnwrap(fixture.archives[vector.archive])))
        do {
          let selected = try await NativeBootChain.admit(
            metadata: Data(vector.metadata.utf8), archive: archive,
            deviceIdentifier: vector.device, firmware: vector.firmware)
          let expected = try XCTUnwrap(vector.expected, vector.name)
          XCTAssertEqual(selected.stage1Member, expected.member, vector.name)
          XCTAssertEqual(selected.windowMilliseconds, expected.window, vector.name)
          XCTAssertEqual(selected.espLayout, expected.layout, vector.name)
        } catch {
          if vector.expected != nil { XCTFail("\(vector.name): \(error)") }
        }
      }
    }

    func testFilledBootObjectsMatchTheReferenceBytesAndKeepTheirLength() throws {
      let fixture = try fixture()
      for vector in fixture.filled {
        let filled = try NativeBootChain.fillStage1(
          fixture.stage1, uuid: "12345678-1234-1234-1234-123456789abc",
          path: "m1n1/boot.bin", windowMilliseconds: vector.window)
        XCTAssertEqual(filled.count, fixture.stage1.count)
        XCTAssertEqual(SHA256Digest(hashing: filled).rawValue, "sha256:" + vector.sha256)
      }
      let magic = Data("AURORA-S1-CFG01\0".utf8)
      for image in [
        Data(), Data(fixture.stage1.dropLast()), fixture.stage1 + magic,
        fixture.stage1 + fixture.stage1,
      ] {
        XCTAssertThrowsError(
          try NativeBootChain.fillStage1(
            image, uuid: "12345678-1234-1234-1234-123456789abc", path: "m1n1/boot.bin",
            windowMilliseconds: 0))
      }
      for path in [
        "../boot.bin", "/boot.bin", "m1n1//boot.bin", "m1n1/./boot.bin",
        "m1n1/boot;bin", "m1n1/é.bin", String(repeating: "a", count: 191),
      ] {
        XCTAssertThrowsError(
          try NativeBootChain.fillStage1(
            fixture.stage1, uuid: "12345678-1234-1234-1234-123456789abc", path: path,
            windowMilliseconds: 0))
      }
      XCTAssertThrowsError(
        try NativeBootChain.fillStage1(
          fixture.stage1, uuid: "12345678-1234-1234-1234-123456789ABC", path: "m1n1/boot.bin",
          windowMilliseconds: 0))
      XCTAssertThrowsError(
        try NativeBootChain.fillStage1(
          fixture.stage1, uuid: "12345678-1234-1234-1234-123456789abc", path: "m1n1/boot.bin",
          windowMilliseconds: 100000))
      var version = fixture.stage1
      let offset = try XCTUnwrap(version.range(of: magic)).upperBound
      version[offset] = 2
      XCTAssertThrowsError(
        try NativeBootChain.fillStage1(
          version, uuid: "12345678-1234-1234-1234-123456789abc", path: "m1n1/boot.bin",
          windowMilliseconds: 0))
    }

    func testChangedDeviceAndUntrustedRestoreURLsFailClosed() throws {
      let vector = try XCTUnwrap(fixture().firmware.first { $0.name == "j700-2-current" })
      let metadata = try NativeInstallationMetadata(data: Data(vector.metadata.utf8))
      let facts = NativeFirmwareSelection.Facts(
        deviceIdentifier: "apple,j700", hardware: vector.hardware)
      let policy = try NativeInspectionPolicy.sealed()
      XCTAssertThrowsError(
        try NativeFirmwareSelection.choose(
          deviceIdentifier: "apple,j613", facts: facts, metadata: metadata, policy: policy))
      for source in [
        "http://updates.cdn-apple.com/image.ipsw", "https://example.org/image.ipsw",
        "https://updates.cdn-apple.com/image.ipsw?token=x",
        "https://user@updates.cdn-apple.com/image.ipsw",
      ] {
        var object =
          try JSONSerialization.jsonObject(with: Data(NativeInspectionPolicySource.json.utf8))
          as! [String: Any]
        var entries = object["firmware"] as! [[String: Any]]
        entries[0]["sourceURL"] = source
        object["firmware"] = entries
        let changed = try JSONDecoder().decode(
          NativeInspectionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(
          try NativeFirmwareSelection.choose(
            deviceIdentifier: "apple,j700", facts: facts, metadata: metadata, policy: changed))
      }
    }

    func testProductionPreflightChecksFirmwareAndBootObjectsInTheImportedPackage() async throws {
      let fixture = try fixture()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let metadata = directory.appendingPathComponent("metadata.json")
      let payload = directory.appendingPathComponent("payload.zip")
      try Data(fixture.completeMetadata.utf8).write(to: metadata)
      try fixture.completeArchive.write(to: payload)
      let package = ImportedEngineHandoffPackage(
        packageURL: directory, manifestURL: directory.appendingPathComponent("manifest.json"),
        requestURL: directory.appendingPathComponent("request.json"),
        identityURL: directory.appendingPathComponent("identity.json"),
        metadataURL: metadata,
        payloadURL: payload,
        bindingDigest: "sha256:" + String(repeating: "a", count: 64),
        planDigest: "sha256:" + String(repeating: "b", count: 64),
        deviceIdentifier: "apple,j700", storeIdentifier: "disk0")
      let hardware = NativeInspectionHardware(
        chipID: 0x8140, bootVersion: "mBoot-18000.161.10",
        macOSVersion: "26.6.2", recoveryVersion: "25.7.83.0.0,0")
      try await NativePayloadPreflight.check(
        package, owner: geteuid(),
        firmwareFacts: {
          NativeFirmwareSelection.Facts(deviceIdentifier: "apple,j700", hardware: hardware)
        })
      do {
        try await NativePayloadPreflight.check(
          package, owner: geteuid(),
          firmwareFacts: {
            NativeFirmwareSelection.Facts(deviceIdentifier: "apple,j613", hardware: hardware)
          })
        XCTFail("Changed host admitted by production preflight")
      } catch NativeFirmwareSelectionError.deviceChanged {}
      var changed =
        try JSONSerialization.jsonObject(with: Data(fixture.completeMetadata.utf8))
        as! [String: Any]
      var templates = changed["os_list"] as! [[String: Any]]
      templates[0]["allowed_device_classes"] = ["j613ap"]
      changed["os_list"] = templates
      try JSONSerialization.data(withJSONObject: changed).write(to: metadata)
      do {
        try await NativePayloadPreflight.check(
          package, owner: geteuid(),
          firmwareFacts: {
            NativeFirmwareSelection.Facts(deviceIdentifier: "apple,j700", hardware: hardware)
          })
        XCTFail("Excluded host admitted by production preflight")
      } catch NativeBootChainError.unsupportedBoard {}
      XCTAssertEqual(try Data(contentsOf: payload), fixture.completeArchive)
    }
  }
#endif
