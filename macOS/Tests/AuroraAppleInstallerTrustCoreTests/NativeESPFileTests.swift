#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeESPFileTests: XCTestCase, @unchecked Sendable {
    /// The fixture's metadata, payload and locked ESP layout. `withObject: false`
    /// leaves out the payload's Mach-O Stage 1, as a payload from before it had.
    static func inputs(withObject: Bool = true) throws -> (Data, Data, [String: String]) {
      let url = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-firmware-selection-vectors",
          withExtension: "json", subdirectory: "Fixtures"))
      let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
      var metadata =
        try JSONSerialization.jsonObject(with: Data((document["completeMetadata"] as! String).utf8))
        as! [String: Any]
      var templates = metadata["os_list"] as! [[String: Any]]
      var rows = templates[0]["partitions"] as! [[String: Any]]
      rows[0]["size"] = "8MiB"
      templates[0]["partitions"] = rows
      metadata["os_list"] = templates
      let archive = try XCTUnwrap(Data(base64Encoded: document["completeArchive"] as! String))
      let payload = withObject ? try withStage1MachO(archive) : archive
      let reference = try XCTUnwrap(
        (document["boot"] as! [[String: Any]]).first {
          $0["name"] as? String == "j700ap-26.6.2-True-all"
        })
      let expected = reference["expected"] as! [String: Any]
      var layout = expected["layout"] as! [String: String]
      // The boot object goes to the ESP beside the common Stage 1.
      if withObject { layout["esp/aurora/stage1.macho"] = "aurora/stage1.macho" }
      return (try JSONSerialization.data(withJSONObject: metadata), payload, layout)
    }
    static let legacyBase = Data("synthetic legacy boot\0STACKBOT".utf8)

    /// Every Mac enrolls the boot object, so the fixture payload carries
    /// `esp/aurora/stage1.macho` for its common Stage 1, added by zip(1).
    static func withStage1MachO(_ payload: Data, optional: Bool = false) throws -> Data {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-fixture-macho-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("esp/aurora"), withIntermediateDirectories: true)
      let zip = directory.appendingPathComponent("payload.zip")
      try payload.write(to: zip)
      func run(_ tool: String, _ arguments: [String], output: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let output {
          FileManager.default.createFile(atPath: output.path, contents: nil)
          process.standardOutput = try FileHandle(forWritingTo: output)
        }
        if output != nil { process.standardError = FileHandle.nullDevice }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
      }
      let raw = directory.appendingPathComponent("esp/aurora/stage1.bin")
      let read = try run("/usr/bin/unzip", ["-p", zip.path, "esp/aurora/stage1.bin"], output: raw)
      // An archive without a common Stage 1 has nothing to wrap.
      if optional, try read != 0 || Data(contentsOf: raw).isEmpty { return payload }
      XCTAssertEqual(read, 0)
      try NativeMachOStage1Tests.object(wrapping: Data(contentsOf: raw)).write(
        to: directory.appendingPathComponent("esp/aurora/stage1.macho"))
      XCTAssertEqual(
        try run("/usr/bin/zip", ["-q", "-X", "-0", zip.path, "esp/aurora/stage1.macho"]), 0)
      return try Data(contentsOf: zip)
    }

    static func plan(deviceIdentifier: String = "apple,j700") async throws -> NativeESPPayloadPlan {
      let (metadata, payload, _) = try inputs()
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let result = try await NativeESPPayloadPlan.make(
        metadata: metadata, archive: archive, device: deviceIdentifier, firmware: "26.6.2",
        legacyStage1: { legacyBase })
      return try XCTUnwrap(result)
    }

    func testBoardMappingMatchesTheLockedBackendAndUnsafeFATNamesAreRefused() async throws {
      let result = try await Self.plan()
      let expected = try Self.inputs().2
      XCTAssertEqual(
        Dictionary(uniqueKeysWithValues: result.entries.map { ($0.member.name, $0.path) }), expected
      )
      for path in [
        "EFI/BOOT/BOOTAA64.EFI", "m1n1/boot.bin", "Aurora Installer.app/Contents/Info.plist",
      ] {
        XCTAssertTrue(NativeESPPayloadPlan.safeFATPath(path))
      }
      for path in [
        "../escape", "EFI/../escape", "/absolute", "EFI/name.", "EFI/name ", "EFI/a:b",
        "EFI/back\\slash", "EFI/é", String(repeating: "a", count: 256),
      ] {
        XCTAssertFalse(NativeESPPayloadPlan.safeFATPath(path), path)
      }
    }

    func testLegacyBootDoesNotWidenModernQualificationOrReplaceItsSelection() async throws {
      let modern = try await Self.plan()
      XCTAssertFalse(modern.usesLegacyStage1)
      let legacy = try await Self.plan(deviceIdentifier: "apple,j314s")
      XCTAssertTrue(legacy.usesLegacyStage1)
      XCTAssertEqual(legacy.stage1, Self.legacyBase)
      XCTAssertFalse(legacy.entries.contains { $0.member.name == "esp/aurora/stage1.bin" })
      let fixture = try await Fixture(deviceIdentifier: "apple,j314s")
      try await fixture.prepare()
      let receipt = try JSONDecoder().decode(
        NativeESPFilesExecution.Receipt.self, from: Data(contentsOf: fixture.receipt))
      let bootURL = fixture.images.base.mounts.appendingPathComponent(
        "disk8s1/Finish Installation.app/Contents/Resources/boot.bin")
      let raw = try Data(contentsOf: bootURL)
      try NativeLegacyStage1.verify(
        raw, receipt: XCTUnwrap(receipt.legacyStage1), uuid: receipt.espUUID.lowercased(),
        path: "m1n1/boot.bin")
      let filled = try NativeLegacyStage1.fill(
        Self.legacyBase, uuid: receipt.espUUID.lowercased(), path: "m1n1/boot.bin")
      XCTAssertEqual(raw, filled)
      let before = try Data(contentsOf: fixture.receipt)
      try await fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }

    func testLegacyExtraDownloadsAreKeptOutOfNativePublicationBeforeDiskWork() async throws {
      let (metadata, payload, _) = try Self.inputs()
      var document = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
      var templates = document["os_list"] as! [[String: Any]]
      templates[0]["extras"] = ["https://example.org/legacy-extra"]
      document["os_list"] = templates
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let result = try await NativeESPPayloadPlan.make(
        metadata: JSONSerialization.data(withJSONObject: document),
        archive: archive, device: "apple,j700", firmware: "26.6.2")
      XCTAssertNil(result)
      templates[0]["extras"] = "malformed"
      document["os_list"] = templates
      do {
        _ = try await NativeESPPayloadPlan.make(
          metadata: JSONSerialization.data(withJSONObject: document),
          archive: archive, device: "apple,j700", firmware: "26.6.2")
        XCTFail("Malformed extra-download contract admitted")
      } catch {}
    }

    func testNativeESPAndIconPublicationResumesWithoutChangingThePartitionMap() async throws {
      let fixture = try await Fixture()
      try await fixture.prepare()
      let before = try Data(contentsOf: fixture.receipt)
      let journal = try Data(contentsOf: fixture.images.base.journal)
      try await fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
      XCTAssertEqual(try Data(contentsOf: fixture.images.base.journal), journal)
      let receipt = try JSONDecoder().decode(NativeESPFilesExecution.Receipt.self, from: before)
      XCTAssertEqual(receipt.plan, fixture.images.base.approved.planDigest)
      XCTAssertEqual(receipt.files.count, fixture.plan.entries.count)
      for entry in fixture.plan.entries {
        let expected = try await fixture.plan.archive.read(entry.member, maximumBytes: 64 << 20)
        XCTAssertEqual(
          try Data(contentsOf: fixture.esp.appendingPathComponent(entry.path)), expected)
      }
      let system = fixture.images.base.mounts.appendingPathComponent("disk8s1")
      XCTAssertEqual(
        try Data(contentsOf: system.appendingPathComponent(".VolumeIcon.icns")).count,
        fixture.plan.icon.sizeBytes)
      let stage1 = try Data(
        contentsOf: system.appendingPathComponent(
          "Finish Installation.app/Contents/Resources/boot.bin"))
      XCTAssertEqual(
        stage1,
        try NativeBootChain.fillStage1(
          fixture.plan.stage1,
          uuid: receipt.espUUID.lowercased(), path: "m1n1/boot.bin",
          windowMilliseconds: fixture.plan.windowMilliseconds))
    }

    func testFATLabelAppearingOnMountPreservesTheApprovedLayout() async throws {
      let fixture = try await Fixture()
      fixture.labelOnMount = true
      try await fixture.prepare()
      let receipt = try Data(contentsOf: fixture.receipt)
      XCTAssertEqual(fixture.images.espLabel, "EFI - FEDOR")
      try await fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
    }

    func testChangedESPContentsOrRecordedLayoutCannotBeAdoptedOnRetry() async throws {
      for fault in ["contents", "layout", "owner"] {
        let fixture = try await Fixture()
        try await fixture.prepare()
        if fault == "layout" {
          fixture.images.changedSnapshot = true
        } else if fault == "owner" {
          fixture.images.changedOwner = true
        } else {
          let path = fixture.esp.appendingPathComponent("m1n1/boot.bin")
          let descriptor = open(path.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
          XCTAssertGreaterThanOrEqual(descriptor, 0)
          defer { close(descriptor) }
          try NativeRawImagePlatform.write(descriptor, Data([0xff]), 0)
        }
        do {
          try await fixture.prepare()
          XCTFail("Changed ESP was adopted: " + fault)
        } catch {}
      }
    }

    func testPublicationOnTheActualDisposableFATFilesystem() async throws {
      guard let path = ProcessInfo.processInfo.environment["AURORA_ESP_FAT_ROOT"] else {
        throw XCTSkip("The component controller supplies a disposable FAT volume")
      }
      let mount = URL(fileURLWithPath: path, isDirectory: true)
      var filesystem = statfs()
      XCTAssertEqual(statfs(mount.path, &filesystem), 0)
      let kind = withUnsafeBytes(of: filesystem.f_fstypename) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      XCTAssertEqual(kind, "msdos")
      let root = mount.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try NativeESPFileStore(
        root: mount, volumeDevice: "fixture",
        namespace: root.lastPathComponent, verifyMount: { _, _, _ in })
      let prefix = root.lastPathComponent + "/"
      let bytes = Data("verified native FAT publication".utf8)
      let identity = try await store.data(bytes, at: prefix + "EFI/BOOT/fixture.bin")
      XCTAssertEqual(try store.identity(prefix + "EFI/BOOT/fixture.bin"), identity)
      let repeated = try await store.data(bytes, at: prefix + "EFI/BOOT/fixture.bin")
      XCTAssertEqual(repeated, identity)
      do {
        _ = try await store.data(Data("conflicting".utf8), at: prefix + "EFI/BOOT/fixture.bin")
        XCTFail("FAT publication overwrote conflicting contents")
      } catch {}
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("EFI/BOOT/fixture.bin")), bytes)
      let newer = Data("verified replacement on FAT".utf8)
      let replaced = try await store.replaceData(
        newer, replacing: identity, at: prefix + "EFI/BOOT/fixture.bin")
      XCTAssertEqual(try store.identity(prefix + "EFI/BOOT/fixture.bin"), replaced.installed)
      XCTAssertEqual(try store.identity(replaced.backupPath), identity)
      let repeatedReplacement = try await store.replaceData(
        newer, replacing: identity, at: prefix + "EFI/BOOT/fixture.bin")
      XCTAssertEqual(repeatedReplacement, replaced)
    }

    func testVerifiedESPReplacementResumesAfterTheOldNameIsBackedUp() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-esp-replace-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try NativeESPFileStore(
        root: root, volumeDevice: "fixture", namespace: "preserved-test",
        verifyMount: { _, _, _ in }, admitFilesystem: { _ in })
      let path = "EFI/BOOT/BOOTAA64.EFI"
      let old = Data("old verified boot file".utf8)
      let next = Data("new verified boot file".utf8)
      let previous = try await store.data(old, at: path)
      let wrong = NativeStubFileIdentity(
        bytes: previous.bytes, sha256: String(repeating: "0", count: 64))
      do {
        _ = try await store.replaceData(next, replacing: wrong, at: path)
        XCTFail("An unverified old file was replaced")
      } catch {}
      XCTAssertEqual(try store.identity(path), previous)
      let names = store.replacementPaths(path)
      let (parent, leaf) = try store.tree.writableParent(path)
      defer { close(parent) }
      XCTAssertEqual(
        renameatx_np(parent, leaf, parent, names.backupLeaf, UInt32(RENAME_EXCL)), 0)
      XCTAssertEqual(fsync(parent), 0)

      let receipt = try await store.replaceData(next, replacing: previous, at: path)
      XCTAssertEqual(receipt.backupPath, names.backup)
      XCTAssertEqual(try store.identity(path), receipt.installed)
      XCTAssertEqual(try store.identity(names.backup), previous)
      let repeated = try await store.replaceData(next, replacing: previous, at: path)
      XCTAssertEqual(repeated, receipt)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(names.staged).path))

      try Data("changed backup".utf8).write(to: root.appendingPathComponent(names.backup))
      do {
        _ = try await store.replaceData(next, replacing: previous, at: path)
        XCTFail("Changed rollback file was adopted")
      } catch {}
      XCTAssertEqual(try store.identity(path), receipt.installed)
    }

    /// FSKit's msdos returns ENOTSUP for RENAME_EXCL onto an absent name.
    func testExclusiveRenameFallsBackWhereTheFilesystemRefusesTheFlag() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-esp-rename-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("staged".utf8).write(to: root.appendingPathComponent("staged"))
      try Data("taken".utf8).write(to: root.appendingPathComponent("taken"))
      let parent = open(root.path, O_RDONLY | O_DIRECTORY)
      XCTAssertGreaterThanOrEqual(parent, 0)
      defer { close(parent) }
      let unsupported: (Int32, String, Int32, String) -> Int32 = { _, _, _, _ in
        errno = ENOTSUP
        return -1
      }
      XCTAssertEqual(
        NativeESPFileStore.renameExclusive(parent, "staged", "taken", exclusive: unsupported), -1)
      XCTAssertEqual(errno, EEXIST)
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("taken")), Data("taken".utf8))
      XCTAssertEqual(
        NativeESPFileStore.renameExclusive(parent, "staged", "final", exclusive: unsupported), 0)
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("final")), Data("staged".utf8))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("staged").path))
      let failing: (Int32, String, Int32, String) -> Int32 = { _, _, _, _ in
        errno = EIO
        return -1
      }
      XCTAssertEqual(
        NativeESPFileStore.renameExclusive(parent, "final", "other", exclusive: failing), -1)
      XCTAssertEqual(errno, EIO)
    }

    final class Fixture: @unchecked Sendable {
      let images: NativePayloadImageTests.Fixture
      let plan: NativeESPPayloadPlan
      let esp: URL
      let receipt: URL
      var labelOnMount = false
      /// Every plan stages the payload's unpadded Mach-O Stage 1, as on M1 to M3.
      /// `machO` stages it padded for the execute window, as on M4 and later;
      /// `machOSource` wraps another raw image instead.
      init(
        deviceIdentifier: String = "apple,j700", machO: Bool = false,
        machOSource: ((Data) -> Data)? = nil
      ) async throws {
        let images = try await NativePayloadImageTests.Fixture(deviceIdentifier: deviceIdentifier)
        self.images = images
        try await images.prepare()
        var plan = try await NativeESPFileTests.plan(deviceIdentifier: deviceIdentifier)
        if machO || machOSource != nil {
          plan.stage1MachO = NativeMachOStage1Tests.object(
            wrapping: machOSource?(plan.stage1) ?? plan.stage1)
          plan.executeWindow = true
          // A real payload carries its own file; any member not otherwise installed stands in.
          if let member = plan.archive.members.first(where: { $0.name == "esp/m1n1/boot.bin" }) {
            plan.entries.append(.init(member: member, path: AuraStage1Format.confinedStage2Path))
          }
        }
        self.plan = plan
        esp = images.base.mounts.appendingPathComponent("disk0s5")
        try FileManager.default.createDirectory(
          at: esp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        receipt = URL(fileURLWithPath: images.base.journal.path + ".native-esp-files.evidence")
      }
      var environment: NativeHandoffEnvironment {
        let original = images.base.platform.environment
        let command = original.command
        let esp = self.esp
        let partition = images.base.snapshot.partitions.first { $0.identifier == "disk0s5" }!
        return NativeHandoffEnvironment(
          snapshot: original.snapshot, device: original.device,
          command: { executable, arguments in
            if arguments == ["info", "-plist", "disk0s5"] {
              if self.labelOnMount {
                self.images.espLabel = "EFI - FEDOR"
              }
              return try PropertyListSerialization.data(
                fromPropertyList: [
                  "DiskUUID": partition.uuid,
                  "MountPoint": esp.path, "Content": "EFI", "WritableVolume": true,
                ], format: .xml, options: 0)
            }
            return try command(executable, arguments)
          }, ownerUUID: original.ownerUUID, rawDigest: original.rawDigest,
          verifyRecovery: original.verifyRecovery, owner: original.owner,
          mountRoot: original.mountRoot, sourcePrebootMount: original.sourcePrebootMount,
          verifyMount: original.verifyMount)
      }
      func prepare() async throws {
        try await NativeESPFilesExecution(
          package: images.base.package, approved: images.base.approved,
          plan: plan, owner: geteuid(), environment: environment, disks: images.platform.disks,
          admitESPFilesystem: { _ in }
        )
        .prepare(
          journal: images.base.journal, authorization: images.base.authorization,
          sourceBootstrap: images.base.bootstrap)
      }
    }
  }
#endif
