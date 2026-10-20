#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeDiskDisplayGeometryTests: XCTestCase {
    private let unit: UInt64 = 1_048_576
    private let rootUUID = "11111111-1111-4111-8111-111111111111"

    private func snapshot() -> RemovalSnapshot {
      RemovalSnapshot(
        disk: "disk0", devicePath: "/dev/disk0", diskSize: 1_000_000 * unit,
        macOSStoreUUID: rootUUID,
        macOSContainerUUID: "22222222-2222-4222-8222-222222222222",
        partitions: [
          RemovalPartition(
            identifier: "disk0s2", uuid: rootUUID, type: "Apple_APFS",
            offset: 16 * unit, size: 500_000 * unit, name: "macOS"),
          RemovalPartition(
            identifier: "disk0s3", uuid: "33333333-3333-4333-8333-333333333333",
            type: "Apple_APFS", offset: 600_000 * unit, size: 100_000 * unit, name: "Work"),
          RemovalPartition(
            identifier: "disk0s4", uuid: "44444444-4444-4444-8444-444444444444",
            type: "Apple_APFS_Recovery", offset: 900_000 * unit, size: 10_000 * unit,
            name: "System Recovery"),
        ], containers: [])
    }

    func testPhysicalDiskIncludesEveryContainerSystemPartitionAndUsableGap() throws {
      let result = try NativeDiskDisplayGeometry(snapshot: snapshot())
      XCTAssertEqual(result.diskTotalBytes, 1_000_000 * unit)
      XCTAssertEqual(result.macOSStoreIdentifier, "disk0s2")
      XCTAssertEqual(result.macOSBytes, 500_000 * unit)
      XCTAssertEqual(result.unallocatedBytes, 389_984 * unit - 20_480)
      XCTAssertEqual(result.otherAllocatedBytes, 110_016 * unit + 20_480)
      XCTAssertEqual(result.partitionNames["disk0s3"], "Work")
      XCTAssertEqual(
        result.macOSBytes + result.otherAllocatedBytes + result.unallocatedBytes,
        result.diskTotalBytes)
    }

    func testAdditionalSharedAPFSVolumesDoNotDuplicatePhysicalCapacity() throws {
      var disk = snapshot()
      let before = try NativeDiskDisplayGeometry(snapshot: disk)
      disk.containers = [
        RemovalContainer(
          uuid: disk.macOSContainerUUID, storeUUID: rootUUID,
          volumes: [
            RemovalVolume(uuid: UUID().uuidString, name: "System", roles: ["System"]),
            RemovalVolume(uuid: UUID().uuidString, name: "Data", roles: ["Data"]),
            RemovalVolume(uuid: UUID().uuidString, name: "Extra data", roles: []),
            RemovalVolume(uuid: UUID().uuidString, name: "Preboot", roles: ["Preboot"]),
          ])
      ]
      XCTAssertEqual(try NativeDiskDisplayGeometry(snapshot: disk), before)
    }

    func testMissingRootOverlapsAndInconsistentTotalsCannotBeRenderedAsValidGeometry() throws {
      var missing = snapshot()
      missing.partitions.removeFirst()
      XCTAssertThrowsError(try NativeDiskDisplayGeometry(snapshot: missing))
      var overlap = snapshot()
      overlap.partitions[0].size = 700_000 * unit
      XCTAssertThrowsError(try NativeDiskDisplayGeometry(snapshot: overlap))
      XCTAssertThrowsError(
        try NativeDiskDisplayGeometry(
          diskTotalBytes: 100, macOSStoreIdentifier: "disk0s2", macOSBytes: 80,
          otherAllocatedBytes: 30, unallocatedBytes: 0))
      XCTAssertThrowsError(
        try NativeDiskDisplayGeometry(
          diskTotalBytes: 100, macOSStoreIdentifier: "disk0s2", macOSBytes: 80,
          otherAllocatedBytes: 10, unallocatedBytes: 9))
    }
  }
#endif
