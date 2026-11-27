#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  /// Every Mac the sealed policy admits, with what its build identity carries
  /// in each admitted restore image (`scripts/restore-image-firmware.json`,
  /// written from the images by `scripts/restore_image_firmware.py`): the
  /// source plan for that identity must collect its N1 Wi-Fi and Bluetooth
  /// firmware under the name the kernel requests, and nothing on a Mac
  /// without an N1. Synthetic bytes only. `test_restore_image_firmware.py`
  /// checks the same record against the policy and the Python collector.
  final class NativeRestoreImageFirmwareTests: XCTestCase {
    private static let scripts = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts")

    private static func json(_ name: String) throws -> [String: Any] {
      let data = try Data(contentsOf: scripts.appendingPathComponent(name))
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
    }

    /// The single identity a stub of this Mac's restore source has, with a
    /// synthetic path for each N1 image the real identity names.
    private static func source(
      machine: String, chip: String, url: String, images: Int
    ) throws -> NativeFirmwareSourcePlan {
      let layout = try XCTUnwrap(NativeRestoreSourceLayout(sourceURL: XCTUnwrap(URL(string: url))))
      var components: [String: Any] = [
        "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]]
      ]
      for index in 0..<images {
        components["Wireless1,Synthetic\(index)"] = [
          "Info": ["Path": "Firmware/synthetic\(index)/ftab.bin"]
        ]
      }
      let identity: [String: Any] = [
        "ApChipID": chip,
        "Info": [
          "DeviceClass": machine + "ap", "RestoreBehavior": layout.restoreBehavior,
          "Variant": layout.variant,
        ],
        "Manifest": components,
      ]
      return try NativeFirmwareSourcePlan(
        manifest: PropertyListSerialization.data(
          fromPropertyList: ["BuildIdentities": [identity]], format: .xml, options: 0))
    }

    func testEveryAdmittedN1MacGetsItsFirmwareUnderTheKernelName() throws {
      let record = try Self.json("restore-image-firmware.json")
      let kernel = try XCTUnwrap(Self.json("n1-kernel-firmware.json")["names"] as? [String: Any])
      let images = try XCTUnwrap(record["images"] as? [[String: Any]])
      XCTAssertFalse(images.isEmpty)
      var n1 = Set<String>()
      for image in images {
        let url = try XCTUnwrap(image["url"] as? String)
        let identities = try XCTUnwrap(image["identities"] as? [String: [String: Any]])
        for (machine, identity) in identities.sorted(by: { $0.key < $1.key }) {
          let chip = try XCTUnwrap(identity["chip_id"] as? String)
          let count = try XCTUnwrap(identity["n1_images"] as? Int)
          let plan = try Self.source(machine: machine, chip: chip, url: url, images: count)
          let label = "\(url) \(machine)"
          guard count > 0 else {
            XCTAssertNil(plan.centauri, label)
            XCTAssertNil(plan.centauriProblem, label)
            XCTAssertNil(try NativeCentauriFirmware.prepare(plan) { _, _ in nil }, label)
            continue
          }
          n1.insert(machine)
          XCTAssertEqual(count, 1, label)
          XCTAssertEqual(identity["n1_ticket"] as? Bool, true, label)
          let centauri = try XCTUnwrap(plan.centauri, label)
          XCTAssertEqual(centauri.ticket, "centauri/centauri.\(machine)ap.im4m", label)
          XCTAssertEqual(centauri.image, "Firmware/synthetic0/ftab.bin", label)
          XCTAssertTrue(kernel.keys.contains(machine), label)
          if let requested = kernel[machine] as? String {
            XCTAssertEqual(centauri.name, requested, label)
          } else {
            XCTAssertEqual(centauri.name, "apple/centauri/\(machine)-ftab.bin", label)
          }
          let files = [
            centauri.image: NativeCentauriFirmwareTests.image,
            centauri.ticket: NativeCentauriFirmwareTests.ticket,
          ]
          let prepared = try XCTUnwrap(
            try NativeCentauriFirmware.prepare(plan) { path, _ in files[path] }, label)
          XCTAssertEqual(Array(prepared.package.keys), [centauri.name], label)
          XCTAssertEqual(prepared.fallback.count, 2, label)
        }
      }
      XCTAssertEqual(n1, Set(kernel.keys))
      XCTAssertTrue(["j714s", "j813", "j873g", "k114s", "k116c"].allSatisfy(n1.contains))
    }
  }
#endif
