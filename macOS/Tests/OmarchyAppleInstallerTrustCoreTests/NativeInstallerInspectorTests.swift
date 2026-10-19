#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeInstallerInspectorTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf:
              directory.appendingPathComponent("native-inspection-vectors.json"))) as! [String: Any]
      return try XCTUnwrap(document["vectors"] as? [[String: Any]])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
      try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func expected(_ vector: [String: Any]) throws -> ValidatedEngineTranscript {
      var bytes = Data()
      for (index, row) in [
        ("inspection", ["device_identifier": vector["device"]!, "support": "supported"]),
        ("inventory", vector["expectedInventory"]! as! [String: Any]),
      ].enumerated() {
        bytes.append(
          try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "sequence": index + 1, "type": row.0, "payload": row.1,
          ]))
        bytes.append(10)
      }
      return try AppleInstallerTrustCore().validateEngineTranscript(bytes)
    }

    func testAllGeometryAndFirmwareVectorsMatchTheAuthenticatedRuntime() throws {
      let cases = try vectors()
      XCTAssertEqual(cases.count, 16)
      let policy = try NativeInspectionPolicy.sealed()
      for vector in cases {
        let device = try XCTUnwrap(vector["device"] as? String)
        let metadata = try decode(NativeInstallationMetadata.self, vector["metadata"]!)
        let hardware = try decode(NativeInspectionHardware.self, vector["hardware"]!)
        let snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
        let containers = try decode([NativeContainerFacts].self, vector["containers"]!)
        let stub = try policy.stubBytes(device, hardware: hardware, metadata: metadata)
        XCTAssertEqual(
          stub, try XCTUnwrap(vector["stubBytes"] as? NSNumber).uint64Value,
          vector["name"] as? String ?? "case")
        let actual = try AppleInstallerTrustCore().validateEngineTranscript(
          NativeDiskInventory.transcript(
            device: device, snapshot: snapshot, containers: containers, metadata: metadata,
            stubBytes: stub))
        XCTAssertEqual(actual, try expected(vector), vector["name"] as? String ?? "case")
      }
    }

    private func first() throws -> (
      host: AppleSiliconHostInspection, hardware: NativeInspectionHardware,
      disk: NativeCollectedDisk, expected: ValidatedEngineTranscript
    ) {
      let vector = try XCTUnwrap(vectors().first)
      let snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
      let hardware = try decode(NativeInspectionHardware.self, vector["hardware"]!)
      let facts = try decode([NativeContainerFacts].self, vector["containers"]!)
      let host = AppleSiliconHostInspection(
        identity: AppleMacIdentity(
          model: "MacBookPro18,3",
          chip: "Apple M1 Pro", deviceIdentifier: "apple,j314s"),
        eligibility: .requiresSignedCatalog,
        macOSVersion: "26.6.2", powerSource: .ac, fileVaultEnabled: true,
        storage: APFSStorageInspection(
          containerIdentifier: "disk4", physicalStoreIdentifier: "disk0s2",
          isInternal: true, containerSizeBytes: facts[0].capacity,
          containerFreeBytes: facts[0].free,
          minimumPreferredSizeBytes: facts[0].preferredMinimum))
      return (
        host, hardware, NativeCollectedDisk(snapshot: snapshot, containers: facts),
        try expected(vector)
      )
    }

    func testNativeInspectorNeedsNoRuntimeArchiveOrExecutable() async throws {
      let value = try first()
      let inspector = NativeInstallerInspector(
        policy: { try NativeInspectionPolicy.sealed() },
        hardware: { value.hardware }, collect: { _ in value.disk })
      let result = try await inspector.inspect(host: value.host)
      XCTAssertEqual(result.validated, value.expected)
      XCTAssertTrue(result.knownInstallations.isEmpty)
    }

    func testKnownInstallationReportIsConnectedWithoutChangingLegacyInventory() async throws {
      let value = try first()
      let vector = try XCTUnwrap(vectors().first { $0["name"] as? String == "complete-install" })
      let snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
      let facts = try decode([NativeContainerFacts].self, vector["containers"]!)
      let disk = NativeCollectedDisk(snapshot: snapshot, containers: facts)
      let inspector = NativeInstallerInspector(policy: { try NativeInspectionPolicy.sealed() },
        hardware: { value.hardware }, collect: { _ in disk })
      let result = try await inspector.inspect(host: value.host)
      XCTAssertEqual(result.knownInstallations.map(\.sourceIdentifier), ["disk0s4"])
      let policy = try NativeInspectionPolicy.sealed()
      let metadata = policy.baselineMetadata
      let stub = try policy.stubBytes(value.host.identity.deviceIdentifier, hardware: value.hardware,
        metadata: metadata)
      XCTAssertEqual(result.transcript, try NativeDiskInventory.transcript(
        device: value.host.identity.deviceIdentifier, snapshot: snapshot, containers: facts,
        metadata: metadata, stubBytes: stub))
    }

    func testUnknownChipIsRefusedBeforeDiskCollection() async throws {
      let value = try first()
      let inspector = NativeInstallerInspector(
        policy: { try NativeInspectionPolicy.sealed() },
        hardware: {
          NativeInspectionHardware(
            chipID: 0xffff, bootVersion: nil,
            macOSVersion: nil, recoveryVersion: nil)
        },
        collect: { _ in
          throw NativeInspectionError.invalidLayout
        })
      let result = try await inspector.inspect(host: value.host)
      XCTAssertEqual(result.validated.support, .unsupported)
      XCTAssertNil(result.validated.inventory)
    }

    func testCancellationBeforeInspectionDoesNotStartCollection() async throws {
      let value = try first()
      let inspector = NativeInstallerInspector(
        policy: { try NativeInspectionPolicy.sealed() },
        hardware: { value.hardware }, collect: { _ in throw NativeInspectionError.invalidLayout })
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await inspector.inspect(host: value.host)
      }
      do {
        _ = try await task.value
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMalformedOrOverlappingGeometryIsRejected() throws {
      let vector = try XCTUnwrap(vectors().first)
      let snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
      let facts = try decode([NativeContainerFacts].self, vector["containers"]!)
      let metadata = try decode(NativeInstallationMetadata.self, vector["metadata"]!)
      for mode in 0..<3 {
        var invalid = snapshot
        if mode == 0 { invalid.partitions.append(invalid.partitions[0]) }
        if mode == 1 { invalid.partitions[1].size = UInt64.max }
        if mode == 2 { invalid.partitions[0].size = invalid.diskSize }
        XCTAssertThrowsError(
          try NativeDiskInventory.transcript(
            device: "apple,j314s", snapshot: invalid,
            containers: facts, metadata: metadata, stubBytes: 2_499_805_184))
      }
    }

    func testSelectedMetadataRequiresExactAuthenticatedBytes() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }
      let vector = try XCTUnwrap(vectors().first)
      let bytes = try JSONSerialization.data(withJSONObject: vector["metadata"]!)
      let file = directory.appendingPathComponent("metadata.json")
      try bytes.write(to: file)
      let artifact = try PinnedInstallerArtifact(
        role: "metadata", sourceURL: URL(string: "https://example.test/metadata.json")!,
        fileName: "metadata.json", expectedDigest: SHA256Digest(hashing: bytes).rawValue,
        expectedSizeBytes: UInt64(bytes.count))
      let staged = StagedInstallerArtifact(
        artifact: artifact, fileURL: file, reusedExistingFile: false)
      _ = try NativeInstallationMetadata.authenticated(staged)
      try (bytes + Data(" ".utf8)).write(to: file)
      XCTAssertThrowsError(try NativeInstallationMetadata.authenticated(staged))
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createSymbolicLink(
        at: file, withDestinationURL: directory.appendingPathComponent("missing"))
      XCTAssertThrowsError(try NativeInstallationMetadata.authenticated(staged))
    }

    func testNativeQueriesCannotReachPartitionOrBootMutations() {
      for arguments in [
        ["eraseDisk", "APFS", "X", "disk0"], ["apfs", "resizeContainer", "disk0s2", "1g"],
        ["mount", "disk0s2"], ["info", "-plist", "disk0\n"], ["info", "-plist", "--all"],
      ] {
        XCTAssertFalse(NativeInspectionCommands.permitted(arguments))
      }
      XCTAssertTrue(
        NativeInspectionCommands.permitted([
          "apfs", "resizeContainer", "disk0s2", "limits", "-plist",
        ]))
      XCTAssertTrue(NativeInspectionCommands.permitted(["info", "-plist", "disk4s1s1"]))
    }

    func testCancellationDuringMountOrReadStillUsesTheCleanupCommandChannel() throws {
      for duringMount in [false, true] {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        let mount = parent.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let recording = CleanupFixture(path: mount.path, duringMount: duringMount)
        var disks = MacRemovalDiskOperator()
        disks.commands = { try recording.normal($0) }
        disks.cleanupCommands = { try recording.cleanup($0) }
        disks.makeMountPoint = { mount }
        XCTAssertThrowsError(
          try disks.withVolume(
            "disk3s2", uuid: CleanupFixture.uuid,
            belongs: { _ in true }, read: { _ in true })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(
          recording.cleanupCalls,
          duringMount
            ? [["info", "-plist", "disk3s2"], ["unmount", "disk3s2"]] : [["unmount", "disk3s2"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mount.path))
      }
    }
  }

  private final class CleanupFixture: @unchecked Sendable {
    static let uuid = "00000000-0000-0000-0000-000000000002"
    private let lock = NSLock()
    private var infoCalls = 0
    private var cleanupArguments = [[String]]()
    let path: String
    let duringMount: Bool
    init(path: String, duringMount: Bool) {
      self.path = path
      self.duringMount = duringMount
    }
    var cleanupCalls: [[String]] { lock.withLock { cleanupArguments } }
    func normal(_ a: [String]) throws -> Data {
      try lock.withLock {
        if a.first == "mount" {
          if duringMount { throw CancellationError() }
          return Data()
        }
        if a == ["info", "-plist", "disk3s2"] {
          infoCalls += 1
          if infoCalls > 1 { throw CancellationError() }
          return try PropertyListSerialization.data(
            fromPropertyList: [
              "DeviceIdentifier": "disk3s2", "DiskUUID": Self.uuid, "MountPoint": "",
            ], format: .xml, options: 0)
        }
        throw NativeInspectionError.invalidLayout
      }
    }
    func cleanup(_ a: [String]) throws -> Data {
      lock.withLock { cleanupArguments.append(a) }
      if a == ["info", "-plist", "disk3s2"] {
        return try PropertyListSerialization.data(
          fromPropertyList: ["MountPoint": path], format: .xml, options: 0)
      }
      return Data()
    }
  }
#endif
