#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// Captured partition/container queries are replayed through the real native
  /// collector. Volume contents and shrink limits were not in that capture;
  /// these are explicitly synthetic inputs, not physical qualification.
  final class NativeDiskCollectorReplayTests: XCTestCase {
    func testRecordedGraphsUseTheBootSnapshotAndPreserveOtherPartitions() throws {
      for label in ["legacy", "converged-before", "after-make-space", "legacy-removed"] {
        let fixture = try NativeCollectorReplay(label)
        let result = try NativeDiskCollector(disks: fixture.makeOperator()).collect(
          host: fixture.host())
        let original = try fixture.mac.makeOperator().snapshot()
        XCTAssertEqual(result.snapshot, original, label)
        XCTAssertEqual(
          result.snapshot.partitions.map(\.identifier), original.partitions.map(\.identifier), label
        )
        let root = try XCTUnwrap(
          result.containers.first { $0.storeUUID == original.macOSStoreUUID })
        XCTAssertEqual(root.systems.count, 1, label)
        XCTAssertEqual(root.systems[0].stub, false, label)
        XCTAssertEqual(root.systems[0].version, "27.0", label)
        XCTAssertTrue(fixture.opened.contains(["/", "disk4s1s1"]), label)
        XCTAssertTrue(fixture.mac.log.allSatisfy(CapturedMac.isReadOnly), label)
      }
    }

    func testMultipleSystemGroupsAndLockedDataKeepTheirOwnClassification() throws {
      let fixture = try NativeCollectorReplay("converged-before", additionalSystem: true)
      let result = try NativeDiskCollector(disks: fixture.makeOperator()).collect(
        host: fixture.host())
      let root = try XCTUnwrap(
        result.containers.first { $0.storeUUID == result.snapshot.macOSStoreUUID })
      XCTAssertEqual(root.systems.count, 2)
      XCTAssertEqual(Set(root.systems.compactMap(\.version)), ["27.0", "26.6.2"])
      XCTAssertTrue(root.systems.allSatisfy { !$0.stub })
      XCTAssertTrue(fixture.opened.contains(["/Volumes/SecondSystem", "disk4s99"]))
      XCTAssertFalse(fixture.mac.log.contains(["info", "-plist", "disk4s100"]))
    }

    func testAnUnreadableSystemIsNotTreatedAsNoExistingSystem() throws {
      let fixture = try NativeCollectorReplay("converged-before", unreadableRoot: true)
      XCTAssertThrowsError(
        try NativeDiskCollector(disks: fixture.makeOperator()).collect(host: fixture.host())
      ) {
        XCTAssertEqual($0 as? NativeInspectionError, .systemVolumeUnreadable)
      }
    }

    func testIOSContainerIsPreservedWithoutOfferingResizeOrErase() throws {
      let fixture = try NativeCollectorReplay("converged-before", foreignProduct: "iPhone OS")
      let result = try NativeDiskCollector(disks: fixture.makeOperator()).collect(
        host: fixture.host())
      XCTAssertEqual(result.snapshot, try fixture.makeOperator().snapshot())
      let part = try XCTUnwrap(result.snapshot.partitions.first { $0.identifier == "disk0s3" })
      XCTAssertFalse(result.containers.contains { $0.storeUUID == part.uuid })
      XCTAssertFalse(
        fixture.queried.contains(["apfs", "resizeContainer", "disk0s3", "limits", "-plist"]))
      XCTAssertNotNil(NativePartitionErase.refusal(members: [part], disk: result))
      let layout = try NativeDiskLayout(result)
      let region = try XCTUnwrap(layout.regions.first { $0.uuid == part.uuid })
      XCTAssertEqual(region.kind, .other)
      XCTAssertFalse(region.isErasable)
      // The captured graph fills the disk. Make a synthetic free extent next
      // to an unrelated Linux partition, without changing the iOS container.
      var snapshotWithFreeSpace = result.snapshot
      let linuxIndex = try XCTUnwrap(
        snapshotWithFreeSpace.partitions.firstIndex {
          $0.type == "Linux Filesystem" && $0.size > 64 * 1024 * 1024 * 1024
        })
      let linux = snapshotWithFreeSpace.partitions[linuxIndex]
      snapshotWithFreeSpace.partitions[linuxIndex] = RemovalPartition(
        identifier: linux.identifier, uuid: linux.uuid, type: linux.type,
        offset: linux.offset, size: linux.size - 64 * 1024 * 1024 * 1024, name: linux.name)
      let metadata = try NativeInspectionPolicy.sealed().baselineMetadata
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: "apple,j314s", snapshot: snapshotWithFreeSpace, containers: result.containers,
          metadata: metadata, stubBytes: 3_000_000_000))
      let inventory = try XCTUnwrap(transcript.inventory)
      XCTAssertTrue(inventory.candidates.contains { $0.kind == "free" })
      XCTAssertFalse(
        inventory.candidates.contains {
          $0.kind != "free" && $0.sourceIdentifier == part.identifier
        })
    }

    func testUngroupedMacOSAndUnreadableForeignMetadataStillFail() throws {
      for product in ["macOS", ""] {
        let fixture = try NativeCollectorReplay("converged-before", foreignProduct: product)
        XCTAssertThrowsError(
          try NativeDiskCollector(disks: fixture.makeOperator()).collect(host: fixture.host())
        ) {
          XCTAssertEqual($0 as? NativeInspectionError, .systemVolumeUnreadable)
        }
      }
    }

    func testRootContainerCannotUseForeignSystemException() throws {
      let fixture = try NativeCollectorReplay(
        "converged-before", foreignProduct: "iPhone OS", foreignOnRoot: true)
      XCTAssertThrowsError(
        try NativeDiskCollector(disks: fixture.makeOperator()).collect(host: fixture.host())
      ) {
        XCTAssertEqual($0 as? NativeInspectionError, .systemVolumeUnreadable)
      }
    }
  }

  private final class NativeCollectorReplay: @unchecked Sendable {
    let mac: CapturedMac
    private let root: URL
    private let second: URL
    private let lock = NSLock()
    private var accesses = [[String]]()
    private let additionalSystem: Bool
    private let unreadableRoot: Bool
    private let foreignProduct: String?
    private let foreignOnRoot: Bool
    private var queries = [[String]]()
    var queried: [[String]] { lock.withLock { queries } }
    private let systemUUID = "00000000-0000-0000-0000-000000000099"
    private let dataUUID = "00000000-0000-0000-0000-000000000100"
    private let groupUUID = "00000000-0000-0000-0000-000000000199"
    var opened: [[String]] { lock.withLock { accesses } }

    init(
      _ label: String, additionalSystem: Bool = false, unreadableRoot: Bool = false,
      foreignProduct: String? = nil, foreignOnRoot: Bool = false
    ) throws {
      mac = try CapturedMac(label)
      self.additionalSystem = additionalSystem
      self.unreadableRoot = unreadableRoot
      self.foreignProduct = foreignProduct
      self.foreignOnRoot = foreignOnRoot
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      second = root.appendingPathComponent("second")
      try Self.system(root, version: "27.0", disabled: false)
      try Self.system(second, version: "26.6.2", disabled: true)
      if let foreignProduct {
        let file = second.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        if !foreignProduct.isEmpty {
          try Self.plist(["ProductName": foreignProduct, "ProductVersion": "27.2"]).write(to: file)
        }
      }
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    private static func system(_ directory: URL, version: String, disabled: Bool) throws {
      let core = directory.appendingPathComponent("System/Library/CoreServices")
      try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("Library"), withIntermediateDirectories: true)
      let bytes = try PropertyListSerialization.data(
        fromPropertyList: ["ProductVersion": version], format: .xml, options: 0)
      try bytes.write(
        to: core.appendingPathComponent(
          disabled ? "SystemVersion-disabled.plist" : "SystemVersion.plist"))
    }

    func host() throws -> AppleSiliconHostInspection {
      let data = try Data(contentsOf: mac.directory.appendingPathComponent("info-root.plist"))
      let info = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      return AppleSiliconHostInspection(
        identity: AppleMacIdentity(
          model: "MacBookPro18,3", chip: "Apple M1 Pro",
          deviceIdentifier: "apple,j314s"), eligibility: .requiresSignedCatalog,
        macOSVersion: "27.0",
        powerSource: .ac, fileVaultEnabled: true,
        storage: APFSStorageInspection(
          containerIdentifier: try XCTUnwrap(info["APFSContainerReference"] as? String),
          physicalStoreIdentifier: "disk0s2",
          isInternal: true,
          containerSizeBytes: try XCTUnwrap(info["APFSContainerSize"] as? NSNumber).uint64Value,
          containerFreeBytes: try XCTUnwrap(info["APFSContainerFree"] as? NSNumber).uint64Value,
          minimumPreferredSizeBytes: 100_000_000_000))
    }

    func makeOperator() -> MacRemovalDiskOperator {
      var disks = mac.makeOperator()
      let commands = disks.commands
      let tree = disks.openTree
      disks.commands = { a in
        self.lock.withLock { self.queries.append(a) }
        if a.count == 5, a[0...1] == ["apfs", "resizeContainer"], a[3...] == ["limits", "-plist"] {
          return try Self.plist(["MinimumSizePreferred": 100_000_000_000 as UInt64])
        }
        if self.additionalSystem, a == ["info", "-plist", "disk4s99"] {
          return try Self.plist([
            "DeviceIdentifier": "disk4s99", "DiskUUID": self.systemUUID,
            "APFSContainerReference": "disk4",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            "MountPoint": "/Volumes/SecondSystem",
          ])
        }
        let data = try commands(a)
        if self.foreignProduct != nil {
          let reference = self.foreignOnRoot ? "disk4" : "disk2"
          if a == ["apfs", "list", "-plist"] || a == ["apfs", "listVolumeGroups", "-plist"] {
            var listing = try XCTUnwrap(
              PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            var containers = try XCTUnwrap(listing["Containers"] as? [[String: Any]])
            let index = try XCTUnwrap(
              containers.firstIndex { $0["ContainerReference"] as? String == reference })
            if a == ["apfs", "list", "-plist"] {
              let volumes = try XCTUnwrap(containers[index]["Volumes"] as? [[String: Any]])
              containers[index]["Volumes"] = volumes.filter {
                $0["Roles"] as? [String] != ["Recovery"]
              }
              // Plenty of free space must not turn a foreign OS into a resize candidate.
              containers[index]["CapacityFree"] = 2_000_000_000 as UInt64
            } else {
              containers[index]["VolumeGroups"] = [[String: Any]]()
            }
            listing["Containers"] = containers
            return try Self.plist(listing)
          }
        }
        guard self.additionalSystem else { return data }
        if a == ["apfs", "list", "-plist"] {
          var listing = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
          var containers = try XCTUnwrap(listing["Containers"] as? [[String: Any]])
          let index = try XCTUnwrap(
            containers.firstIndex { $0["ContainerReference"] as? String == "disk4" })
          var volumes = try XCTUnwrap(containers[index]["Volumes"] as? [[String: Any]])
          volumes += [
            [
              "DeviceIdentifier": "disk4s99", "APFSVolumeUUID": self.systemUUID,
              "Name": "Second macOS", "Roles": ["System"],
            ],
            [
              "DeviceIdentifier": "disk4s100", "APFSVolumeUUID": self.dataUUID,
              "Name": "Locked Data", "Roles": ["Data"], "Locked": true,
            ],
          ]
          containers[index]["Volumes"] = volumes
          listing["Containers"] = containers
          return try Self.plist(listing)
        }
        if a == ["apfs", "listVolumeGroups", "-plist"] {
          var listing = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
          var containers = try XCTUnwrap(listing["Containers"] as? [[String: Any]])
          let index = try XCTUnwrap(
            containers.firstIndex { $0["ContainerReference"] as? String == "disk4" })
          var groups = containers[index]["VolumeGroups"] as? [[String: Any]] ?? []
          groups.append([
            "APFSVolumeGroupUUID": self.groupUUID,
            "Volumes": [
              ["DiskUUID": self.systemUUID, "DeviceIdentifier": "disk4s99", "Role": "System"],
              ["DiskUUID": self.dataUUID, "DeviceIdentifier": "disk4s100", "Role": "Data"],
            ],
          ])
          containers[index]["VolumeGroups"] = groups
          listing["Containers"] = containers
          return try Self.plist(listing)
        }
        return data
      }
      disks.openTree = { path, identifier in
        if self.foreignProduct != nil && identifier == "disk2s2" {
          return try RemovalFileTree(
            descriptor: open(self.second.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        }
        if path == "/" || (self.additionalSystem && identifier == "disk4s99") {
          self.lock.withLock { self.accesses.append([path, identifier]) }
          if self.unreadableRoot && path == "/" {
            throw NativeInspectionError.systemVolumeUnreadable
          }
          let directory = path == "/" ? self.root : self.second
          return try RemovalFileTree(
            descriptor: open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        }
        return try tree(path, identifier)
      }
      return disks
    }

    private static func plist(_ value: [String: Any]) throws -> Data {
      try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
  }
#endif
