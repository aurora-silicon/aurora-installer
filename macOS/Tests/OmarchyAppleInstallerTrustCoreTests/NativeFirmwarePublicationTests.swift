#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeFirmwarePublicationTests: XCTestCase, @unchecked Sendable {
    func testSourcePlanUsesOneSelectedIdentityAndExcludesBootLoadedFUD() throws {
      func manifest(_ identities: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(
          fromPropertyList: ["BuildIdentities": identities], format: .xml, options: 0)
      }
      let identity: [String: Any] = [
        "Info": ["DeviceClass": "j700ap", "RestoreBehavior": "Erase", "Variant": "macOS Customer"],
        "Manifest": [
          "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]],
          "Multitouch": ["Info": ["Path": "Firmware/Multitouch.im4p", "IsFUDFirmware": true]],
          "BootLoaded": ["Info": ["Path": "Firmware/boot.im4p", "IsFUDFirmware": true,
                                      "IsLoadedByiBoot": true]],
          "Stage1Loaded": ["Info": ["Path": "Firmware/stage1.im4p", "IsFUDFirmware": true,
                                        "IsLoadedByiBootStage1": true]],
          "Other": ["Info": ["Path": "Firmware/other.im4p"]],
        ],
      ]
      let source = try NativeFirmwareSourcePlan(manifest: manifest([identity]))
      XCTAssertEqual(source.machine, "j700")
      XCTAssertEqual(source.kernel, "kernelcache.release.synthetic")
      XCTAssertEqual(source.fud, [.init(component: "Multitouch", member: "Firmware/Multitouch.im4p")])
      XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([identity, identity])))
      var malformed = identity
      malformed["Manifest"] = ["Multitouch": ["Info": ["Path": "../outside", "IsFUDFirmware": true]]]
      XCTAssertThrowsError(try NativeFirmwareSourcePlan(manifest: manifest([malformed])))
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
        sourceTree, path: "archive", identity: expected, owner: geteuid(), at: "vendorfw/firmware.tar")
      XCTAssertEqual(published, expected)
      XCTAssertThrowsError(try esp.identity("vendorfw/firmware.tar"))
      XCTAssertEqual(try esp.identity("vendorfw/firmware.tar", maximum: 256 << 20), expected)
      let repeated = try await esp.file(
        sourceTree, path: "archive", identity: expected, owner: geteuid(), at: "vendorfw/firmware.tar")
      XCTAssertEqual(repeated, expected)
      do {
        _ = try await esp.data(Data(count: size), at: "boot/too-large.bin")
        XCTFail("Boot data writer accepted the archive budget")
      } catch {}
      XCTAssertFalse(FileManager.default.fileExists(atPath: espRoot.appendingPathComponent("boot/too-large.bin").path))
      let wrong = NativeStubFileIdentity(bytes: size, sha256: String(repeating: "0", count: 64))
      do {
        _ = try await esp.file(sourceTree, path: "archive", identity: wrong, owner: geteuid(), at: "vendorfw/wrong.tar")
        XCTFail("Changed source digest was published")
      } catch {}
      XCTAssertFalse(FileManager.default.fileExists(atPath: espRoot.appendingPathComponent("vendorfw/wrong.tar").path))
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
  }
#endif
