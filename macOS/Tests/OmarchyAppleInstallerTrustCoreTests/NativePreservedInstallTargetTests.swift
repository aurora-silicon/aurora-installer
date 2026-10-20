#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedInstallTargetTests: XCTestCase {
    private func fixture() throws -> NativeCollectedDisk {
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
      let title = AuroraDistribution.nixos.title
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
      XCTAssertEqual(target.identityDigest.count, 64)
      XCTAssertEqual(
        target.identityDigest,
        try NativePreservedInstallTarget.admit(
          disk, sourceIdentifier: "disk0s4", title: AuroraDistribution.nixos.title,
          bootImageBytes: 4096, rootImageBytes: 4096).identityDigest)
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
  }
#endif
