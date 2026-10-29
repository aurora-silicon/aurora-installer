#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  private struct PayloadFixtureSource: FirmwareRangeReading {
    let bytes: Data
    var sizeBytes: Int { bytes.count }
    func read(offset: Int, count: Int) async throws -> Data {
      guard offset >= 0, count > 0, offset <= bytes.count - count else {
        throw NativePayloadPreflightError.invalidPayload
      }
      return bytes.subdata(in: offset..<(offset + count))
    }
  }

  final class NativePayloadPreflightTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Decodable {
      struct Vector: Decodable {
        let name: String
        let metadata: String
        let archive: String
        let accepted: Bool
      }
      let archives: [String: Data]
      let vectors: [Vector]
    }

    private func fixture() throws -> Fixture {
      let url = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-payload-vectors", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testAllDistributionLayoutsMatchTheLockedBackendReference() async throws {
      let fixture = try fixture()
      XCTAssertEqual(fixture.vectors.count, 38)
      for vector in fixture.vectors {
        let archive = try await IPSWArchive.open(
          PayloadFixtureSource(
            bytes: try XCTUnwrap(fixture.archives[vector.archive])))
        var accepted = false
        do {
          try await NativePayloadPreflight.validate(
            metadata: Data(vector.metadata.utf8), payloadName: "payload.zip", archive: archive)
          accepted = true
        } catch {}
        XCTAssertEqual(accepted, vector.accepted, vector.name)
      }
    }

    func testNixOSRefusesAnEFILoaderTiedToTheSourcePartitionNumber() async throws {
      let fixture = try fixture()
      let vector = try XCTUnwrap(
        fixture.vectors.first { $0.name == "nixos-btrfs-v1-kde" })
      let oldArchive = try await IPSWArchive.open(
        PayloadFixtureSource(bytes: try XCTUnwrap(fixture.archives["btrfs"])))
      do {
        try await NativePayloadPreflight.validate(
          metadata: Data(vector.metadata.utf8), payloadName: "payload.zip",
          archive: oldArchive)
        XCTFail("Position-dependent GRUB loader admitted")
      } catch NativePayloadPreflightError.invalidPayload {}
    }

    func testNixOSGRUBMustSearchForItsExactBootFilesystemUUID() {
      var header = Data(repeating: 0, count: 0x478)
      header.replaceSubrange(
        0x468..<0x478,
        with: Data([
          0x41, 0xdc, 0x57, 0xcf, 0x2d, 0x07, 0x50, 0xf9,
          0xba, 0x96, 0x7c, 0x95, 0xcd, 0xe8, 0x5a, 0xda,
        ]))
      let portable = Data(
        "MZsearch.fs_uuid 41dc57cf-2d07-50f9-ba96-7c95cde85ada root\nset prefix=($root)/grub\n"
          .utf8)
      XCTAssertTrue(NativePayloadPreflight.portableGRUB(bootHeader: header, efi: portable))
      XCTAssertFalse(
        NativePayloadPreflight.portableGRUB(
          bootHeader: header, efi: Data("MZ(,gpt2)/grub".utf8)))
      XCTAssertFalse(
        NativePayloadPreflight.portableGRUB(
          bootHeader: header,
          efi: Data(
            "MZsearch.fs_uuid 00000000-0000-0000-0000-000000000001 root\nset prefix=($root)/grub\n"
              .utf8)))
      header.replaceSubrange(0x468..<0x478, with: Data(repeating: 0, count: 16))
      XCTAssertFalse(NativePayloadPreflight.portableGRUB(bootHeader: header, efi: portable))
    }

    /// Current Aurora NixOS images: GRUB has no built-in prefix and reads the
    /// hardened grub.cfg beside it, which finds Boot by UUID on its own disk.
    func testNixOSGRUBMayFindItsBootFilesystemThroughTheConfigBesideIt() {
      var header = Data(repeating: 0, count: 0x478)
      header.replaceSubrange(
        0x468..<0x478,
        with: Data([
          0x41, 0xdc, 0x57, 0xcf, 0x2d, 0x07, 0x50, 0xf9,
          0xba, 0x96, 0x7c, 0x95, 0xcd, 0xe8, 0x5a, 0xda,
        ]))
      let uuid = "41dc57cf-2d07-50f9-ba96-7c95cde85ada"
      func config(_ uuid: String, prefix: Bool = true) -> Data {
        Data(
          """
          if [ -n "$aurora_boot" ]; then
            search --no-floppy --fs-uuid --set=root --hint="$aurora_boot" \(uuid)
          \(prefix ? "  set prefix=($root)/grub\n" : "")  configfile ($root)/grub/grub.cfg
          fi
          """.utf8)
      }
      let grub = Data("MZ grub_search_fs_uuid partmap/gpt.c GPT entry %d".utf8)
      XCTAssertTrue(
        NativePayloadPreflight.portableGRUB(bootHeader: header, efi: grub, config: config(uuid)))
      // No config, another filesystem's UUID, or no prefix from the search.
      XCTAssertFalse(NativePayloadPreflight.portableGRUB(bootHeader: header, efi: grub))
      XCTAssertFalse(
        NativePayloadPreflight.portableGRUB(
          bootHeader: header, efi: grub,
          config: config("00000000-0000-0000-0000-000000000001")))
      XCTAssertFalse(
        NativePayloadPreflight.portableGRUB(
          bootHeader: header, efi: grub, config: config(uuid, prefix: false)))
      // A built-in slot prefix, or another built-in search, wins over the config.
      for efi in ["MZ(,gpt2)/grub", "MZ(hd0,gpt2)/grub", "MZsearch.fs_uuid 0000 root\n"] {
        XCTAssertFalse(
          NativePayloadPreflight.portableGRUB(
            bootHeader: header, efi: Data(efi.utf8), config: config(uuid)), efi)
      }
    }

    func testBooleanPartitionFieldsCannotBeStringsOrNumbers() async throws {
      let fixture = try fixture()
      let vector = try XCTUnwrap(fixture.vectors.first)
      let archive = try await IPSWArchive.open(
        PayloadFixtureSource(
          bytes: try XCTUnwrap(fixture.archives[vector.archive])))
      for value in [1 as Any, "true", NSNull()] {
        var document = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(vector.metadata.utf8)) as? [String: Any])
        var templates = document["os_list"] as! [[String: Any]]
        var partitions = templates[0]["partitions"] as! [[String: Any]]
        partitions[2]["expand"] = value
        templates[0]["partitions"] = partitions
        document["os_list"] = templates
        do {
          try await NativePayloadPreflight.validate(
            metadata: JSONSerialization.data(withJSONObject: document),
            payloadName: "payload.zip", archive: archive)
          XCTFail("Non-Boolean partition flag admitted")
        } catch NativePayloadPreflightError.invalidPartitions {}
      }
    }

    func testMetadataBoundsAndTopLevelShapeFailClosed() async throws {
      let fixture = try fixture()
      let archive = try await IPSWArchive.open(
        PayloadFixtureSource(
          bytes: try XCTUnwrap(fixture.archives["btrfs"])))
      for metadata in [
        Data(), Data(repeating: 32, count: 65_537), Data("[]".utf8),
        Data("{\"os_list\":[]}".utf8),
      ] {
        do {
          try await NativePayloadPreflight.validate(
            metadata: metadata, payloadName: "payload.zip", archive: archive)
          XCTFail("Invalid metadata admitted")
        } catch {}
      }
    }
  }
#endif
