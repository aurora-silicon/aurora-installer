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
      let url = try XCTUnwrap(Bundle.module.url(
        forResource: "native-payload-vectors", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testAllDistributionLayoutsMatchTheLockedBackendReference() async throws {
      let fixture = try fixture()
      XCTAssertEqual(fixture.vectors.count, 38)
      for vector in fixture.vectors {
        let archive = try await IPSWArchive.open(PayloadFixtureSource(
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

    func testBooleanPartitionFieldsCannotBeStringsOrNumbers() async throws {
      let fixture = try fixture()
      let vector = try XCTUnwrap(fixture.vectors.first)
      let archive = try await IPSWArchive.open(PayloadFixtureSource(
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
      let archive = try await IPSWArchive.open(PayloadFixtureSource(
        bytes: try XCTUnwrap(fixture.archives["btrfs"])))
      for metadata in [Data(), Data(repeating: 32, count: 65_537), Data("[]".utf8),
                       Data("{\"os_list\":[]}".utf8)] {
        do {
          try await NativePayloadPreflight.validate(
            metadata: metadata, payloadName: "payload.zip", archive: archive)
          XCTFail("Invalid metadata admitted")
        } catch {}
      }
    }
  }
#endif
