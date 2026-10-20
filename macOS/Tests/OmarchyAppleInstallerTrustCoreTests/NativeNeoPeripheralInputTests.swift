#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import NativeFirmwareFixtureSupport
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeNeoPeripheralInputTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Decodable, Sendable {
      let rawFiles: [String: Data]
      let local: [String: Data]
      let payload: Data
      let metadata: String
      let manifest: NativeNeoPeripheralPreparer.Manifest
      let outputSHA256: [String: String]
    }

    func testConvertedSnapshotMatchesTheReferenceManifestAndStaysOutsideRetainedInputs()
      async throws
    {
      let fixture = try InputFixture()
      defer { fixture.remove() }
      let prepared = try await fixture.preparer().prepare(
        package: fixture.package, rawDirectory: fixture.raw)
      defer { try? prepared.remove() }
      XCTAssertEqual(prepared.directory.deletingLastPathComponent().path, fixture.root.path)
      XCTAssertEqual(prepared.recipeSHA256, fixture.value.manifest.recipeSHA256)
      let observed = try Data(
        contentsOf: prepared.directory.appendingPathComponent("manifest.json"))
      let expected =
        try JSONSerialization.jsonObject(with: NeoFirmwareFixture.data()) as! [String: Any]
      XCTAssertEqual(
        try JSONSerialization.jsonObject(with: observed) as! NSDictionary,
        expected["manifest"] as! NSDictionary)
      let tree = try NativeHandoffFileTree(prepared.directory, protected: true, owner: geteuid())
      for (name, sha) in fixture.value.outputSHA256 {
        let record = try XCTUnwrap(fixture.value.manifest.files[name])
        let bytes = try tree.read("files/" + name, maximum: record.bytes)
        XCTAssertEqual(SHA256Digest(hashing: bytes).rawValue, "sha256:" + sha)
        var info = stat()
        XCTAssertEqual(
          lstat(prepared.directory.appendingPathComponent("files/" + name).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
      }
      XCTAssertEqual(
        Set(try FileManager.default.contentsOfDirectory(atPath: fixture.package.packageURL.path)),
        ["metadata.json", "identity.json", "payload.zip"])
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.raw.appendingPathComponent("manifest.json").path))
      try prepared.remove()
      XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
    }

    func testEachAttemptRecollectsLocalInputsInsteadOfCachingAnotherDeviceCalibration() async throws
    {
      let fixture = try InputFixture()
      defer { fixture.remove() }
      let first = try await fixture.preparer().prepare(
        package: fixture.package, rawDirectory: fixture.raw)
      defer { try? first.remove() }
      let other = Data([6, 5, 4, 3, 2, 1])
      let second = try await fixture.preparer(address: other).prepare(
        package: fixture.package, rawDirectory: fixture.raw)
      defer { try? second.remove() }
      XCTAssertNotEqual(first.directory, second.directory)
      let record = "files/mediatek/j700-mt7932-bdaddr.bin"
      XCTAssertEqual(
        try Data(contentsOf: first.directory.appendingPathComponent(record)),
        fixture.value.local["address"])
      XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent(record)), other)
      let manifest = try JSONDecoder().decode(
        NativeNeoPeripheralPreparer.Manifest.self,
        from: Data(contentsOf: second.directory.appendingPathComponent("manifest.json")))
      XCTAssertEqual(
        manifest.localInputs["address"], String(SHA256Digest(hashing: other).rawValue.dropFirst(7))
      )
    }

    func testSensorSnapshotIncludesBothCompleteDeviceLocalContainers() async throws {
      let fixture = try InputFixture()
      defer { fixture.remove() }
      let sensor = NativeSensorInputs(
        calibration: NativeSensorCalibrationTests.calibration(),
        rootKey: NativeSensorCalibrationTests.rootKey())
      let prepared = try await fixture.preparer(sensor: sensor).prepare(
        package: fixture.package, rawDirectory: fixture.raw)
      defer { try? prepared.remove() }
      let tree = try NativeHandoffFileTree(prepared.directory, protected: true, owner: geteuid())
      XCTAssertEqual(
        try tree.read("files/apple/mesacal-j700.bin", maximum: 1 << 20), sensor.calibration)
      XCTAssertEqual(try tree.read("files/apple/msrk-j700.bin", maximum: 1 << 20), sensor.rootKey)
      let manifest = try JSONDecoder().decode(
        NativeNeoPeripheralPreparer.Manifest.self,
        from: tree.read("manifest.json", maximum: 65536))
      XCTAssertEqual(manifest.files["apple/msrk-j700.bin"]?.role, "sensor")
      XCTAssertEqual(
        manifest.localInputs["sensorRootKey"],
        String(SHA256Digest(hashing: sensor.rootKey).rawValue.dropFirst(7)))
    }

    func testChangedRawInputsUnsafeLinksMissingLocalCalibrationOrPolicyNeverPublishASnapshot()
      async throws
    {
      for fault in ["raw-digest", "raw-link", "local", "policy", "identity"] {
        let fixture = try InputFixture()
        defer { fixture.remove() }
        let source = fixture.raw.appendingPathComponent("sunrise/" + NeoFirmwareConversions.wifiRAM)
        switch fault {
        case "raw-digest": try Data("changed".utf8).write(to: source)
        case "raw-link":
          try FileManager.default.removeItem(at: source)
          try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: fixture.package.payloadURL)
        case "policy":
          try Data("{\"os_list\":[{\"omarchy_target\":\"apple-silicon-full-os\"}]}".utf8).write(
            to: fixture.package.metadataURL)
          try fixture.rebindMetadata()
        case "identity": try Data("{}".utf8).write(to: fixture.package.identityURL)
        default: break
        }
        do {
          _ = try await fixture.preparer(missingLocal: fault == "local").prepare(
            package: fixture.package, rawDirectory: fixture.raw)
          XCTFail("Expected rejection: \(fault)")
        } catch {}
        XCTAssertTrue(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy {
            !$0.hasPrefix("neo-peripherals-")
          })
      }
    }

    private final class InputFixture: @unchecked Sendable {
      let value: Fixture
      let root: URL, raw: URL
      let package: ImportedEngineHandoffPackage
      init() throws {
        value = try JSONDecoder().decode(Fixture.self, from: NeoFirmwareFixture.data())
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        raw = root.appendingPathComponent("native-firmware/raw")
        let imported = root.appendingPathComponent("imported")
        for url in [root, raw, imported] {
          try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        package = ImportedEngineHandoffPackage(
          packageURL: imported, manifestURL: imported.appendingPathComponent("manifest.json"),
          requestURL: imported.appendingPathComponent("request.json"),
          identityURL: imported.appendingPathComponent("identity.json"),
          engineURL: imported.appendingPathComponent("engine.tar.gz"),
          metadataURL: imported.appendingPathComponent("metadata.json"),
          payloadURL: imported.appendingPathComponent("payload.zip"),
          bindingDigest: value.manifest.bindingDigest,
          planDigest: value.manifest.planDigest,
          deviceIdentifier: value.manifest.deviceIdentifier, storeIdentifier: "disk0")
        try Data(value.metadata.utf8).write(to: package.metadataURL)
        try value.payload.write(to: package.payloadURL)
        try rebindMetadata()
        for (name, bytes) in value.rawFiles {
          let url = raw.appendingPathComponent(name)
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          try bytes.write(to: url)
        }
      }
      func rebindMetadata() throws {
        try JSONSerialization.data(withJSONObject: [
          "metadata_digest": SHA256Digest(hashing: Data(contentsOf: package.metadataURL)).rawValue,
          "payload_digest": value.manifest.payloadDigest,
        ]).write(to: package.identityURL)
      }
      func preparer(
        address: Data? = nil, missingLocal: Bool = false, sensor: NativeSensorInputs? = nil
      ) -> NativeNeoPeripheralPreparer {
        let inventory = NativeNeoInputInventory(
          recipeSHA256: value.manifest.recipeSHA256,
          files: value.rawFiles.map { name, bytes in
            NativeNeoInputInventory.File(
              name: name, bytes: bytes.count,
              sha256: String(SHA256Digest(hashing: bytes).rawValue.dropFirst(7)))
          })
        let inputs = NativeNeoLocalInputs(
          factory: value.local["factory"]!, lsci: value.local["lsci"]!,
          address: address ?? value.local["address"]!, sensor: sensor)
        return NativeNeoPeripheralPreparer(
          owner: geteuid(), inventory: { inventory },
          localInputs: { _ in
            if missingLocal { throw NativePeripheralInputError.localInput }
            return inputs
          })
      }
      func remove() { try? FileManager.default.removeItem(at: root) }
    }
  }
#endif
