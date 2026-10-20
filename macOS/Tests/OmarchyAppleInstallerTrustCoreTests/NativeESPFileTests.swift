#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeESPFileTests: XCTestCase, @unchecked Sendable {
    static func inputs() throws -> (Data, Data, [String: String]) {
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
      let payload = try XCTUnwrap(Data(base64Encoded: document["completeArchive"] as! String))
      let reference = try XCTUnwrap(
        (document["boot"] as! [[String: Any]]).first {
          $0["name"] as? String == "j700ap-26.6.2-True-all"
        })
      let expected = reference["expected"] as! [String: Any]
      return (
        try JSONSerialization.data(withJSONObject: metadata), payload,
        expected["layout"] as! [String: String]
      )
    }
    static func plan() async throws -> NativeESPPayloadPlan {
      let (metadata, payload, _) = try inputs()
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let result = try await NativeESPPayloadPlan.make(
        metadata: metadata, archive: archive, device: "apple,j700", firmware: "26.6.2")
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
    }

    final class Fixture: @unchecked Sendable {
      let images: NativePayloadImageTests.Fixture
      let plan: NativeESPPayloadPlan
      let esp: URL
      let receipt: URL
      init() async throws {
        let images = try await NativePayloadImageTests.Fixture()
        self.images = images
        try await images.prepare()
        plan = try await NativeESPFileTests.plan()
        esp = images.base.mounts.appendingPathComponent("disk0s5")
        try FileManager.default.createDirectory(
          at: esp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        receipt = URL(fileURLWithPath: images.base.journal.path + ".native-esp-files.evidence")
      }
      func prepare() async throws {
        let original = images.base.platform.environment
        let command = original.command
        let esp = self.esp
        let partition = images.base.snapshot.partitions.first { $0.identifier == "disk0s5" }!
        let environment = NativeHandoffEnvironment(
          snapshot: original.snapshot, device: original.device,
          command: { executable, arguments in
            if arguments == ["info", "-plist", "disk0s5"] {
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
