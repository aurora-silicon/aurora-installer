#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeInstallerDryRunTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    private func machine(device: String, chip: UInt64, macOS: String, boot: String) throws -> Data {
      let isc = "00000000-0000-4000-8000-000000000001"
      let store = "00000000-0000-4000-8000-000000000002"
      let container = "00000000-0000-4000-8000-000000000003"
      let group = "00000000-0000-4000-8000-000000000004"
      let macOSEnd: UInt64 = 524_312_576 + 200 * gib
      let document: [String: Any] = [
        "deviceIdentifier": device,
        "hardware": [
          "chipID": chip, "bootVersion": boot, "macOSVersion": macOS,
          "recoveryVersion": "25.7.83.0.0,0",
        ],
        "snapshot": [
          "disk": "disk0", "devicePath": "/dev/disk0", "diskSize": 500 * gib,
          "macOSStoreUUID": store, "macOSContainerUUID": container,
          "partitions": [
            [
              "identifier": "disk0s1", "uuid": isc, "type": "Apple_APFS_ISC", "offset": 24576,
              "size": 524_288_000, "name": "",
            ],
            [
              "identifier": "disk0s2", "uuid": store, "type": "Apple_APFS",
              "offset": 524_312_576, "size": macOSEnd - 524_312_576, "name": "",
            ],
          ],
          "containers": [
            [
              "uuid": container, "storeUUID": store,
              "volumes": [
                [
                  "uuid": "00000000-0000-4000-8000-000000000005", "name": "Macintosh HD",
                  "roles": ["System"], "group": group, "identifier": "disk3s1",
                ],
                [
                  "uuid": "00000000-0000-4000-8000-000000000006", "name": "Data",
                  "roles": ["Data"], "group": group, "identifier": "disk3s2",
                ],
              ],
            ]
          ],
        ],
        "containers": [
          [
            "storeUUID": store, "capacity": macOSEnd - 524_312_576, "free": 100 * gib,
            "preferredMinimum": 100 * gib,
            "systems": [
              ["group": group, "label": "Macintosh HD", "stub": false, "version": macOS]
            ],
          ]
        ],
      ]
      return try JSONSerialization.data(withJSONObject: document)
    }

    private func metadata() throws -> Data {
      let template: [String: Any] = [
        "omarchy_target": "apple-silicon-full-os", "name": "Fixture", "default_os_name": "Fixture",
        "boot_object": "aura.bin", "next_object": "m1n1/boot.bin", "package": "fixture.zip",
        "icon": "aurora-volume.icns",
        "partitions": [
          [
            "name": "EFI", "type": "EFI", "size": "524288000B", "format": "fat",
            "copy_firmware": true, "copy_installer_data": true, "source": "esp",
          ],
          ["name": "Boot", "type": "Linux", "size": "1073741824B", "image": "boot.img"],
          [
            "name": "Root", "type": "Linux", "size": "10737418240B", "image": "root.img",
            "expand": true,
          ],
        ],
      ]
      return try JSONSerialization.data(withJSONObject: ["os_list": [template]])
    }

    private func run(_ machine: Data) async throws -> [String: Any] {
      let data = try await NativeInstallerDryRun.run(
        machine: machine, metadata: metadata(),
        payloadDigest: SHA256Digest(hashing: Data("payload".utf8)).rawValue, archive: nil)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testM2PlansFreeSpaceAfterMacOSWithThe13Point5Stub() async throws {
      let result = try await run(
        machine(device: "apple,j413", chip: 0x8112, macOS: "26.6.2", boot: "mBoot-18000.161.10"))
      XCTAssertEqual(result["supported"] as? Bool, true)
      let firmware = try XCTUnwrap(result["firmware"] as? [String: Any])
      XCTAssertEqual(firmware["version"] as? String, "13.5")
      let candidates = try XCTUnwrap(result["candidates"] as? [[String: Any]])
      let free = try XCTUnwrap(candidates.first { $0["kind"] as? String == "free" })
      let plan = try XCTUnwrap(free["plan"] as? [String: Any])
      XCTAssertEqual(
        plan["required_human_steps"] as? [String],
        ["enterOneTrueRecovery", "authenticateMachineOwner"])
      XCTAssertEqual(result["one_true_recovery_boot_policy"] as? [String], ["-nc"])
    }

    func testNeoUsesTheLargeStubAndCustomBootArguments() async throws {
      let result = try await run(
        machine(device: "apple,j700", chip: 0x8140, macOS: "26.6.2", boot: "mBoot-18000.161.10"))
      XCTAssertEqual(result["supported"] as? Bool, true)
      XCTAssertEqual(result["inspection_stub_bytes"] as? UInt64, 5_999_951_872)
      XCTAssertEqual(result["one_true_recovery_boot_policy"] as? [String], ["-nca"])
    }

    func testRefusedModelsStopBeforePlanning() async throws {
      let result = try await run(
        machine(device: "apple,j614s", chip: 0x6040, macOS: "26.6.2", boot: "mBoot-20457.1.29"))
      XCTAssertEqual(result["supported"] as? Bool, false)
      XCTAssertEqual(result["unsupported_reason"] as? String, "explicitly refused model")
      XCTAssertNil(result["candidates"])
    }
  }
#endif
