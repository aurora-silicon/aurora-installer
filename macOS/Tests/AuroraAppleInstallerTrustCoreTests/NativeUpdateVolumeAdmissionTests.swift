#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeUpdateVolumeAdmissionTests: XCTestCase {
    private let stubStoreUUID = "00000000-0000-0000-0000-000000000009"
    private let macStoreUUID = "00000000-0000-0000-0000-000000000002"
    private let espUUID = "00000000-0000-0000-0000-000000000010"
    private let groupUUID = "00000000-0000-0000-0000-000000000900"

    private func stubVolumes(including extra: [RemovalVolume] = []) -> [RemovalVolume] {
      [
        RemovalVolume(
          uuid: "00000000-0000-0000-0000-000000000456", name: "Aurora - Data",
          roles: ["Data"], group: groupUUID, identifier: "disk8s1"),
        RemovalVolume(
          uuid: "00000000-0000-0000-0000-000000000457", name: "Aurora",
          roles: ["System"], group: groupUUID, identifier: "disk8s2"),
        RemovalVolume(
          uuid: "00000000-0000-0000-0000-000000000458", name: "Preboot",
          roles: ["Preboot"], identifier: "disk8s3"),
        RemovalVolume(
          uuid: "00000000-0000-0000-0000-000000000459", name: "Recovery",
          roles: ["Recovery"], identifier: "disk8s4"),
      ] + extra
    }

    private func snapshot(
      macVolumes: [RemovalVolume]? = nil, stubVolumes: [RemovalVolume]? = nil,
      espName: String = ""
    ) -> RemovalSnapshot {
      let mac =
        macVolumes ?? [
          RemovalVolume(
            uuid: "00000000-0000-0000-0000-000000000201", name: "Macintosh HD",
            roles: ["System"], group: "00000000-0000-0000-0000-000000000200", identifier: "disk3s1"),
          RemovalVolume(
            uuid: "00000000-0000-0000-0000-000000000202", name: "Data",
            roles: ["Data"], group: "00000000-0000-0000-0000-000000000200", identifier: "disk3s5"),
        ]
      let stub = stubVolumes ?? self.stubVolumes()
      return RemovalSnapshot(
        disk: "disk0", devicePath: "/dev/disk0", diskSize: 250_000_000_000,
        macOSStoreUUID: macStoreUUID, macOSContainerUUID: "00000000-0000-0000-0000-000000000102",
        partitions: [
          RemovalPartition(
            identifier: "disk0s2", uuid: macStoreUUID, type: "Apple_APFS",
            offset: 1_000_000_000, size: 100_000_000_000, name: ""),
          RemovalPartition(
            identifier: "disk0s3", uuid: stubStoreUUID, type: "Apple_APFS",
            offset: 101_000_000_000, size: 6_000_000_000, name: ""),
          RemovalPartition(
            identifier: "disk0s4", uuid: espUUID, type: "EFI",
            offset: 107_000_000_000, size: 524_288_000, name: espName),
        ],
        containers: [
          RemovalContainer(
            uuid: "00000000-0000-0000-0000-000000000102", storeUUID: macStoreUUID, volumes: mac),
          RemovalContainer(
            uuid: "00000000-0000-0000-0000-000000000123", storeUUID: stubStoreUUID, volumes: stub),
        ])
    }

    func testAdmitsSingleLateUngroupedUpdateVolumeInStartupContainerAndRefusesOtherChanges() {
      let update = RemovalVolume(
        uuid: "00000000-0000-0000-0000-000000000470", name: "Update",
        roles: ["Update"], identifier: "disk8s5")
      let secondUpdate = RemovalVolume(
        uuid: "00000000-0000-0000-0000-000000000471", name: "Update",
        roles: ["Update"], identifier: "disk8s6")
      let groupedUpdate = RemovalVolume(
        uuid: "00000000-0000-0000-0000-000000000472", name: "Update",
        roles: ["Update"], group: groupUUID, identifier: "disk8s5")
      let badUUIDUpdate = RemovalVolume(
        uuid: "00000000-0000-0000-0000-00000000047a", name: "Update",
        roles: ["Update"], identifier: "disk8s5")
      let unrelated = RemovalVolume(
        uuid: "00000000-0000-0000-0000-000000000473", name: "VM",
        roles: ["VM"], identifier: "disk8s5")

      let recorded = snapshot()
      XCTAssertTrue(
        NativeUpdateVolumeAdmission.matches(
          recorded, recorded: recorded, stubStoreUUID: stubStoreUUID))
      let withUpdate = snapshot(stubVolumes: stubVolumes(including: [update]))
      XCTAssertTrue(
        NativeUpdateVolumeAdmission.matches(
          withUpdate, recorded: recorded, stubStoreUUID: stubStoreUUID))
      // Order of recorded volumes is preserved even when the Update volume sits first.
      let withPrependedUpdate = snapshot(stubVolumes: [update] + stubVolumes())
      XCTAssertTrue(
        NativeUpdateVolumeAdmission.matches(
          withPrependedUpdate, recorded: recorded, stubStoreUUID: stubStoreUUID))

      // Refusals: second Update, two new Updates, grouped Update, non-canonical UUID, unrelated role.
      let withTwoUpdates = snapshot(stubVolumes: stubVolumes(including: [update, secondUpdate]))
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          withTwoUpdates, recorded: recorded, stubStoreUUID: stubStoreUUID))
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          withTwoUpdates, recorded: withUpdate, stubStoreUUID: stubStoreUUID))
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          snapshot(stubVolumes: stubVolumes(including: [groupedUpdate])), recorded: recorded,
          stubStoreUUID: stubStoreUUID))
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          snapshot(stubVolumes: stubVolumes(including: [badUUIDUpdate])), recorded: recorded,
          stubStoreUUID: stubStoreUUID))
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          snapshot(stubVolumes: stubVolumes(including: [unrelated])), recorded: recorded,
          stubStoreUUID: stubStoreUUID))

      // Refusal: Update volume added to a different container.
      let macUpdate = RemovalVolume(
        uuid: "00000000-0000-0000-0000-000000000299", name: "Update",
        roles: ["Update"], identifier: "disk3s6")
      let inMacOS = snapshot(
        macVolumes: recorded.containers[0].volumes + [macUpdate])
      XCTAssertFalse(
        NativeUpdateVolumeAdmission.matches(
          inMacOS, recorded: recorded, stubStoreUUID: stubStoreUUID))

      // Combined with FAT label discovery on the ESP.
      let labeledAndUpdated = snapshot(
        stubVolumes: stubVolumes(including: [update]), espName: "EFI - FEDOR")
      XCTAssertTrue(
        NativeESPLabelAdmission.matches(
          labeledAndUpdated, recorded: recorded, espUUID: espUUID, label: "EFI - Fedor",
          stubStoreUUID: stubStoreUUID))
      let labeledAndUnrelated = snapshot(
        stubVolumes: stubVolumes(including: [unrelated]), espName: "EFI - FEDOR")
      XCTAssertFalse(
        NativeESPLabelAdmission.matches(
          labeledAndUnrelated, recorded: recorded, espUUID: espUUID, label: "EFI - Fedor",
          stubStoreUUID: stubStoreUUID))
    }
  }
#endif
