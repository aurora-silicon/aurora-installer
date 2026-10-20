#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeSourceOwnerAdmissionTests: XCTestCase, @unchecked Sendable {
    func testBootstrapMatchesTheLockedBackendSourceOwnerVectors() throws {
      struct Fixture: Decodable {
        struct Vector: Decodable { let fault: String; let expected: String? }
        let vectors: [Vector]
      }
      let url = try XCTUnwrap(Bundle.module.url(
        forResource: "native-source-owner-vectors", withExtension: "json", subdirectory: "Fixtures"))
      let vectors = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).vectors
      XCTAssertEqual(vectors.count, 10)
      for vector in vectors {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.fault = vector.fault
        switch vector.fault {
        case "wrong-guid": try fixture.writeAdmins(["mina": ["GeneratedUID": UUID().uuidString]])
        case "wrong-user": try fixture.writeAdmins(["other": ["GeneratedUID": fixture.owner]])
        case "missing": try FileManager.default.removeItem(at: fixture.admins)
        case "duplicate-system": fixture.updateVolumes { $0.append($0[0]) }
        default: break
        }
        if let expected = vector.expected {
          let actual = try fixture.admit()
          XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual.configuration, options: [.sortedKeys]),
            Data(expected.utf8), vector.fault)
        } else { XCTAssertThrowsError(try fixture.admit(), vector.fault) }
      }
    }
    func testSourceOwnerIsResolvedBeforeAnyTargetExistsAndSkipsTheBootSnapshot() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let bootstrap = try fixture.admit()
      XCTAssertEqual(bootstrap.systemUUID, fixture.system)
      XCTAssertEqual(bootstrap.groupUUID, fixture.group)
      XCTAssertEqual(bootstrap.ownerUUID, fixture.owner)
      XCTAssertNotEqual(bootstrap.systemUUID, fixture.bootSnapshot)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.system.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.esp.path))
      XCTAssertFalse(fixture.commands.contains { $0.first == "unmount" })
      XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted))
    }

    func testTargetBootstrapAndLiveSourceUseTheSameOwnerProof() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let admission = NativeSourceOwnerAdmission(environment: fixture.environment())
      let bootstrap = try fixture.admit()
      let target = UUID().uuidString
      let config: [String: Any] = ["bootstrap": bootstrap.configuration, "groupUUID": target]
      try admission.requireExpected(config: config, snapshot: fixture.snapshot,
        authorization: fixture.base.authorization(), mounts: NativeHandoffMounts(fixture.environment()))
      for fault in ["system", "group", "owner", "mode", "owners", "target"] {
        var changed = bootstrap.configuration
        var targetGroup = target
        switch fault {
        case "system": changed["sourceSystemUUID"] = UUID().uuidString
        case "group": changed["sourceGroupUUID"] = UUID().uuidString
        case "owner": changed["ownerUUIDs"] = [UUID().uuidString]
        case "mode": changed["mode"] = "other"
        case "owners": changed["ownerUUIDs"] = [fixture.owner, fixture.owner]
        default: targetGroup = bootstrap.groupUUID
        }
        XCTAssertThrowsError(try admission.requireExpected(
          config: ["bootstrap": changed, "groupUUID": targetGroup], snapshot: fixture.snapshot,
          authorization: fixture.base.authorization(), mounts: NativeHandoffMounts(fixture.environment())), fault)
      }
    }

    func testChangedOwnerSourceGroupGraphOrMountedPrebootFailsClosed() throws {
      for fault in ["device", "store", "root-group", "source-system", "source-reference", "local-guid",
                    "volume-owner", "numeric-owner", "preboot-uuid", "preboot-path", "mount-device",
                    "duplicate-system", "missing-data", "duplicate-preboot", "layout-race"] {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.fault = fault
        if fault == "duplicate-system" { fixture.updateVolumes { $0.append($0[0]) } }
        if fault == "missing-data" { fixture.updateVolumes { $0.removeAll { $0.roles == ["Data"] } } }
        if fault == "duplicate-preboot" { fixture.updateVolumes { $0.append($0[2]) } }
        XCTAssertThrowsError(try fixture.admit(), fault)
        XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted), fault)
        XCTAssertFalse(fixture.commands.contains { $0.first == "unmount" }, fault)
      }
    }

    func testProtectedPrebootMetadataRejectsMissingWrongWritableAndLinkedOwners() throws {
      for fault in ["missing", "wrong-guid", "wrong-user", "writable", "symlink"] {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        switch fault {
        case "missing": try FileManager.default.removeItem(at: fixture.admins)
        case "wrong-guid": try fixture.writeAdmins(["mina": ["GeneratedUID": UUID().uuidString]])
        case "wrong-user": try fixture.writeAdmins(["other": ["GeneratedUID": fixture.owner]])
        case "writable": XCTAssertEqual(chmod(fixture.admins.path, 0o664), 0)
        default:
          let other = fixture.base.root.appendingPathComponent("other-admins.plist")
          try Data(contentsOf: fixture.admins).write(to: other)
          try FileManager.default.removeItem(at: fixture.admins)
          try FileManager.default.createSymbolicLink(at: fixture.admins, withDestinationURL: other)
        }
        XCTAssertThrowsError(try fixture.admit(), fault)
      }
    }

    func testOnlyInspectionOwnedReadOnlyMountIsCleanedAfterSuccessOrFailure() throws {
      for failure in [false, true] {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.prebootMounted = false
        if failure { try FileManager.default.removeItem(at: fixture.admins) }
        if failure { XCTAssertThrowsError(try fixture.admit()) } else { _ = try fixture.admit() }
        XCTAssertFalse(fixture.prebootMounted)
        XCTAssertEqual(fixture.commands.filter { $0.first == "mount" }, [["mount", "readOnly", "disk4s3"]])
        XCTAssertEqual(fixture.commands.filter { $0.first == "unmount" }, [["unmount", "disk4s3"]])
        XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted))
      }
    }

    func testCancellationBeforeSourceAdmissionLaunchesNoCommands() async throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try fixture.admit()
      }
      do { _ = try await task.value; XCTFail("Cancelled admission completed") }
      catch is CancellationError {}
      XCTAssertTrue(fixture.commands.isEmpty)
    }
  }

  private final class OwnerFixture: @unchecked Sendable {
    let base: NativeRecoveryHandoffFixture
    var snapshot: RemovalSnapshot
    var commands = [[String]]()
    var fault = ""
    var prebootMounted = true
    var snapshots = 0
    let system: String, group: String, owner: String
    let bootSnapshot = "00000000-0000-0000-0000-000000000777"
    var admins: URL {
      base.sourcePreboot.appendingPathComponent(group + "/var/db/AdminUserRecoveryInfo.plist")
    }

    init() throws {
      base = try NativeRecoveryHandoffFixture()
      let config = base.vector["config"] as! [String: Any]
      let bootstrap = config["bootstrap"] as! [String: Any]
      system = bootstrap["sourceSystemUUID"] as! String
      group = bootstrap["sourceGroupUUID"] as! String
      owner = (bootstrap["ownerUUIDs"] as! [String])[0]
      var disk = base.diskSnapshot
      disk.containers = [disk.containers[0]]
      disk.partitions.removeAll { ["disk0s4", "disk0s5", "disk0s6", "disk0s7"].contains($0.identifier) }
      snapshot = disk
      try FileManager.default.removeItem(at: base.system)
      try FileManager.default.removeItem(at: base.esp)
    }

    func updateVolumes(_ update: (inout [RemovalVolume]) -> Void) {
      let container = snapshot.containers[0]
      var volumes = container.volumes
      update(&volumes)
      snapshot.containers[0] = RemovalContainer(uuid: container.uuid, storeUUID: container.storeUUID, volumes: volumes)
    }

    func admit() throws -> NativeSourceBootstrap {
      try NativeSourceOwnerAdmission(environment: environment()).check(
        package: base.package, authorization: base.authorization())
    }

    func writeAdmins(_ value: Any) throws {
      try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: admins)
    }

    func permitted(_ args: [String]) -> Bool {
      (args.count == 3 && Array(args.prefix(2)) == ["info", "-plist"])
        || args == ["apfs", "listUsers", system, "-plist"]
        || args == ["mount", "readOnly", "disk4s3"] || args == ["unmount", "disk4s3"]
    }

    func environment() -> NativeHandoffEnvironment {
      let original = base.environment()
      return NativeHandoffEnvironment(snapshot: {
        self.snapshots += 1
        if self.fault == "store" {
          let disk = self.snapshot
          return RemovalSnapshot(disk: "disk9", devicePath: disk.devicePath, diskSize: disk.diskSize,
            macOSStoreUUID: disk.macOSStoreUUID, macOSContainerUUID: disk.macOSContainerUUID,
            partitions: disk.partitions, containers: disk.containers)
        }
        if self.fault == "layout-race", self.snapshots > 1 {
          var changed = self.snapshot
          changed.partitions[1].size += 4096
          return changed
        }
        return self.snapshot
      }, device: { self.fault == "device" ? "apple,j613" : self.base.package.deviceIdentifier },
      command: { executable, args in
        guard executable == "/usr/sbin/diskutil", self.permitted(args) else {
          throw NativeHandoffValidationError.invalidOwner
        }
        self.commands.append(args)
        func plist(_ value: Any) throws -> Data {
          try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        if args == ["info", "-plist", "/"] {
          return try plist(["APFSVolumeGroupID": self.fault == "root-group" ? UUID().uuidString : self.group,
                            "APFSContainerReference": "disk4", "VolumeUUID": self.bootSnapshot])
        }
        if args == ["info", "-plist", "disk4s1"] {
          return try plist(["VolumeUUID": self.fault == "source-system" ? UUID().uuidString : self.system,
                            "APFSVolumeGroupID": self.group,
                            "APFSContainerReference": self.fault == "source-reference" ? "disk9" : "disk4"])
        }
        if args == ["apfs", "listUsers", self.system, "-plist"] {
          let flag: Any
          if self.fault == "numeric-owner" { flag = 1 } else { flag = self.fault != "volume-owner" }
          return try plist(["Users": [["APFSCryptoUserUUID": self.owner, "VolumeOwner": flag]]])
        }
        if args == ["info", "-plist", "disk4s3"] {
          return try plist(["VolumeUUID": self.fault == "preboot-uuid" ? UUID().uuidString : self.snapshot.containers[0].volumes.first { $0.roles == ["Preboot"] }!.uuid,
                            "MountPoint": self.prebootMounted ? (self.fault == "preboot-path" ? "/tmp/untrusted" : self.base.sourcePreboot.path) : ""])
        }
        if args == ["mount", "readOnly", "disk4s3"] { self.prebootMounted = true; return Data() }
        if args == ["unmount", "disk4s3"] { self.prebootMounted = false; return Data() }
        throw NativeHandoffValidationError.invalidOwner
      }, ownerUUID: { username in
        XCTAssertEqual(username, "mina")
        return self.fault == "local-guid" ? UUID().uuidString : self.owner
      }, rawDigest: original.rawDigest, verifyRecovery: original.verifyRecovery,
      owner: original.owner, mountRoot: original.mountRoot, sourcePrebootMount: original.sourcePrebootMount,
      verifyMount: { fd, url, device in
        if self.fault == "mount-device" { throw NativeHandoffValidationError.invalidOwner }
        try original.verifyMount(fd, url, device)
      })
    }
  }
#endif
