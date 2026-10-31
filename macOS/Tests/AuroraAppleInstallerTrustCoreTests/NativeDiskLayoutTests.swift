#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeDiskLayoutTests: XCTestCase {
    private func vectorDisk() throws -> NativeCollectedDisk {
      let file = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-inspection-vectors", withExtension: "json",
          subdirectory: "Fixtures"))
      let document =
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
      let vector = (document["vectors"] as! [[String: Any]])[0]
      func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
      }
      var snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
      // The vector names macOS's container only by UUID; removal recognition
      // also reads its volumes.
      snapshot.containers.append(
        RemovalContainer(
          uuid: snapshot.macOSContainerUUID, storeUUID: snapshot.macOSStoreUUID,
          volumes: [
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-0000000000C1", name: "Macintosh HD",
              roles: ["System"], group: "00000000-0000-0000-0000-0000000000CA",
              identifier: "disk3s1")
          ]))
      return NativeCollectedDisk(
        snapshot: snapshot,
        containers: try decode([NativeContainerFacts].self, vector["containers"]!))
    }

    /// Adds a startup container, EFI and two Linux partitions ending at `end`.
    private func adding(
      _ title: String, espName: String, ending end: UInt64, number: Int,
      to disk: NativeCollectedDisk
    ) -> NativeCollectedDisk {
      var snapshot = disk.snapshot
      let sizes: [UInt64] = [2_499_805_184, 524_288_000, 1 << 30, 4 << 30]
      var offset = end - sizes.reduce(0, +)
      let types = ["Apple_APFS", "EFI", "Linux Filesystem", "Linux Filesystem"]
      let names = ["", espName, "", ""]
      for index in sizes.indices {
        snapshot.partitions.append(
          RemovalPartition(
            identifier: "disk0s\(number + index)",
            uuid: "00000000-0000-0000-0000-000000000\(number)\(index)0", type: types[index],
            offset: offset, size: sizes[index], name: names[index]))
        offset += sizes[index]
      }
      snapshot.partitions.sort { $0.offset < $1.offset }
      let store = "00000000-0000-0000-0000-000000000\(number)00"
      let group = "00000000-0000-0000-0000-000000000\(number)90"
      snapshot.containers.append(
        RemovalContainer(
          uuid: "00000000-0000-0000-0000-000000000\(number)80", storeUUID: store,
          volumes: [
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-000000000\(number)81", name: title,
              roles: ["System"], group: group, identifier: "disk\(number)s1"),
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-000000000\(number)82", name: title + " - Data",
              roles: ["Data"], group: group, identifier: "disk\(number)s2"),
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-000000000\(number)83", name: "Preboot",
              roles: ["Preboot"], identifier: "disk\(number)s3"),
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-000000000\(number)84", name: "Recovery",
              roles: ["Recovery"], identifier: "disk\(number)s4"),
          ]))
      let facts = NativeContainerFacts(
        storeUUID: store, capacity: sizes[0], free: 500_000_000, preferredMinimum: 0,
        systems: [NativeSystemVolumeFacts(group: group, label: title, stub: true, version: "26.6")])
      return NativeCollectedDisk(snapshot: snapshot, containers: disk.containers + [facts])
    }

    func testOneInstallationIsDescribedInDiskOrderAndIsWhatRemovalWouldErase() throws {
      let base = try vectorDisk()
      let recovery = try XCTUnwrap(
        base.snapshot.partitions.first { $0.type == "Apple_APFS_Recovery" })
      let disk = adding(
        "Aurora Alarm", espName: "EFI - AUROR", ending: recovery.offset, number: 4, to: base)
      let layout = try NativeDiskLayout(disk)
      XCTAssertEqual(
        layout.regions.map(\.kind), [.appleSystem, .macOS, .free, .linux, .appleSystem])
      let macOS = layout.regions[1]
      XCTAssertEqual(macOS.name, "Macintosh HD")
      XCTAssertTrue(macOS.isRunningMacOS)
      XCTAssertEqual(macOS.freeBytes, 107_374_182_400)
      XCTAssertEqual(macOS.systemVolumeUUID, "00000000-0000-0000-0000-0000000000C1")
      let linux = layout.regions[3]
      XCTAssertEqual(linux.name, "Aurora Alarm")
      XCTAssertTrue(linux.recognized)
      XCTAssertEqual(linux.identifier, "disk0s4")
      XCTAssertEqual(linux.endBytes, recovery.offset)
      XCTAssertEqual(linux.systemVolumeUUID, "00000000-0000-0000-0000-000000000481")
      // The removal service's own recognition targets exactly this row.
      XCTAssertEqual(layout.removableStartupContainerUUID, linux.uuid)
      XCTAssertEqual(layout.regions[2].offsetBytes, macOS.endBytes)
      XCTAssertEqual(layout.regions[2].endBytes, linux.offsetBytes)
    }

    func testAnotherInstallersLinuxIsUnrecognizedAndSeveralInstallationsAreNotErasable()
      throws
    {
      let base = try vectorDisk()
      let recovery = try XCTUnwrap(
        base.snapshot.partitions.first { $0.type == "Apple_APFS_Recovery" })
      var disk = adding(
        "Fedora Linux with KDE Plasma", espName: "EFI - FEDOR", ending: recovery.offset,
        number: 8, to: base)
      disk = adding(
        "Aurora Fedora Remix", espName: "EFI - AUROR", ending: recovery.offset - 9_000_000_000,
        number: 4, to: disk)
      let layout = try NativeDiskLayout(disk)
      XCTAssertEqual(
        layout.regions.map(\.kind),
        [.appleSystem, .macOS, .free, .linux, .free, .linux, .appleSystem])
      XCTAssertEqual(layout.regions[3].name, "Aurora Fedora Remix")
      XCTAssertTrue(layout.regions[3].recognized)
      XCTAssertEqual(layout.regions[5].name, "Fedora Linux with KDE Plasma")
      XCTAssertFalse(layout.regions[5].recognized)
      // Its EFI and Linux partitions belong to its row, not to "other".
      XCTAssertEqual(layout.regions[5].endBytes, recovery.offset)
      XCTAssertNil(layout.removableStartupContainerUUID)
    }
  }
#endif
