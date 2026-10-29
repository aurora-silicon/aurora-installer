#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativePreservedInstallTargetTests: XCTestCase {
    private func fixture(title: String = AuroraDistribution.nixos.title) throws
      -> NativeCollectedDisk
    {
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(
            contentsOf: directory.appendingPathComponent("native-inspection-vectors.json")))
          as? [String: Any])
      let vectors = try XCTUnwrap(document["vectors"] as? [[String: Any]])
      let vector = try XCTUnwrap(vectors.first { $0["name"] as? String == "complete-install" })
      var snapshot = try JSONDecoder().decode(
        RemovalSnapshot.self,
        from: JSONSerialization.data(withJSONObject: vector["snapshot"]!))
      var facts = try JSONDecoder().decode(
        [NativeContainerFacts].self,
        from: JSONSerialization.data(withJSONObject: vector["containers"]!))
      snapshot.partitions = snapshot.partitions.map { part in
        guard part.identifier == "disk0s5" else { return part }
        return RemovalPartition(
          identifier: part.identifier, uuid: part.uuid, type: part.type,
          offset: part.offset, size: part.size,
          name: NativeKnownInstallations.espLabel(for: title))
      }
      let previous = facts[1]
      let group = previous.systems[0].group
      facts[1] = NativeContainerFacts(
        storeUUID: previous.storeUUID, capacity: previous.capacity,
        free: previous.free, preferredMinimum: previous.preferredMinimum,
        systems: [
          NativeSystemVolumeFacts(group: group, label: title, stub: true, version: "26.6.2")
        ])
      snapshot.containers = [
        RemovalContainer(
          uuid: UUID().uuidString, storeUUID: previous.storeUUID,
          volumes: [
            RemovalVolume(
              uuid: UUID().uuidString, name: title, roles: ["System"], group: group,
              identifier: "disk8s1"),
            RemovalVolume(
              uuid: UUID().uuidString, name: title + " Data", roles: ["Data"], group: group,
              identifier: "disk8s2"),
            RemovalVolume(
              uuid: UUID().uuidString, name: "Preboot", roles: ["Preboot"],
              identifier: "disk8s3"),
            RemovalVolume(
              uuid: UUID().uuidString, name: "Recovery", roles: ["Recovery"],
              identifier: "disk8s4"),
          ])
      ]
      return NativeCollectedDisk(snapshot: snapshot, containers: facts)
    }

    func testAdmitsExistingAuroraLayoutWithoutChangingItsStageOneIdentity() throws {
      let disk = try fixture()
      let target = try NativePreservedInstallTarget.admit(
        disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
        bootImageBytes: 1 << 30, rootImageBytes: 24 << 30)
      XCTAssertEqual(target.stub.identifier, "disk0s4")
      XCTAssertEqual(target.esp.identifier, "disk0s5")
      XCTAssertEqual(target.boot.identifier, "disk0s6")
      XCTAssertEqual(target.root.identifier, "disk0s7")
      XCTAssertEqual(target.group, disk.containers[1].systems[0].group)
      XCTAssertNotNil(SHA256Digest(rawValue: target.identityDigest))
      XCTAssertEqual(
        target.identityDigest,
        try NativePreservedInstallTarget.admit(
          disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: 4096, rootImageBytes: 4096
        ).identityDigest)
      var changed = disk.snapshot
      let container = try XCTUnwrap(changed.containers.first)
      changed.containers = [
        RemovalContainer(
          uuid: container.uuid, storeUUID: container.storeUUID,
          volumes: container.volumes.map { volume in
            guard volume.roles == ["System"] else { return volume }
            return RemovalVolume(
              uuid: UUID().uuidString, name: volume.name, roles: volume.roles,
              group: volume.group, identifier: volume.identifier)
          })
      ]
      let changedTarget = try NativePreservedInstallTarget.admit(
        NativeCollectedDisk(snapshot: changed, containers: disk.containers),
        sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
        bootImageBytes: 4096, rootImageBytes: 4096)
      XCTAssertNotEqual(target.identityDigest, changedTarget.identityDigest)
    }

    func testOmarchyLayoutOffersCrossDistributionResetButUnknownStubDoesNot() throws {
      let disk = try fixture(title: "Omarchy")
      let target = try NativePreservedInstallTarget.recognize(
        disk, sourceIdentifier: "disk0s4", title: "Omarchy")
      XCTAssertEqual(target.title, "Omarchy")
      XCTAssertEqual(target.esp.name, "EFI - OMARC")
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(
            contentsOf: directory.appendingPathComponent("native-inspection-vectors.json")))
          as? [String: Any])
      let vectors = try XCTUnwrap(document["vectors"] as? [[String: Any]])
      let vector = try XCTUnwrap(vectors.first { $0["name"] as? String == "complete-install" })
      var metadata = try XCTUnwrap(vector["metadata"] as? [String: Any])
      var templates = try XCTUnwrap(metadata["os_list"] as? [[String: Any]])
      templates[0]["default_os_name"] = AuroraDistribution.arch.title
      metadata["os_list"] = templates
      let inspected = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: disk.snapshot, containers: disk.containers,
          metadata: try NativeInstallationMetadata(
            data: JSONSerialization.data(withJSONObject: metadata)),
          stubBytes: 2_499_805_184))
      let candidate = try XCTUnwrap(
        inspected.inventory?.candidates.first { $0.kind == "reinstall" })
      XCTAssertEqual(candidate.sourceIdentifier, target.stub.identifier)
      XCTAssertEqual(candidate.identityDigest, target.identityDigest)
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.recognize(
          try fixture(title: "Unknown Linux"), sourceIdentifier: "disk0s4"))
    }

    func testRejectsChangedLayoutWrongProfileAndOversizedImageBeforeWrite() throws {
      let disk = try fixture()
      let boot = try XCTUnwrap(
        disk.snapshot.partitions.first { $0.identifier == "disk0s6" })
      let root = try XCTUnwrap(
        disk.snapshot.partitions.first { $0.identifier == "disk0s7" })
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.admit(
          disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.fedora.title,
          bootImageBytes: 4096, rootImageBytes: 4096))
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.admit(
          disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: boot.size + 4096, rootImageBytes: 4096))
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.admit(
          disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: 4096, rootImageBytes: root.size + 4096))
      var changed = disk.snapshot
      let index = try XCTUnwrap(
        changed.partitions.firstIndex { $0.identifier == "disk0s6" })
      changed.partitions[index].size -= 4096
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.admit(
          NativeCollectedDisk(snapshot: changed, containers: disk.containers),
          sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: 4096, rootImageBytes: 4096))
      var duplicate = disk.snapshot
      duplicate.containers.append(duplicate.containers[0])
      XCTAssertThrowsError(
        try NativePreservedInstallTarget.admit(
          NativeCollectedDisk(snapshot: duplicate, containers: disk.containers),
          sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: 4096, rootImageBytes: 4096))
    }

    func testPreservedCandidateProducesAPlanWithoutRecoveryEnrollment() throws {
      let disk = try fixture()
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(
            contentsOf: directory.appendingPathComponent("native-inspection-vectors.json")))
          as? [String: Any])
      let vectors = try XCTUnwrap(document["vectors"] as? [[String: Any]])
      let vector = try XCTUnwrap(vectors.first { $0["name"] as? String == "complete-install" })
      var metadata = try XCTUnwrap(vector["metadata"] as? [String: Any])
      var templates = try XCTUnwrap(metadata["os_list"] as? [[String: Any]])
      templates[0]["default_os_name"] = AuroraDistribution.nixos.title
      metadata["os_list"] = templates
      let bytes = try JSONSerialization.data(withJSONObject: metadata)
      let inspected = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: disk.snapshot, containers: disk.containers,
          metadata: try NativeInstallationMetadata(data: bytes), stubBytes: 2_499_805_184))
      let inventory = try XCTUnwrap(inspected.inventory)
      let candidate = try XCTUnwrap(
        inventory.candidates.first { $0.kind == "reinstall" })
      let target = try NativePreservedInstallTarget.recognize(
        disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title)
      XCTAssertEqual(candidate.sourceIdentifier, target.stub.identifier)
      XCTAssertEqual(candidate.identityDigest, target.identityDigest)
      XCTAssertEqual(candidate.minimumInstallBytes, candidate.lengthBytes)
      templates[0]["default_os_name"] = AuroraDistribution.arch.title
      metadata["os_list"] = templates
      let switchedMetadata = try JSONSerialization.data(withJSONObject: metadata)
      let switchedInspection = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: disk.snapshot, containers: disk.containers,
          metadata: try NativeInstallationMetadata(data: switchedMetadata),
          stubBytes: 2_499_805_184))
      let switched = try XCTUnwrap(
        switchedInspection.inventory?.candidates.first { $0.kind == "reinstall" })
      XCTAssertEqual(switched.identityDigest, target.identityDigest)
      XCTAssertThrowsError(
        try PinnedAsahiPlanRequest(
          inventory: inventory, candidate: candidate,
          requestedLengthBytes: candidate.lengthBytes - PinnedAsahiPlanRequest.allocationUnitBytes))
      let request = try PinnedAsahiPlanRequest(
        inventory: inventory, candidate: candidate,
        requestedLengthBytes: candidate.lengthBytes)
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: "test", engineDigest: "sha256:" + String(repeating: "a", count: 64),
        metadataDigest: "sha256:" + String(repeating: "b", count: 64),
        payloadDigest: "sha256:" + String(repeating: "c", count: 64))
      let planned = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeInstallerPlanner.transcript(
          inspection: inspected, request: request, identity: identity))
      XCTAssertEqual(planned.plan?.candidateKind, "reinstall")
      XCTAssertEqual(planned.plan?.requiredHumanSteps, ["authenticateMachineOwner"])
      var unbound = disk.snapshot
      unbound.containers.removeAll()
      let unboundInspection = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: unbound, containers: disk.containers,
          metadata: try NativeInstallationMetadata(data: bytes), stubBytes: 2_499_805_184))
      XCTAssertFalse(
        try XCTUnwrap(unboundInspection.inventory).candidates.contains {
          $0.kind == "reinstall"
        })
    }

    func testAuthenticatedPreflightBindsCurrentLayoutImagesAndUnchangedStageOne() async throws {
      let disk = try fixture()
      let (baseMetadata, payload, _) = try NativeESPFileTests.inputs()
      var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: baseMetadata) as? [String: Any])
      var templates = try XCTUnwrap(document["os_list"] as? [[String: Any]])
      templates[0]["default_os_name"] = AuroraDistribution.nixos.title
      document["os_list"] = templates
      let metadata = try JSONSerialization.data(withJSONObject: document)
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: disk.snapshot, containers: disk.containers,
          metadata: try NativeInstallationMetadata(data: metadata), stubBytes: 2_499_805_184))
      let inventory = try XCTUnwrap(inspection.inventory)
      let candidate = try XCTUnwrap(inventory.candidates.first { $0.kind == "reinstall" })
      let request = try PinnedAsahiPlanRequest(
        inventory: inventory, candidate: candidate,
        requestedLengthBytes: candidate.lengthBytes)
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: "test", engineDigest: "sha256:" + String(repeating: "a", count: 64),
        metadataDigest: SHA256Digest(hashing: metadata).rawValue,
        payloadDigest: SHA256Digest(hashing: payload).rawValue)
      let transcript = try NativeInstallerPlanner.transcript(
        inspection: inspection, request: request, identity: identity)
      let approved = try XCTUnwrap(
        AppleInstallerTrustCore().validateEngineTranscript(transcript).plan)
      let target = try NativePreservedInstallTarget.recognize(
        disk, sourceIdentifier: candidate.sourceIdentifier, title: AuroraDistribution.nixos.title)
      let possibleESP = try await NativeESPPayloadPlan.make(
        metadata: metadata, archive: archive, device: "apple,j314s", firmware: "26.6.2",
        legacyStage1: { NativeESPFileTests.legacyBase })
      let esp = try XCTUnwrap(possibleESP)
      let installed = try NativeLegacyStage1.fill(
        esp.stage1, uuid: target.esp.uuid.lowercased(), path: "m1n1/boot.bin")
      let prepared = try await NativePreservedInstallAdmission.check(
        approved: approved, metadata: metadata, archive: archive, disk: disk,
        stubBytes: 2_499_805_184, firmwareVersion: "26.6.2",
        installedStage1: installed, legacyStage1: { NativeESPFileTests.legacyBase })
      XCTAssertEqual(prepared.target.identityDigest, target.identityDigest)
      XCTAssertEqual(prepared.transcript, transcript)
      XCTAssertEqual(prepared.boot.name, "boot.img")
      XCTAssertEqual(prepared.root.name, "root.img")
      XCTAssertEqual(prepared.stage1.sha256, NativeStubFileStore.hash(installed))
      XCTAssertNil(prepared.espVolumeID)

      var changed = installed
      changed[0] ^= 1
      do {
        _ = try await NativePreservedInstallAdmission.check(
          approved: approved, metadata: metadata, archive: archive, disk: disk,
          stubBytes: 2_499_805_184, firmwareVersion: "26.6.2",
          installedStage1: changed, legacyStage1: { NativeESPFileTests.legacyBase })
        XCTFail("Changed Stage 1 was admitted")
      } catch {}
    }

    func testPreflightCarriesTheESPVolumeIDAndKeepsASmallerExistingESP() async throws {
      let disk = try fixture()
      let (baseMetadata, payload, _) = try NativeESPFileTests.inputs()
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      func admit(_ volumeID: String, espSize: String = "8MiB") async throws
        -> NativePreservedInstallAdmission.Prepared
      {
        var document = try XCTUnwrap(
          JSONSerialization.jsonObject(with: baseMetadata) as? [String: Any])
        var templates = try XCTUnwrap(document["os_list"] as? [[String: Any]])
        var rows = try XCTUnwrap(templates[0]["partitions"] as? [[String: Any]])
        rows[0]["volume_id"] = volumeID
        rows[0]["size"] = espSize
        templates[0]["partitions"] = rows
        templates[0]["default_os_name"] = AuroraDistribution.nixos.title
        document["os_list"] = templates
        let metadata = try JSONSerialization.data(withJSONObject: document)
        let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
          NativeDiskInventory.transcript(
            device: "apple,j314s", snapshot: disk.snapshot, containers: disk.containers,
            metadata: try NativeInstallationMetadata(data: metadata), stubBytes: 2_499_805_184))
        let inventory = try XCTUnwrap(inspection.inventory)
        let candidate = try XCTUnwrap(inventory.candidates.first { $0.kind == "reinstall" })
        let transcript = try NativeInstallerPlanner.transcript(
          inspection: inspection,
          request: PinnedAsahiPlanRequest(
            inventory: inventory, candidate: candidate,
            requestedLengthBytes: candidate.lengthBytes),
          identity: PinnedAsahiPlanIdentity(
            engineVersion: "test", engineDigest: "sha256:" + String(repeating: "a", count: 64),
            metadataDigest: SHA256Digest(hashing: metadata).rawValue,
            payloadDigest: SHA256Digest(hashing: payload).rawValue))
        let approved = try XCTUnwrap(
          AppleInstallerTrustCore().validateEngineTranscript(transcript).plan)
        let target = try NativePreservedInstallTarget.recognize(
          disk, sourceIdentifier: candidate.sourceIdentifier,
          title: AuroraDistribution.nixos.title)
        let possibleESP = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive, device: "apple,j314s", firmware: "26.6.2",
          legacyStage1: { NativeESPFileTests.legacyBase })
        let installed = try NativeLegacyStage1.fill(
          XCTUnwrap(possibleESP).stage1, uuid: target.esp.uuid.lowercased(),
          path: "m1n1/boot.bin")
        return try await NativePreservedInstallAdmission.check(
          approved: approved, metadata: metadata, archive: archive, disk: disk,
          stubBytes: 2_499_805_184, firmwareVersion: "26.6.2",
          installedStage1: installed, legacyStage1: { NativeESPFileTests.legacyBase })
      }
      let fedora = try await admit("0x4866d833")
      XCTAssertEqual(fedora.espVolumeID, 0x4866_D833)
      let legacy = try await admit("0X4F4D5801")
      XCTAssertEqual(legacy.espVolumeID, 0x4F4D_5801)
      // A reset keeps the existing 512 MiB ESP even when the image's ESP is
      // larger; its free space is checked before the first write instead.
      let larger = try await admit("0x4866d833", espSize: "1GiB")
      XCTAssertLessThan(larger.target.esp.size, 1 << 30)
      XCTAssertEqual(larger.espVolumeID, 0x4866_D833)
      do {
        _ = try await admit("4866D833")
        XCTFail("A volume ID a fresh install couldn't format was admitted")
      } catch {
        XCTAssertEqual(error as? NativePreservedInstallError, .unavailable)
      }
    }
  }
#endif
