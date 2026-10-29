#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativeHandoffMountsTests: XCTestCase {
    /// One FAT volume that diskutil mounts at `/Volumes/EFI`, as recorded.
    private final class FakeVolume: @unchecked Sendable {
      let lock = NSLock()
      let uuid = UUID().uuidString
      let root: URL
      var mountPoint: String?
      var browsable = true
      var commands: [[String]] = []

      init(root: URL, mountedBrowsable: Bool) {
        self.root = root
        if mountedBrowsable { mountPoint = root.appendingPathComponent("EFI").path }
      }

      func command(_ executable: String, _ arguments: [String]) throws -> Data {
        XCTAssertEqual(executable, "/usr/sbin/diskutil")
        return try lock.withLock {
          if arguments == ["info", "-plist", "disk0s9"] {
            var info: [String: Any] = ["DiskUUID": uuid, "WritableVolume": true]
            info["MountPoint"] = mountPoint ?? ""
            return try PropertyListSerialization.data(
              fromPropertyList: info, format: .xml, options: 0)
          }
          commands.append(arguments)
          switch arguments.first {
          case "unmount": mountPoint = nil
          case "mount":
            browsable = !arguments.contains("nobrowse")
            mountPoint = root.appendingPathComponent("EFI").path
          default: XCTFail("Unexpected disk command \(arguments)")
          }
          return Data()
        }
      }

      func isBrowsable(_ url: URL) -> Bool {
        lock.withLock { url.path == mountPoint && browsable }
      }

      func environment() -> NativeHandoffEnvironment {
        NativeHandoffEnvironment(
          snapshot: { throw NativeHandoffValidationError.invalidTarget },
          device: { "apple,j700" }, command: { try self.command($0, $1) },
          ownerUUID: { _ in UUID().uuidString }, rawDigest: { _, _ in "" },
          verifyRecovery: { _, _ in }, owner: geteuid(), mountRoot: root,
          sourcePrebootMount: root.appendingPathComponent("Preboot"),
          verifyMount: { _, _, _ in }, mountIsBrowsable: { self.isBrowsable($0) })
      }
    }

    private func volumes() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "handoff-mounts-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      return root
    }

    func testTheLinuxESPIsMountedOutOfSightOfFinderSpotlightAndTheTrash() throws {
      let root = try volumes()
      defer { try? FileManager.default.removeItem(at: root) }
      let volume = FakeVolume(root: root, mountedBrowsable: false)
      do {
        let mounts = NativeHandoffMounts(volume.environment())
        let url = try mounts.mounted(
          "disk0s9", uuid: volume.uuid, key: "DiskUUID", writable: true, browsable: false)
        XCTAssertEqual(url.path, root.appendingPathComponent("EFI").path)
        XCTAssertEqual(volume.commands, [["mount", "nobrowse", "disk0s9"]])
      }
      XCTAssertEqual(volume.commands.last, ["unmount", "disk0s9"])
    }

    func testABrowsableMountIsMountedAgainOutOfSight() throws {
      let root = try volumes()
      defer { try? FileManager.default.removeItem(at: root) }
      // Disk Arbitration mounts a newly formatted ESP where Finder sees it.
      let volume = FakeVolume(root: root, mountedBrowsable: true)
      let mounts = NativeHandoffMounts(volume.environment())
      _ = try mounts.mounted(
        "disk0s9", uuid: volume.uuid, key: "DiskUUID", writable: true, browsable: false)
      XCTAssertEqual(
        volume.commands, [["unmount", "disk0s9"], ["mount", "nobrowse", "disk0s9"]])
      XCTAssertFalse(volume.browsable)
    }

    func testOtherVolumesKeepTheirMountsAndOptions() throws {
      let root = try volumes()
      defer { try? FileManager.default.removeItem(at: root) }
      let mounted = FakeVolume(root: root, mountedBrowsable: true)
      _ = try NativeHandoffMounts(mounted.environment()).mounted(
        "disk0s9", uuid: mounted.uuid, key: "DiskUUID", writable: true)
      XCTAssertEqual(mounted.commands, [])

      let unmounted = FakeVolume(root: root, mountedBrowsable: false)
      do {
        let mounts = NativeHandoffMounts(unmounted.environment())
        _ = try mounts.mounted("disk0s9", uuid: unmounted.uuid, key: "DiskUUID")
      }
      XCTAssertEqual(unmounted.commands.first, ["mount", "readOnly", "disk0s9"])
    }
  }
#endif
