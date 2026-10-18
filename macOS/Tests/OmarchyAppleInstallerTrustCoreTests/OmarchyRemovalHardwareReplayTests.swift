#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  /// Replays what diskutil, bless and nvram printed on the M1 Pro lab Mac
  /// (macOS 27.0, 2026-09-28) through the real disk operator. `legacy` is an
  /// older omarchy-mac install made by asahi-alarm v0.9.2, `converged-before` is
  /// this app's own layout, and `after-make-space` and `legacy-removed` are what
  /// removal left on that Mac. Account names and UUIDs, SMART data and build
  /// paths were redacted, and installer.log keeps only its "New partition:"
  /// records; everything removal reads is as captured.
  final class OmarchyRemovalHardwareReplayTests: XCTestCase {
    func testOlderOmarchyMacInstallWithADirtyEFIPartition() throws {
      let mac = try CapturedMac("legacy", diskutilRefusesMount: ["disk0s4"])
      let plan = try OmarchyRemovalPlan(disks: mac.makeOperator())
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(plan.installation?.name, "Asahi Alarm Minimal")
      XCTAssertEqual(plan.members.map(\.identifier), ["disk0s3", "disk0s4", "disk0s5"])
      XCTAssertEqual(plan.macOS.identifier, "disk0s2")
      XCTAssertEqual(plan.reclaimBytes, 40_662_585_344)
      XCTAssertEqual(plan.targetMacOSBytes, 994_662_584_320)
      XCTAssertEqual(
        plan.targetMacOSBytes, try CapturedMac("legacy-removed").size(of: "disk0s2"),
        "macOS grows to the size it had on the Mac after this removal")
      try assertConfirmed(plan, esp: "1bc56391-63e4-4bbd-9485-4517bc7f3aa7")
      XCTAssertEqual(
        mac.log.filter { ["mount", "openFAT", "unmount"].contains($0[0]) },
        [["openFAT", "disk0s4", "4096", "524288000"]],
        "the dirty EFI partition is read from its raw device and never mounted")
      XCTAssertEqual(mac.createdMountPoints, [])
      XCTAssertEqual(mac.opened, [["/Volumes/Asahi Alarm Minimal", "disk3s2"]])
      assertReadOnly(mac)
    }

    func testConvergedInstall() throws {
      let mac = try CapturedMac("converged-before")
      let plan = try OmarchyRemovalPlan(disks: mac.makeOperator())
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(plan.installation?.name, "Omarchy")
      XCTAssertEqual(
        plan.members.map(\.identifier), ["disk0s3", "disk0s4", "disk0s5", "disk0s6"])
      XCTAssertEqual(plan.macOS.identifier, "disk0s2")
      XCTAssertEqual(plan.reclaimBytes, 315_999_911_936)
      XCTAssertEqual(plan.targetMacOSBytes, 994_662_584_320)
      try assertConfirmed(plan, esp: "14ea5495-50e5-40c5-a8a5-a52c66791e85")
      XCTAssertEqual(
        mac.log.filter { ["mount", "openFAT", "unmount"].contains($0[0]) },
        [["openFAT", "disk0s4", "4096", "524288000"]])
      XCTAssertEqual(mac.createdMountPoints, [])
      XCTAssertEqual(mac.opened, [["/Volumes/Omarchy", "disk2s2"]])
      assertReadOnly(mac)
    }

    func testCapturedStartupDiskIsTheRunningMacOS() throws {
      for label in ["legacy", "converged-before"] {
        let plan = try OmarchyRemovalPlan(disks: CapturedMac(label).makeOperator())
        XCTAssertNil(plan.startup, label)
        XCTAssertNil(plan.ticket(id: UUID()).startupDisk, label)
      }
    }

    func testConvergedInstallSetAsTheStartupDiskIsPlannedFirst() throws {
      let mac = try CapturedMac("converged-before")
      mac.startupDevice = "/dev/disk2s2\n"
      let plan = try OmarchyRemovalPlan(disks: mac.makeOperator())
      XCTAssertEqual(plan.startup, .other("Omarchy"))
      XCTAssertEqual(
        plan.ticket(id: UUID()).startupDisk,
        OmarchyRemovalItem(
          title: "Set macOS “Macintosh HD” as the startup disk",
          detail: "Your Mac starts up from “Omarchy” now", bytes: 0))
      assertReadOnly(mac)
    }

    func testFreeSpaceLeftAfterMacOSIsReturned() throws {
      let mac = try CapturedMac("after-make-space")
      let plan = try OmarchyRemovalPlan(disks: mac.makeOperator())
      XCTAssertEqual(plan.kind, .freeSpace)
      XCTAssertNil(plan.installation)
      XCTAssertEqual(plan.members, [])
      XCTAssertEqual(plan.reclaimBytes, 40_662_585_344)
      XCTAssertEqual(plan.targetMacOSBytes, 994_662_584_320)
      XCTAssertTrue(mac.log.contains(["apfs", "resizeContainer", "disk0s2", "limits", "-plist"]))
      XCTAssertEqual(mac.opened, [])
      assertReadOnly(mac)
    }

    func testNothingIsFoundAfterRemoval() throws {
      let mac = try CapturedMac("legacy-removed")
      XCTAssertThrowsError(try OmarchyRemovalPlan(disks: mac.makeOperator())) { error in
        XCTAssertEqual((error as? RemovalFailure)?.message, RemovalText.nothingFound(gap: 0))
      }
      XCTAssertEqual(mac.opened, [])
      assertReadOnly(mac)
    }

    private func assertConfirmed(
      _ plan: OmarchyRemovalPlan, esp: String, file: StaticString = #filePath,
      line: UInt = #line
    ) throws {
      let evidence = try XCTUnwrap(plan.evidence, file: file, line: line)
      XCTAssertEqual(
        evidence.installerRecord,
        .partitions(plan.members.map { RemovalCreatedPartition(uuid: $0.uuid, type: $0.type) }),
        file: file, line: line)
      XCTAssertEqual(
        evidence.stubVolumeGroup, plan.installation?.system.group, file: file, line: line)
      XCTAssertFalse(evidence.stubHasLibrary, file: file, line: line)
      XCTAssertTrue(evidence.stubHasM1n1, file: file, line: line)
      XCTAssertEqual(evidence.stubEFIPartitions, [esp], file: file, line: line)
      XCTAssertEqual(plan.installation?.esp.uuid, esp.uppercased(), file: file, line: line)
    }

    private func assertReadOnly(
      _ mac: CapturedMac, file: StaticString = #filePath, line: UInt = #line
    ) {
      XCTAssertEqual(mac.refused, [], file: file, line: line)
      for argv in mac.log where !CapturedMac.isReadOnly(argv) {
        XCTFail("not read-only: \(argv)", file: file, line: line)
      }
    }
  }

  /// Answers the removal operator's seams from one capture. A command with no
  /// captured answer is refused and recorded.
  final class CapturedMac: @unchecked Sendable {
    let directory: URL
    /// What `bless --getBoot` prints instead of the captured answer.
    var startupDevice: String?
    let diskutilRefusesMount: Set<String>
    private(set) var log = [[String]]()
    private(set) var refused = [[String]]()
    private(set) var opened = [[String]]()
    private(set) var createdMountPoints = [String]()
    private var mounted = [String: String]()
    private var trees = [String: URL]()
    private var mountedInfo = [String: URL]()
    private let scratch: URL
    private let lock = NSLock()

    init(_ label: String, diskutilRefusesMount: Set<String> = []) throws {
      let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      directory = fixtures.appendingPathComponent("m1-pro-2026-09-28/\(label)")
      self.diskutilRefusesMount = diskutilRefusesMount
      scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "removal-replay-\(UUID())")
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      try prepareVolumes()
    }

    deinit {
      try? FileManager.default.removeItem(at: scratch)
      for path in createdMountPoints { _ = Darwin.rmdir(path) }
    }

    func makeOperator() -> MacRemovalDiskOperator {
      MacRemovalDiskOperator(
        commands: { try self.diskutil($0) }, targetType: { "J314s" },
        startupTools: { tool in
          switch tool {
          case .blessGetBoot:
            return try self.startupDevice.map { Data($0.utf8) } ?? self.file("bless-getboot.txt")
          case .nvramPrint:
            // Only names were captured; boot-volume is the value this Mac
            // printed on 2026-09-28 (macOS never moved between captures).
            let names = String(decoding: try self.file("nvram-names.txt"), as: UTF8.self)
            let bootVolume = String(
              decoding: try Data(
                contentsOf: self.directory.deletingLastPathComponent().appendingPathComponent(
                  "nvram-boot-volume.txt")), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(
              names.split(whereSeparator: \.isNewline).map {
                "\($0)\t\($0 == "boot-volume" ? bootVolume : "value")\n"
              }.joined().utf8)
          }
        },
        openTree: { try self.openTree($0, $1) },
        makeMountPoint: {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "removal-replay-mount-\(UUID())")
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
          self.lock.lock()
          defer { self.lock.unlock() }
          self.createdMountPoints.append(url.resolvingSymlinksInPath().path)
          return url
        },
        openFAT: { try self.openFAT($0, $1, $2) })
    }

    static func isReadOnly(_ argv: [String]) -> Bool {
      switch argv.first {
      case "info": return argv.count == 3 && argv[1] == "-plist"
      case "list": return argv == ["list", "-plist", "internal", "physical"]
      case "apfs":
        return argv == ["apfs", "list", "-plist"] || argv == ["apfs", "listVolumeGroups", "-plist"]
          || (argv.count == 5 && argv[1] == "resizeContainer"
            && argv[3...] == ["limits", "-plist"])
      case "mount": return argv.count == 6 && argv[1] == "readOnly"
      case "openFAT": return argv.count == 4
      case "unmount": return argv.count == 2
      default: return false
      }
    }

    func size(of identifier: String) throws -> UInt64 {
      let info = try plist(directory.appendingPathComponent("info/\(identifier).plist"))
      return try XCTUnwrap(info["Size"] as? NSNumber).uint64Value
    }

    private func diskutil(_ argv: [String]) throws -> Data {
      lock.lock()
      defer { lock.unlock() }
      log.append(argv)
      func refuse() -> RemovalFailure {
        refused.append(argv)
        return RemovalFailure(message: "no captured answer for \(argv.joined(separator: " "))")
      }
      switch argv {
      case ["info", "-plist", "/"]: return try file("info-root.plist")
      case ["list", "-plist", "internal", "physical"]: return try file("list.plist")
      case ["apfs", "list", "-plist"]: return try file("apfs-list.plist")
      case ["apfs", "listVolumeGroups", "-plist"]: return try file("apfs-volumegroups.plist")
      default: break
      }
      if argv.count == 3, argv[0] == "info", argv[1] == "-plist" {
        let identifier = argv[2]
        if let path = mounted[identifier], let captured = mountedInfo[identifier] {
          var info = try plist(captured)
          info["MountPoint"] = path
          return try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        }
        let url = directory.appendingPathComponent("info/\(identifier).plist")
        guard FileManager.default.fileExists(atPath: url.path) else { throw refuse() }
        return try Data(contentsOf: url)
      }
      let store = String(decoding: try file("macos-store.txt"), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if argv == ["apfs", "resizeContainer", store, "limits", "-plist"] {
        return try file("macos-limits.plist")
      }
      if argv.count == 6,
        Array(argv.prefix(4)) == ["mount", "readOnly", "nobrowse", "-mountPoint"],
        mountedInfo[argv[5]] != nil
      {
        if diskutilRefusesMount.contains(argv[5]) {
          throw RemovalFailure(message: "Volume on \(argv[5]) failed to mount")
        }
        mounted[argv[5]] = argv[4]
        return Data()
      }
      if argv.count == 2, argv[0] == "unmount", mounted.removeValue(forKey: argv[1]) != nil {
        return Data()
      }
      throw refuse()
    }

    /// Serves the captured files from a directory standing in for the volume,
    /// only at the mount point diskutil reports for it at that moment.
    private func openTree(_ mountPoint: String, _ device: String) throws -> RemovalFileTree {
      lock.lock()
      defer { lock.unlock() }
      opened.append([mountPoint, device])
      let captured = try plist(directory.appendingPathComponent("info/\(device).plist"))
      let reported = mounted[device] ?? captured["MountPoint"] as? String
      guard let tree = trees[device], mountPoint == reported else {
        throw RemovalFailure(message: "\(device) isn’t mounted at \(mountPoint)")
      }
      return try RemovalFileTree(
        descriptor: open(tree.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    /// Serves the EFI partition's captured files from a FAT32 image, only while
    /// diskutil reports it unmounted, with the geometry diskutil reported.
    private func openFAT(_ device: String, _ blockSize: Int, _ size: UInt64) throws
      -> any RemovalFileReading
    {
      lock.lock()
      defer { lock.unlock() }
      log.append(["openFAT", device, "\(blockSize)", "\(size)"])
      let info = try plist(directory.appendingPathComponent("info/\(device).plist"))
      guard let tree = trees[device], mounted[device] == nil,
        (info["MountPoint"] as? String ?? "").isEmpty,
        (info["DeviceBlockSize"] as? NSNumber)?.intValue == blockSize,
        (info["Size"] as? NSNumber)?.uint64Value == size
      else { throw RemovalFailure(message: "\(device) isn’t an unmounted EFI partition") }
      func file(_ path: String) throws -> Data? {
        let url = tree.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
      }
      let image = FATImageBuilder.esp(
        RemovalInstallFiles(
          espBootObject: try file("m1n1/boot.bin"), stubInfo: try file("asahi/stub_info.json"),
          installerLog: try file("asahi/installer.log"), stubHasLibrary: false,
          stubBootObject: nil))
      return try OmarchyRemovalFATVolumeTests.volume(image.data)
    }

    /// The EFI partition's asahi/ files were copied from it. Its m1n1/boot.bin
    /// wasn't (only its digest was recorded), and removal only needs it to exist,
    /// so a placeholder stands in. The startup container's top level is rebuilt
    /// from its captured listing, with the real Finish Installation.app boot.bin.
    private func prepareVolumes() throws {
      let evidence = directory.appendingPathComponent("evidence")
      guard FileManager.default.fileExists(atPath: evidence.path) else { return }
      for name in try FileManager.default.contentsOfDirectory(atPath: evidence.path) {
        let source = evidence.appendingPathComponent(name)
        let root = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if name.hasPrefix("esp-") {
          let device = String(name.dropFirst(4))
          try put(Data("m1n1 boot.bin placeholder".utf8), root, "m1n1/boot.bin")
          try put(
            Data(contentsOf: source.appendingPathComponent("asahi_stub_info.json")), root,
            "asahi/stub_info.json")
          try put(
            Data(contentsOf: source.appendingPathComponent("asahi_installer.log")), root,
            "asahi/installer.log")
          trees[device] = root
          mountedInfo[device] = source.appendingPathComponent("mounted.plist")
        } else if name.hasPrefix("stub-system-") {
          let listing = try String(
            contentsOf: source.appendingPathComponent("ls.txt"), encoding: .utf8)
          try rebuild(listing, in: root)
          try put(
            Data(contentsOf: source.appendingPathComponent("finish-boot.bin")), root,
            "Finish Installation.app/Contents/Resources/boot.bin")
          trees[String(name.dropFirst(12))] = root
        }
      }
    }

    /// Recreates the entries of an `ls -la` listing: directories, empty files
    /// and links to where the originals pointed.
    private func rebuild(_ listing: String, in root: URL) throws {
      let manager = FileManager.default
      for line in listing.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9, let kind = fields[0].first, "dl-".contains(kind) else { continue }
        let entry = fields[8].components(separatedBy: " -> ")
        guard entry[0] != ".", entry[0] != ".." else { continue }
        let url = root.appendingPathComponent(entry[0])
        switch kind {
        case "d": try manager.createDirectory(at: url, withIntermediateDirectories: true)
        case "l": try manager.createSymbolicLink(atPath: url.path, withDestinationPath: entry[1])
        default: try Data().write(to: url)
        }
      }
    }

    private func put(_ data: Data, _ root: URL, _ path: String) throws {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }

    private func file(_ name: String) throws -> Data {
      try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func plist(_ url: URL) throws -> [String: Any] {
      let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil)
      return try XCTUnwrap(value as? [String: Any])
    }
  }
#endif
