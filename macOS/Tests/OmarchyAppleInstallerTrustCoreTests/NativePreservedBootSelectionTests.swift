#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedBootSelectionTests: XCTestCase, @unchecked Sendable {
    func testExistingStageOneSelectionRestoresStubFilesAndVerifiesTheGroup() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-preserved-boot-" + UUID().uuidString)
      let volumes = root.appendingPathComponent("Volumes")
      let systemRoot = volumes.appendingPathComponent("Aurora NixOS")
      let version = systemRoot.appendingPathComponent(
        "System/Library/CoreServices/SystemVersion.plist")
      let disabled = systemRoot.appendingPathComponent(
        "System/Library/CoreServices/SystemVersion-disabled.plist")
      let stage1URL = systemRoot.appendingPathComponent(
        "Finish Installation.app/Contents/Resources/boot.bin")
      try FileManager.default.createDirectory(
        at: version.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      try FileManager.default.createDirectory(
        at: stage1URL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("version".utf8).write(to: disabled)
      try Data("media".utf8).write(to: systemRoot.appendingPathComponent(".IAPhysicalMedia"))
      let stage1 = Data("existing signed Stage 1".utf8)
      try stage1.write(to: stage1URL)
      let identity = NativeStubFileIdentity(
        bytes: stage1.count, sha256: NativeStubFileStore.hash(stage1))
      let stub = RemovalPartition(
        identifier: "disk0s3", uuid: UUID().uuidString, type: "Apple_APFS",
        offset: 4096, size: 1 << 20, name: "Aurora NixOS")
      let esp = RemovalPartition(
        identifier: "disk0s4", uuid: UUID().uuidString, type: "EFI",
        offset: stub.end, size: 1 << 20, name: "EFI - AUROR")
      let boot = RemovalPartition(
        identifier: "disk0s5", uuid: UUID().uuidString, type: "Linux Filesystem",
        offset: esp.end, size: 2 << 20, name: "")
      let linuxRoot = RemovalPartition(
        identifier: "disk0s6", uuid: UUID().uuidString, type: "Linux Filesystem",
        offset: boot.end, size: 4 << 20, name: "")
      let group = UUID().uuidString
      let system = RemovalVolume(
        uuid: UUID().uuidString, name: "Aurora NixOS", roles: ["System"],
        group: group, identifier: "disk8s1")
      let container = RemovalContainer(
        uuid: UUID().uuidString, storeUUID: stub.uuid, volumes: [system])
      let baseline = RemovalSnapshot(
        disk: "disk0", devicePath: "/dev/disk0", diskSize: 64 << 20,
        macOSStoreUUID: UUID().uuidString, macOSContainerUUID: UUID().uuidString,
        partitions: [stub, esp, boot, linuxRoot], containers: [container])
      let target = NativePreservedInstallTarget(
        disk: "disk0", title: "Aurora NixOS", group: group,
        stub: stub, esp: esp, boot: boot, root: linuxRoot,
        identityDigest: "sha256:" + String(repeating: "a", count: 64))
      let selected = root.appendingPathComponent("selected")
      let environment = NativeHandoffEnvironment(
        snapshot: { baseline }, device: { "apple,j314s" },
        command: { executable, arguments in
          if executable == "/sbin/mount",
            arguments == ["-u", "-w", systemRoot.path]
          { return Data() }
          if executable == "/usr/sbin/bless", arguments == ["--getBoot", "--plist"] {
            return try PropertyListSerialization.data(
              fromPropertyList: ["Boot Volume": "selected-target"], format: .xml, options: 0)
          }
          guard executable == "/usr/sbin/diskutil",
            arguments.count == 3, Array(arguments.prefix(2)) == ["info", "-plist"]
          else { throw NativeHandoffValidationError.invalidTarget }
          if arguments[2] == system.identifier {
            return try PropertyListSerialization.data(
              fromPropertyList: [
                "VolumeUUID": system.uuid, "APFSVolumeGroupID": group,
                "MountPoint": systemRoot.path, "WritableVolume": true,
              ], format: .xml, options: 0)
          }
          if arguments[2] == "selected-target" {
            return try PropertyListSerialization.data(
              fromPropertyList: [
                "APFSVolumeGroupID": FileManager.default.fileExists(atPath: selected.path)
                  ? group : UUID().uuidString,
              ], format: .xml, options: 0)
          }
          throw NativeHandoffValidationError.invalidTarget
        }, ownerUUID: { _ in UUID().uuidString },
        rawDigest: { _, _ in throw NativeHandoffValidationError.invalidTarget },
        verifyRecovery: { _, _ in throw NativeHandoffValidationError.invalidTarget },
        owner: geteuid(), mountRoot: volumes,
        sourcePrebootMount: root.appendingPathComponent("Preboot"),
        verifyMount: { fd, url, device in
          var opened = stat()
          var named = stat()
          guard device == system.identifier, url.path == systemRoot.path,
            fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
            opened.st_ino == named.st_ino
          else { throw NativeHandoffValidationError.invalidTarget }
        })
      let authorization = try MachineOwnerAuthorization(
        username: "mina", password: Data("owner-password".utf8))
      var failing = NativePreservedBootSelector(
        baseline: baseline, expectedStage1: identity, environment: environment,
        owner: geteuid())
      failing.bless = { _, _, _ in throw NativeHandoffValidationError.authorizationFailed }
      XCTAssertThrowsError(try failing.select(target, authorization: authorization))
      XCTAssertTrue(FileManager.default.fileExists(atPath: disabled.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: version.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))

      var selector = failing
      selector.bless = { arguments, input, secret in
        guard arguments == [
          "--setBoot", "--device", "/dev/disk8s1", "--user", "mina", "--stdinpass",
        ], input == Data("owner-password\n".utf8),
          secret == Data("owner-password".utf8)
        else { throw NativeHandoffValidationError.invalidTarget }
        try Data("selected".utf8).write(to: selected)
      }
      XCTAssertThrowsError(try selector.verify(target))
      try selector.select(target, authorization: authorization)
      XCTAssertTrue(FileManager.default.fileExists(atPath: disabled.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: version.path))
      try selector.verify(target)
      try Data("changed Stage 1".utf8).write(to: stage1URL)
      XCTAssertThrowsError(try selector.verify(target))
    }
  }
#endif
