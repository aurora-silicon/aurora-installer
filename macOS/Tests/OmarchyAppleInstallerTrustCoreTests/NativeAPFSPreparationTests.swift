#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeAPFSPreparationTests: XCTestCase, @unchecked Sendable {
    func testFreeAndResizePathsUseFreshIdentitiesAndCheckpointBeforeContinuation() throws {
      for kind in ["free", "resize"] {
        let fixture = try InputFixture(kind: kind)
        defer { fixture.remove() }
        try fixture.prepare()
        let expected = kind == "resize" ? ["apfs", "addPartition"] : ["addPartition"]
        XCTAssertEqual(fixture.commands.map { $0[0] }, expected)
        if kind == "resize" {
          XCTAssertEqual(fixture.commands[0], ["apfs", "resizeContainer", "disk0s2",
            String(fixture.original.disk.snapshot.partitions[1].size - fixture.approved.lengthBytes)])
        }
        XCTAssertEqual(fixture.commands.last, ["addPartition", "disk0s2", "apfs", "Omarchy", String(fixture.firmware.stubBytes)])
        let transcript = try Data(contentsOf: fixture.journal)
        let validated = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
        XCTAssertEqual(validated.plan, fixture.approved)
        XCTAssertEqual(validated.checkpoints.map(\.identifier), ["apfs-target-prepared"])
        let evidence = try NativeAPFSTargetEvidence.read(Data(contentsOf: fixture.evidence))
        XCTAssertEqual(evidence.partitionIdentifier, "disk0s9")
        XCTAssertEqual(evidence.offsetBytes, fixture.approved.offsetBytes)
        XCTAssertEqual(evidence.sizeBytes, fixture.firmware.stubBytes)
        XCTAssertEqual(fixture.commands.count, fixture.intentChecks)
        let count = fixture.commands.count
        try fixture.prepare()
        XCTAssertEqual(fixture.commands.count, count, "A completed native APFS checkpoint must never replay commands")
      }
    }

    func testChangedMinimumOrLayoutStopsBeforeIntentAndCommands() throws {
      for fault in ["minimum", "partition", "identity-check", "source-owner"] {
        let fixture = try InputFixture(kind: "resize")
        defer { fixture.remove() }
        fixture.fault = fault
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertTrue(fixture.commands.isEmpty)
        let bytes = try Data(contentsOf: fixture.journal)
        XCTAssertTrue(bytes.isEmpty || NativeInstallAdmission.provesNoMutation(bytes))
      }
    }

    func testRecoveryIncompatibleLabelsAreRejectedBeforeIntent() throws {
      for label in [String(repeating: "a", count: 81), "Aurora/Linux", "Aurora\nLinux", "Aurora\u{7f}"] {
        let fixture = try InputFixture(kind: "free", label: label)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.prepare()) { XCTAssertEqual($0 as? NativeAPFSError, .invalidLabel) }
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertTrue(try NativeInstallAdmission.provesNoMutation(Data(contentsOf: fixture.journal)))
      }
    }

    func testCompletedTargetKeepsTheOriginalSourceOwnerProofAcrossAttempts() throws {
      let fixture = try InputFixture(kind: "free")
      defer { fixture.remove() }
      try fixture.prepare()
      let different = try NativeSourceBootstrap(systemUUID: fixture.sourceBootstrap.systemUUID,
        groupUUID: fixture.sourceBootstrap.groupUUID, ownerUUID: "00000000-0000-0000-0000-000000000104")
      XCTAssertThrowsError(try fixture.execution.prepareTarget(journal: fixture.journal,
        authorization: fixture.authorization, sourceBootstrap: different)) {
        XCTAssertEqual($0 as? NativeHandoffValidationError, .invalidOwner)
      }
      XCTAssertEqual(fixture.commands.count, 1)
    }

    func testSafeFreshMinimumChangesPreserveTheApprovedHeaderAndUseTheNewBound() throws {
      let fixture = try InputFixture(kind: "resize")
      defer { fixture.remove() }
      try fixture.transcript.write(to: fixture.journal)
      fixture.fault = "minimum-safe"
      try fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.journal).prefix(fixture.transcript.count), fixture.transcript)
      XCTAssertEqual(fixture.commands.count, 2)
    }

    func testChangedResizeResultTargetOrUnrelatedPartitionNeverGetsACheckpoint() throws {
      for fault in ["resize-rounding", "target-offset", "target-size", "target-label", "unrelated", "command-error"] {
        let fixture = try InputFixture(kind: fault == "resize-rounding" ? "resize" : "free")
        defer { fixture.remove() }
        fixture.fault = fault
        XCTAssertThrowsError(try fixture.prepare(), fault)
        let bytes = try Data(contentsOf: fixture.journal)
        XCTAssertFalse(NativeInstallAdmission.provesNoMutation(bytes))
        XCTAssertTrue(try AppleInstallerTrustCore().validateEngineTranscript(bytes).checkpoints.isEmpty)
        let count = fixture.commands.count
        fixture.fault = nil
        XCTAssertThrowsError(try fixture.prepare()) {
          XCTAssertEqual($0 as? NativeAPFSError, .ambiguousMutation)
        }
        XCTAssertEqual(fixture.commands.count, count, "An incomplete intent is ambiguous even if a plausible target exists")
      }
    }

    func testInterruptedInitialHeaderCanResumeButForeignBytesCannot() throws {
      for length in [0, 1, 50, 200] {
        let fixture = try InputFixture(kind: "free")
        defer { fixture.remove() }
        try fixture.transcript.prefix(length).write(to: fixture.journal)
        try fixture.prepare()
        XCTAssertEqual(fixture.commands.count, 1)
      }
      let fixture = try InputFixture(kind: "free")
      defer { fixture.remove() }
      try Data("foreign header".utf8).write(to: fixture.journal)
      XCTAssertThrowsError(try fixture.prepare())
      XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testEvidenceWithoutCheckpointIsAmbiguousAndChangedCompletedIdentityIsRefused() throws {
      let incomplete = try InputFixture(kind: "free")
      defer { incomplete.remove() }
      try incomplete.prepare()
      var records = try Data(contentsOf: incomplete.journal).split(separator: 10).map(Data.init)
      records.removeLast()
      try (records.reduce(into: Data()) { $0.append($1); $0.append(10) }).write(to: incomplete.journal)
      XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.evidence.path))
      XCTAssertThrowsError(try incomplete.prepare()) {
        XCTAssertEqual($0 as? NativeAPFSError, .ambiguousMutation)
      }
      XCTAssertEqual(incomplete.commands.count, 1)

      let completed = try InputFixture(kind: "free")
      defer { completed.remove() }
      try completed.prepare()
      let target = try XCTUnwrap(completed.snapshot.partitions.firstIndex { $0.identifier == "disk0s9" })
      completed.snapshot.partitions[target].size += 4096
      XCTAssertThrowsError(try completed.prepare()) {
        XCTAssertEqual($0 as? NativeAPFSError, .changedTarget)
      }
      XCTAssertEqual(completed.commands.count, 1)
    }

    func testSourceControlsAndRestoreArchiveMustBeAdmittedBeforeDiskWork() async throws {
      let fixture = try InputFixture(kind: "free")
      defer { fixture.remove() }
      let facts = NativeFirmwareSelection.Facts(deviceIdentifier: fixture.original.deviceIdentifier,
        hardware: fixture.original.hardware)
      let refused = NativeAPFSPreparer(owner: geteuid(), platform: fixture.platform,
        firmwareFacts: { facts }, admitRestore: { _ in throw NativeAPFSError.invalidPlan })
      do {
        _ = try await refused.preflight(fixture.package)
        XCTFail("Expected archive admission failure")
      } catch {}
      XCTAssertTrue(fixture.commands.isEmpty)
      XCTAssertTrue(try Data(contentsOf: fixture.journal).isEmpty)
      let accepted = NativeAPFSPreparer(owner: geteuid(), platform: fixture.platform,
        firmwareFacts: { facts }, admitRestore: { _ in })
      let preparedValue = try await accepted.preflight(fixture.package)
      let prepared = try XCTUnwrap(preparedValue)
      XCTAssertTrue(fixture.commands.isEmpty)
      try prepared.prepareTarget(journal: fixture.journal, authorization: fixture.authorization, sourceBootstrap: fixture.sourceBootstrap)
      XCTAssertEqual(fixture.commands.count, 1)
    }

    private final class InputFixture: @unchecked Sendable {
      let root: URL, journal: URL, evidence: URL
      let package: ImportedEngineHandoffPackage
      let original: NativeAPFSFacts
      let metadata: NativeInstallationMetadata
      let metadataBytes: Data
      let firmware: NativeFirmwareSelection
      let approved: ValidatedEnginePlan
      let transcript: Data
      let authorization: MachineOwnerAuthorization
      let sourceBootstrap: NativeSourceBootstrap
      var snapshot: RemovalSnapshot
      var fault: String?
      var commands = [[String]]()
      var intentChecks = 0

      init(kind: String, label: String = "Omarchy") throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "native-inspection-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let vector = (document["vectors"] as! [[String: Any]])[0]
        func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
          try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
        }
        let disk = NativeCollectedDisk(snapshot: try decode(RemovalSnapshot.self, vector["snapshot"]!),
          containers: try decode([NativeContainerFacts].self, vector["containers"]!))
        original = NativeAPFSFacts(deviceIdentifier: vector["device"] as! String,
          hardware: try decode(NativeInspectionHardware.self, vector["hardware"]!), disk: disk)
        snapshot = disk.snapshot
        var metadataDocument = vector["metadata"] as! [String: Any]
        var templates = metadataDocument["os_list"] as! [[String: Any]]
        templates[0]["default_os_name"] = label
        metadataDocument["os_list"] = templates
        metadataBytes = try JSONSerialization.data(withJSONObject: metadataDocument, options: [.sortedKeys])
        metadata = try NativeInstallationMetadata(data: metadataBytes)
        firmware = try NativeFirmwareSelection.choose(deviceIdentifier: original.deviceIdentifier,
          facts: .init(deviceIdentifier: original.deviceIdentifier, hardware: original.hardware),
          metadata: metadata, policy: NativeInspectionPolicy.sealed())
        let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
          NativeDiskInventory.transcript(device: original.deviceIdentifier, snapshot: disk.snapshot,
            containers: disk.containers, metadata: metadata, stubBytes: firmware.stubBytes))
        let inventory = try XCTUnwrap(inspection.inventory)
        let candidate = try XCTUnwrap(inventory.candidates.first { $0.kind == kind })
        let identity = try PinnedAsahiPlanIdentity(engineVersion: "native-test",
          engineDigest: SHA256Digest(hashing: Data("engine".utf8)).rawValue,
          metadataDigest: SHA256Digest(hashing: metadataBytes).rawValue,
          payloadDigest: SHA256Digest(hashing: Data("payload".utf8)).rawValue)
        transcript = try NativeInstallerPlanner.transcript(inspection: inspection,
          request: PinnedAsahiPlanRequest(inventory: inventory, candidate: candidate,
            requestedLengthBytes: UInt64(kind == "resize" ? 40 : 80) << 30), identity: identity)
        approved = try XCTUnwrap(AppleInstallerTrustCore().validateEngineTranscript(transcript).plan)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imported = root.appendingPathComponent("imported")
        let journals = root.appendingPathComponent("execution-journals")
        for path in [root, imported, journals] {
          try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let binding = "sha256:" + String(repeating: "b", count: 64)
        journal = journals.appendingPathComponent(String(binding.dropFirst(7)) + ".jsonl")
        evidence = URL(fileURLWithPath: journal.path + ".apfs-target-prepared.evidence")
        package = ImportedEngineHandoffPackage(packageURL: imported, manifestURL: imported.appendingPathComponent("manifest.json"),
          requestURL: imported.appendingPathComponent("request.json"), identityURL: imported.appendingPathComponent("identity.json"),
          engineURL: imported.appendingPathComponent("engine.tar.gz"), metadataURL: imported.appendingPathComponent("metadata.json"),
          payloadURL: imported.appendingPathComponent("payload.zip"),
          restoreImageURL: imported.appendingPathComponent(RestoreImageHelper.fileName),
          bindingDigest: binding, planDigest: approved.planDigest, deviceIdentifier: approved.deviceIdentifier,
          storeIdentifier: approved.storeIdentifier)
        authorization = try MachineOwnerAuthorization(username: "mina", password: Data("synthetic-owner".utf8))
        sourceBootstrap = try NativeSourceBootstrap(systemUUID: "00000000-0000-0000-0000-000000000101",
          groupUUID: "00000000-0000-0000-0000-000000000102", ownerUUID: "00000000-0000-0000-0000-000000000103")
        try Data().write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        try controls()
      }

      var platform: NativeAPFSPlatform {
        NativeAPFSPlatform(collect: {
          if self.fault == "minimum" || self.fault == "minimum-safe" {
            let value = self.original.disk.containers[0]
            let changed = NativeContainerFacts(storeUUID: value.storeUUID, capacity: value.capacity,
              free: value.free, preferredMinimum: self.fault == "minimum" ? value.capacity
                : value.capacity - self.approved.lengthBytes - NativeInspectionMath.unit, systems: value.systems)
            return NativeAPFSFacts(deviceIdentifier: self.original.deviceIdentifier, hardware: self.original.hardware,
              disk: NativeCollectedDisk(snapshot: self.snapshot, containers: [changed]))
          }
          var snapshot = self.snapshot
          if self.fault == "partition" { snapshot.partitions[1].size += 4096 }
          return NativeAPFSFacts(deviceIdentifier: self.original.deviceIdentifier, hardware: self.original.hardware,
            disk: NativeCollectedDisk(snapshot: snapshot, containers: self.original.disk.containers))
        }, snapshot: { self.snapshot }, verifyPartition: { part, _ in
          if self.fault == "identity-check" || !self.snapshot.partitions.contains(where: { $0 == part && $0.identifier == part.identifier }) {
            throw NativeAPFSError.changedLayout
          }
        }, verifySourceOwner: { _, _, expected in
          guard self.fault != "source-owner", expected == self.sourceBootstrap else {
            throw NativeHandoffValidationError.invalidOwner
          }
        }, command: { arguments in
          XCTAssertTrue(String(decoding: try Data(contentsOf: self.journal), as: UTF8.self).contains("apfs_preparation_started"))
          self.intentChecks += 1
          self.commands.append(arguments)
          if self.fault == "command-error" { throw NativeAPFSError.changedLayout }
          if arguments[0] == "apfs" {
            self.snapshot.partitions[1].size = UInt64(arguments[3])! + (self.fault == "resize-rounding" ? 4096 : 0)
          } else {
            let id = "00000000-0000-0000-0000-000000000009"
            let part = RemovalPartition(identifier: "disk0s9", uuid: id, type: "Apple_APFS",
              offset: self.approved.offsetBytes + (self.fault == "target-offset" ? 4096 : 0),
              size: self.firmware.stubBytes + (self.fault == "target-size" ? 4096 : 0), name: "")
            self.snapshot.partitions.append(part)
            self.snapshot.partitions.sort { $0.offset < $1.offset }
            self.snapshot.containers.append(RemovalContainer(uuid: "00000000-0000-0000-0000-000000000123", storeUUID: id,
              volumes: [RemovalVolume(uuid: "00000000-0000-0000-0000-000000000456",
                name: self.fault == "target-label" ? "Other" : arguments[3], roles: [])]))
            if self.fault == "unrelated" { self.snapshot.partitions[0].size -= 4096 }
          }
        })
      }

      var execution: NativeAPFSExecution {
        NativeAPFSExecution(package: package, owner: geteuid(), approved: approved,
          metadata: metadata, firmware: firmware, platform: platform)
      }

      private func controls() throws {
        func record(_ name: String, _ data: Data) -> [String: Any] {
          ["file_name": name, "digest": SHA256Digest(hashing: data).rawValue, "size_bytes": data.count]
        }
        let engine = Data("engine".utf8), payload = Data("payload".utf8), decoder = Data("decoder".utf8)
        let manifest: [String: Any] = ["format": 1, "binding_digest": package.bindingDigest,
          "request_file": "request.json", "identity_file": "identity.json",
          "engine": record("engine.tar.gz", engine), "metadata": record("metadata.json", metadataBytes),
          "payload": record("payload.zip", payload), "restore_image": record(RestoreImageHelper.fileName, decoder)]
        let request: [String: Any] = ["format": 1, "operation": "install", "plan_digest": approved.planDigest,
          "device_identifier": approved.deviceIdentifier, "store_identifier": approved.storeIdentifier,
          "layout_digest": approved.layoutDigest, "candidate_kind": approved.candidateKind,
          "source_identifier": approved.sourceIdentifier, "offset_bytes": approved.offsetBytes,
          "length_bytes": approved.lengthBytes, "engine_version": approved.engineVersion,
          "required_human_steps": approved.requiredHumanSteps]
        let identity: [String: Any] = ["format": 1, "binding_digest": package.bindingDigest,
          "trust_root_fingerprint": "sha256:" + String(repeating: "a", count: 64), "catalog_sequence": 1,
          "catalog_payload_digest": "sha256:" + String(repeating: "a", count: 64), "plan_digest": approved.planDigest,
          "engine_digest": approved.engineDigest, "metadata_digest": approved.metadataDigest, "payload_digest": approved.payloadDigest]
        for (url, value) in [(package.manifestURL, manifest), (package.requestURL, request), (package.identityURL, identity)] {
          try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try metadataBytes.write(to: package.metadataURL)
      }
      func prepare() throws {
        try execution.prepareTarget(journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
      }
      func remove() { try? FileManager.default.removeItem(at: root) }
    }
  }
#endif
