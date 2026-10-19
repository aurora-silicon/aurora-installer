#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeKnownInstallationsTests: XCTestCase {
    private func fixture(_ title: String = "Omarchy", stub: Bool = true,
      espLabel: String? = nil) throws -> NativeCollectedDisk {
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
        directory.appendingPathComponent("native-inspection-vectors.json"))) as? [String: Any])
      let vectors = try XCTUnwrap(document["vectors"] as? [[String: Any]])
      let vector = try XCTUnwrap(vectors.first { $0["name"] as? String == "complete-install" })
      var snapshot = try JSONDecoder().decode(RemovalSnapshot.self,
        from: JSONSerialization.data(withJSONObject: vector["snapshot"]!))
      snapshot.partitions = snapshot.partitions.map {
        guard $0.identifier == "disk0s5" else { return $0 }
        return RemovalPartition(identifier: $0.identifier, uuid: $0.uuid, type: $0.type,
          offset: $0.offset, size: $0.size,
          name: espLabel ?? NativeKnownInstallations.espLabel(for: title))
      }
      var facts = try JSONDecoder().decode([NativeContainerFacts].self,
        from: JSONSerialization.data(withJSONObject: vector["containers"]!))
      let previous = facts[1]
      facts[1] = NativeContainerFacts(storeUUID: previous.storeUUID, capacity: previous.capacity,
        free: previous.free, preferredMinimum: previous.preferredMinimum,
        systems: [NativeSystemVolumeFacts(group: previous.systems[0].group, label: title,
          stub: stub, version: previous.systems[0].version)])
      return NativeCollectedDisk(snapshot: snapshot, containers: facts)
    }

    func testEveryDistributionAndOmarchyIsRecognizedWithoutTheSelectedProfileOrSizeFloor() throws {
      for title in AuroraDistribution.allCases.map(\.title) + ["Omarchy"] {
        let disk = try fixture(title)
        var snapshot = disk.snapshot
        let rootIndex = try XCTUnwrap(snapshot.partitions.firstIndex { $0.identifier == "disk0s7" })
        snapshot.partitions[rootIndex].size = 1024 * 1024
        let result = try NativeKnownInstallations.recognize(NativeCollectedDisk(snapshot: snapshot, containers: disk.containers))
        XCTAssertEqual(result.count, 1, title)
        let stub = try XCTUnwrap(disk.snapshot.partitions.first { $0.identifier == "disk0s4" })
        let root = snapshot.partitions[rootIndex]
        XCTAssertEqual(result.first, NativeKnownInstallation(sourceIdentifier: "disk0s4",
          offsetBytes: stub.offset, lengthBytes: root.end - stub.offset))
        // Real bytes only: surrounding free space is never attributed to the install.
        XCTAssertLessThan(try XCTUnwrap(result.first).lengthBytes, 8 * 1024 * 1024 * 1024)
      }
      XCTAssertEqual(NativeKnownInstallations.espLabel(for: "Fedora Aurora Remix"), "EFI - FEDOR")
      XCTAssertEqual(NativeKnownInstallations.espLabel(for: "Aurora ALARM"), "EFI - AUROR")
      XCTAssertEqual(NativeKnownInstallations.espLabel(for: "Aurora NixOS"), "EFI - AUROR")
    }

    func testNormalMacOSUnrelatedLinuxAndIncompleteLayoutsDoNotMatch() throws {
      for disk in [try fixture("Macintosh HD"), try fixture("Fedora Aurora Remix", stub: false),
        try fixture("Aurora NixOS", espLabel: "UNRELATED")] {
        XCTAssertTrue(try NativeKnownInstallations.recognize(disk).isEmpty)
      }
      let incomplete = try fixture()
      var snapshot = incomplete.snapshot
      snapshot.partitions.removeAll { $0.identifier == "disk0s7" }
      XCTAssertTrue(try NativeKnownInstallations.recognize(NativeCollectedDisk(snapshot: snapshot, containers: incomplete.containers)).isEmpty)
    }

    func testMultipleInstallationsAndMultipleSystemGroupsAreNotLost() throws {
      let disk = try fixture("Fedora Aurora Remix")
      var snapshot = disk.snapshot
      let original = disk.snapshot.partitions.filter { ["disk0s4", "disk0s5", "disk0s6", "disk0s7"].contains($0.identifier) }
      // The retained vector has enough trailing free space for a smaller second install.
      let start: UInt64 = 230_000_000_000
      var cursor = start
      var second = [RemovalPartition]()
      for (index, part) in original.enumerated() {
        let size: UInt64 = index == 3 ? 1024 * 1024 : part.size
        second.append(RemovalPartition(identifier: "disk0s\(8 + index)",
          uuid: UUID().uuidString, type: part.type, offset: cursor, size: size,
          name: index == 1 ? "EFI - AUROR" : part.name))
        cursor += size
      }
      snapshot.partitions += second
      let fact = disk.containers[1]
      let facts = disk.containers + [NativeContainerFacts(storeUUID: second[0].uuid,
        capacity: second[0].size, free: fact.free, preferredMinimum: fact.preferredMinimum,
        systems: [NativeSystemVolumeFacts(group: UUID().uuidString, label: "Aurora NixOS", stub: true, version: "26.6.2"),
          NativeSystemVolumeFacts(group: UUID().uuidString, label: "Aurora ALARM", stub: true, version: "26.6.2")])]
      let result = try NativeKnownInstallations.recognize(NativeCollectedDisk(snapshot: snapshot, containers: facts))
      XCTAssertEqual(result.map(\.sourceIdentifier), ["disk0s4", "disk0s8"])
    }

    func testInvalidGeometryAndAmbiguousContainerFactsFailClosed() throws {
      let disk = try fixture()
      XCTAssertThrowsError(try NativeKnownInstallations.recognize(NativeCollectedDisk(
        snapshot: disk.snapshot, containers: disk.containers + [disk.containers[1]])))
      var snapshot = disk.snapshot
      snapshot.partitions.append(snapshot.partitions[1])
      XCTAssertThrowsError(try NativeKnownInstallations.recognize(NativeCollectedDisk(
        snapshot: snapshot, containers: disk.containers)))
    }
  }
#endif
