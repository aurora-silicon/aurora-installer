#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeFirmwarePublicationTests: XCTestCase, @unchecked Sendable {
    func testSourcePlanUsesOneSelectedIdentityAndExcludesBootLoadedFUD() throws {
      func manifest(_ identities: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(
          fromPropertyList: ["BuildIdentities": identities], format: .xml, options: 0)
      }
      let identity: [String: Any] = [
        "ApChipID": "0x8140",
        "Info": ["DeviceClass": "j700ap", "RestoreBehavior": "Erase", "Variant": "macOS Customer"],
        "Manifest": [
          "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]],
          "Multitouch": ["Info": ["Path": "Firmware/Multitouch.im4p", "IsFUDFirmware": true]],
          "BootLoaded": [
            "Info": [
              "Path": "Firmware/boot.im4p", "IsFUDFirmware": true,
              "IsLoadedByiBoot": true,
            ]
          ],
          "Stage1Loaded": [
            "Info": [
              "Path": "Firmware/stage1.im4p", "IsFUDFirmware": true,
              "IsLoadedByiBootStage1": true,
            ]
          ],
          "Other": ["Info": ["Path": "Firmware/other.im4p"]],
        ],
      ]
      let source = try NativeFirmwareSourcePlan(manifest: manifest([identity]))
      XCTAssertEqual(source.machine, "j700")
      XCTAssertEqual(source.chipID, 0x8140)
      XCTAssertEqual(source.kernel, "kernelcache.release.synthetic")
      XCTAssertEqual(
        source.fud, [.init(component: "Multitouch", member: "Firmware/Multitouch.im4p")])
      var withoutTrackpad = identity
      var withoutTrackpadManifest = identity["Manifest"] as! [String: Any]
      withoutTrackpadManifest.removeValue(forKey: "Multitouch")
      withoutTrackpad["Manifest"] = withoutTrackpadManifest
      XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([withoutTrackpad])))
      XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([identity, identity])))
      var malformed = identity
      malformed["Manifest"] = [
        "Multitouch": ["Info": ["Path": "../outside", "IsFUDFirmware": true]]
      ]
      XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([malformed])))
      // The chip decides chip-keyed firmware such as the ProRes rows.
      for chip: Any? in [nil, "8140", "0xzz", 0x8140] {
        var other = identity
        other["ApChipID"] = chip
        XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([other])))
      }
    }

    func testAnOLEDMacBookProSourcePlanKeepsItsTrackpadAndTouchscreenFirmware() throws {
      let identity: [String: Any] = [
        "ApChipID": "0x6050",
        "Info": [
          "DeviceClass": "k114cap", "RestoreBehavior": "Erase", "Variant": "macOS Customer",
        ],
        "Manifest": [
          "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]],
          "Multitouch": ["Info": ["Path": "Firmware/Multitouch.im4p", "IsFUDFirmware": true]],
          "Ap,TouchASICFW": ["Info": ["Path": "Firmware/Touch.im4p", "IsFUDFirmware": true]],
        ],
      ]
      let source = try NativeFirmwareSourcePlan(
        manifest: PropertyListSerialization.data(
          fromPropertyList: ["BuildIdentities": [identity]], format: .xml, options: 0))
      XCTAssertEqual(source.machine, "k114c")
      XCTAssertEqual(
        Set(source.fud.map(\.component)), ["Multitouch", "Ap,TouchASICFW"])
    }

    func testAnN1MacsSourcePlanNamesItsImageTicketAndDriverFile() throws {
      func plan(_ deviceClass: String, _ wireless: [String: String]) throws
        -> NativeFirmwareSourcePlan
      {
        var components: [String: Any] = [
          "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]]
        ]
        for (key, path) in wireless { components[key] = ["Info": ["Path": path]] }
        let identity: [String: Any] = [
          "ApChipID": "0x6050",
          "Info": [
            "DeviceClass": deviceClass, "RestoreBehavior": "Erase", "Variant": "macOS Customer",
          ],
          "Manifest": components,
        ]
        return try NativeFirmwareSourcePlan(
          manifest: PropertyListSerialization.data(
            fromPropertyList: ["BuildIdentities": [identity]], format: .xml, options: 0))
      }
      let image = "Firmware/synthetic/ftab.bin"
      let n1 = try plan("j714sap", ["Wireless1,Wi-Fi": image, "Wireless1,Bluetooth": image])
      XCTAssertEqual(
        n1.centauri,
        NativeFirmwareSourcePlan.Centauri(
          image: image, ticket: "centauri/centauri.j714sap.im4m",
          name: "apple/centauri/j714s-ftab.bin"))
      XCTAssertEqual(
        try plan("j873gap", ["Wireless1,Wi-Fi": image]).centauri?.name,
        "apple/centauri/j873-ftab.bin")
      XCTAssertNil(n1.centauriProblem)
      // A Mac whose build identity has no N1 collects none.
      let other = try plan("j704ap", [:])
      XCTAssertNil(other.centauri)
      XCTAssertNil(other.centauriProblem)
      // The driver loads one image: with two, the Mac installs without one.
      let two = try plan(
        "j714sap", ["Wireless1,Wi-Fi": image, "Wireless1,Bluetooth": "Firmware/other.bin"])
      XCTAssertNil(two.centauri)
      XCTAssertEqual(two.centauriProblem, "the build identity names 2 different N1 images")
      XCTAssertThrowsError(try plan("j714sap", ["Wireless1,Wi-Fi": "../outside"]))
    }

    func testArchiveStreamingExceedsBootBudgetWithoutRelaxingBootCallers() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let source = root.appendingPathComponent("archive")
      let descriptor = open(source.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { close(descriptor) }
      let size = (64 << 20) + 4096
      XCTAssertEqual(ftruncate(descriptor, off_t(size)), 0)
      try NativeRawImagePlatform.write(descriptor, Data("archive tail".utf8), UInt64(size - 12))
      XCTAssertEqual(fsync(descriptor), 0)
      let sourceTree = try NativeHandoffFileTree(root, protected: true, owner: geteuid())
      let expected = try NativeStubFileStore(tree: sourceTree, owner: geteuid()).identity("archive")
      let espRoot = root.appendingPathComponent("esp")
      try FileManager.default.createDirectory(
        at: espRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let esp = try NativeESPFileStore(
        root: espRoot, volumeDevice: "fixture", namespace: "archive", verifyMount: { _, _, _ in },
        admitFilesystem: { _ in })
      let published = try await esp.file(
        sourceTree, path: "archive", identity: expected, owner: geteuid(),
        at: "vendorfw/firmware.tar")
      XCTAssertEqual(published, expected)
      XCTAssertThrowsError(try esp.identity("vendorfw/firmware.tar"))
      XCTAssertEqual(try esp.identity("vendorfw/firmware.tar", maximum: 256 << 20), expected)
      let repeated = try await esp.file(
        sourceTree, path: "archive", identity: expected, owner: geteuid(),
        at: "vendorfw/firmware.tar")
      XCTAssertEqual(repeated, expected)
      do {
        _ = try await esp.data(Data(count: size), at: "boot/too-large.bin")
        XCTFail("Boot data writer accepted the archive budget")
      } catch {}
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: espRoot.appendingPathComponent("boot/too-large.bin").path))
      let wrong = NativeStubFileIdentity(bytes: size, sha256: String(repeating: "0", count: 64))
      do {
        _ = try await esp.file(
          sourceTree, path: "archive", identity: wrong, owner: geteuid(), at: "vendorfw/wrong.tar")
        XCTFail("Changed source digest was published")
      } catch {}
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: espRoot.appendingPathComponent("vendorfw/wrong.tar").path))
      let copied = try await NativeStubFileStore(tree: sourceTree, owner: geteuid()).file(
        esp.tree, path: "vendorfw/firmware.tar", identity: expected, at: "recovery/firmware.tar")
      XCTAssertEqual(copied, expected)
    }

    func testImageDetachFailurePreservesOwnershipAndOperationFailure() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let image = NativeFirmwareMountedImage(
        directory: root, root: root.appendingPathComponent("recovery"), device: "disk99s1",
        command: { executable, args in
          XCTAssertEqual(executable, "/usr/bin/hdiutil")
          XCTAssertEqual(args, ["detach", "/dev/disk99s1"])
          throw NativeFirmwareInputFailure.detachFailed
        })
      do {
        let _: Int = try await NativeFirmwareMountedImage.withCleanup(image) {
          throw NativeFirmwareInputFailure.invalidSource
        }
        XCTFail("Cleanup failure was hidden")
      } catch NativeFirmwareInputFailure.cleanupFailed(let operation, let cleanup) {
        XCTAssertTrue(operation is NativeFirmwareInputFailure)
        XCTAssertTrue(cleanup is NativeFirmwareInputFailure)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRadioSnapshotKeepsLinksWithinTheirDirectory() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let wifi = root.appendingPathComponent("usr/share/firmware/wifi/C-4378__s-B3")
      try FileManager.default.createDirectory(at: wifi, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("trx".utf8).write(to: wifi.appendingPathComponent("kyushu.trx"))
      let fm = FileManager.default
      try fm.createSymbolicLink(
        atPath: wifi.appendingPathComponent("kyushu-X0.trx").path, withDestinationPath: "kyushu.trx"
      )
      try fm.createSymbolicLink(
        atPath: wifi.appendingPathComponent("kyushu-X1.trx").path,
        withDestinationPath: "kyushu-X0.trx")
      try fm.createSymbolicLink(
        atPath: wifi.appendingPathComponent("aruba.trx").path, withDestinationPath: "missing.trx")
      let tree = try NativeHandoffFileTree(root, protected: true, owner: geteuid())
      let snapshot = try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: "usr/share/firmware", tree: tree, owner: geteuid())
      XCTAssertEqual(snapshot.files, ["wifi/C-4378__s-B3/kyushu.trx": Data("trx".utf8)])
      XCTAssertEqual(
        snapshot.links,
        [
          "wifi/C-4378__s-B3/kyushu-X0.trx": "wifi/C-4378__s-B3/kyushu.trx",
          "wifi/C-4378__s-B3/kyushu-X1.trx": "wifi/C-4378__s-B3/kyushu.trx",
        ])
      // A link that leaves its directory is refused, not followed.
      try fm.createSymbolicLink(
        atPath: wifi.appendingPathComponent("outside.trx").path,
        withDestinationPath: "../../../outside")
      XCTAssertThrowsError(
        try NativeFirmwareInputFiles.snapshot(
          root: root, prefix: "usr/share/firmware", tree: tree, owner: geteuid()))
      // Directory walks that never admit links still refuse them.
      XCTAssertThrowsError(try NativeFirmwareInputFiles.relativeEntries(root: wifi, maximum: 10))
    }

    func testMountpointUsesTheRealPathThatHdiutilReports() throws {
      // /var is a symlink to /private/var, as for the helper's working directory.
      let parent = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
      XCTAssertEqual(parent.resolvingSymlinksInPath().path, "/var/tmp")
      let real = try NativeFirmwareMountedImage.realDirectory(parent)
      XCTAssertEqual(real.path, "/private/var/tmp")

      let root = real.appendingPathComponent("firmware-image-test/recovery")
      func response(mountPoint: String) throws -> Data {
        try PropertyListSerialization.data(
          fromPropertyList: [
            "system-entities": [
              ["dev-entry": "/dev/disk11", "content-hint": "GUID_partition_scheme"],
              [
                "dev-entry": "/dev/disk11s1", "mount-point": mountPoint,
                "content-hint": "41504653-0000-11AA-AA11-00306543ECAC",
              ],
            ]
          ], format: .xml, options: 0)
      }
      XCTAssertEqual(
        try NativeFirmwareMountedImage.attachedDevice(
          response(mountPoint: "/private/var/tmp/firmware-image-test/recovery"), root: root),
        "disk11s1")
      // The Foundation spelling never matches what hdiutil reports.
      XCTAssertThrowsError(
        try NativeFirmwareMountedImage.attachedDevice(
          response(mountPoint: "/private/var/tmp/firmware-image-test/recovery"),
          root: parent.resolvingSymlinksInPath()
            .appendingPathComponent("firmware-image-test/recovery")))
    }
  }
#endif
