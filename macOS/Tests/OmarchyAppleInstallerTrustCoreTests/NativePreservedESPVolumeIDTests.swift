#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedESPVolumeIDTests: XCTestCase, @unchecked Sendable {
    /// A disposable image file standing in for the raw ESP partition of a
    /// disk with 4 KiB blocks.
    final class Device: @unchecked Sendable {
      let directory: URL
      let url: URL
      var opened = 0
      var writable = 0
      var flushed = 0
      var mounted = false

      init(_ image: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("disposable-esp")
        try image.write(to: url)
      }
      deinit { try? FileManager.default.removeItem(at: directory) }

      var bytes: Data { (try? Data(contentsOf: url)) ?? Data() }
      func replace(with image: Data) throws { try image.write(to: url) }

      var platform: NativeESPVolumeIDPlatform {
        NativeESPVolumeIDPlatform(
          openTarget: { _, writable in
            self.opened += 1
            if writable { self.writable += 1 }
            let descriptor = open(
              self.url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw NativeRawImageError.invalidTarget }
            return (descriptor, 4096)
          },
          flush: { descriptor in
            self.flushed += 1
            guard fsync(descriptor) == 0 else { throw NativeRawImageError.flushFailed }
          },
          mounted: { _ in self.mounted })
      }
    }

    struct Fixture {
      let journal: NativePreservedInstallJournal
      let prepared: NativePreservedInstallAdmission.Prepared
      let execution: NativePreservedESPVolumeIDExecution
      let capacity: NativePreservedESPCapacity
      let device: Device
      let espUUID: String
      let authorization: MachineOwnerAuthorization
      let bootstrap: NativeSourceBootstrap

      func prepare() throws {
        try execution.prepare(
          journal: journal, authorization: authorization, bootstrap: bootstrap)
      }

      func restore() throws {
        try execution.restore(
          journal: journal, authorization: authorization, bootstrap: bootstrap)
      }
    }

    static let espBytes = 8 << 20

    /// An ESP formatted the way a fresh install formats one on 4 KiB-sector
    /// storage: boot sector 0, FSInfo 1, backup boot sector 6. Linux marks
    /// only the primary boot sector while the volume is mounted.
    static func image(
      serial: UInt32, sectorBytes: Int = 4096, type: String = "FAT32   ",
      backupSector: Int = 6, dirty: Bool = true
    ) -> Data {
      let sectors = espBytes / sectorBytes
      var boot = [UInt8](repeating: 0, count: sectorBytes)
      func put(_ value: Int, at offset: Int, bytes count: Int) {
        for index in 0..<count {
          boot[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
      }
      boot.replaceSubrange(0..<11, with: [0xEB, 0x58, 0x90] + Array("BSD4.4  ".utf8))
      put(sectorBytes, at: 0x0B, bytes: 2)
      boot[0x0D] = 1
      put(32, at: 0x0E, bytes: 2)
      boot[0x10] = 2
      boot[0x15] = 0xF8
      put(32, at: 0x18, bytes: 2)
      put(255, at: 0x1A, bytes: 2)
      put(sectors, at: 0x20, bytes: 4)
      put(((sectors + 2) * 4 + sectorBytes - 1) / sectorBytes, at: 0x24, bytes: 4)
      put(2, at: 0x2C, bytes: 4)
      put(1, at: 0x30, bytes: 2)
      put(backupSector, at: 0x32, bytes: 2)
      boot[0x40] = 0x80
      boot[0x42] = 0x29
      put(Int(serial), at: 0x43, bytes: 4)
      boot.replaceSubrange(0x47..<0x52, with: Array("EFI - OMARC".utf8))
      boot.replaceSubrange(0x52..<0x5A, with: Array(type.utf8))
      boot[510] = 0x55
      boot[511] = 0xAA
      var information = [UInt8](repeating: 0, count: sectorBytes)
      information.replaceSubrange(0..<4, with: Array("RRaA".utf8))
      information.replaceSubrange(484..<488, with: Array("rrAa".utf8))
      information.replaceSubrange(488..<496, with: [UInt8](repeating: 0xFF, count: 8))
      information.replaceSubrange(510..<512, with: [0x55, 0xAA])
      var image = Data(count: espBytes)
      for (sector, bytes) in [(1, information), (7, information), (backupSector, boot)] {
        image.replaceSubrange(sector * sectorBytes..<(sector + 1) * sectorBytes, with: bytes)
      }
      if dirty { boot[0x41] = 1 }
      image.replaceSubrange(0..<sectorBytes, with: boot)
      return image
    }

    /// The same ESP with a working FAT: the root directory, `bootBin` at
    /// m1n1/boot.bin when given, and `used` more allocated clusters.
    static func formatted(used: Int, bootBin: Data? = nil) -> Data {
      var bytes = image(serial: 0x4866_D833, dirty: false)
      func link(_ cluster: Int, to value: UInt32) {
        for index in 0..<4 {
          bytes[32 * 4096 + cluster * 4 + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
      }
      func data(_ cluster: Int) -> Int { (38 + cluster - 2) * 4096 }
      func entry(_ name: String, directory: Bool, first: Int, size: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<offset + 11, with: Array(name.utf8))
        bytes[offset + 11] = directory ? 0x10 : 0x20
        bytes[offset + 26] = UInt8(first & 0xFF)
        bytes[offset + 27] = UInt8(first >> 8 & 0xFF)
        for index in 0..<4 {
          bytes[offset + 28 + index] = UInt8(truncatingIfNeeded: size >> (8 * index))
        }
      }
      link(0, to: 0x0FFF_FFF8)
      link(1, to: 0x0FFF_FFFF)
      link(2, to: 0x0FFF_FFFF)
      var next = 3
      if let bootBin {
        entry("M1N1       ", directory: true, first: 3, size: 0, at: data(2))
        link(3, to: 0x0FFF_FFFF)
        entry("BOOT    BIN", directory: false, first: 4, size: bootBin.count, at: data(3))
        let clusters = max(1, (bootBin.count + 4095) / 4096)
        for cluster in 4..<4 + clusters {
          link(cluster, to: cluster == 3 + clusters ? 0x0FFF_FFFF : UInt32(cluster + 1))
        }
        bytes.replaceSubrange(data(4)..<data(4) + bootBin.count, with: bootBin)
        next = 4 + clusters
      }
      for cluster in next..<next + used { link(cluster, to: 0x0FFF_FFFF) }
      return bytes
    }

    static func setting(_ serial: UInt32, sectors: [Int], in image: Data) -> Data {
      var image = image
      for sector in sectors {
        for index in 0..<4 {
          image[sector * 4096 + 0x43 + index] = UInt8(truncatingIfNeeded: serial >> (8 * index))
        }
      }
      return image
    }

    private func makeFixture(image: Data, volumeID: UInt32?) async throws -> Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-preserved-esp-volume-id-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let journalDirectory = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(
        at: journalDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let binding = "sha256:" + String(repeating: "3", count: 64)
      let journalURL = journalDirectory.appendingPathComponent(
        String(binding.dropFirst(7)) + ".jsonl")
      try Data().write(to: journalURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
      let (transcript, approved) = try NativePreservedInstallJournalTests.transcript()
      let package = ImportedEngineHandoffPackage(
        packageURL: root, manifestURL: root.appendingPathComponent("manifest.json"),
        requestURL: root.appendingPathComponent("request.json"),
        identityURL: root.appendingPathComponent("identity.json"),
        engineURL: root.appendingPathComponent("engine"),
        metadataURL: root.appendingPathComponent("metadata"),
        payloadURL: root.appendingPathComponent("payload"),
        bindingDigest: binding, planDigest: approved.planDigest,
        deviceIdentifier: approved.deviceIdentifier, storeIdentifier: approved.storeIdentifier,
        installationIntent: .reinstall)
      let journal = try NativePreservedInstallJournal(
        url: journalURL, package: package, transcript: transcript, owner: geteuid())
      try journal.bindInstallConf(InstallConf(encrypt: false, lane: "edge"))
      let stub = RemovalPartition(
        identifier: "disk0s3", uuid: UUID().uuidString, type: "Apple_APFS",
        offset: 4096, size: 1 << 20, name: "Aurora NixOS")
      let esp = RemovalPartition(
        identifier: "disk0s4", uuid: UUID().uuidString, type: "EFI",
        offset: stub.end, size: UInt64(Self.espBytes), name: "EFI - AUROR")
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
      let baseline = RemovalSnapshot(
        disk: "disk0", devicePath: "/dev/disk0", diskSize: 64 << 20,
        macOSStoreUUID: UUID().uuidString, macOSContainerUUID: UUID().uuidString,
        partitions: [stub, esp, boot, linuxRoot],
        containers: [
          RemovalContainer(uuid: UUID().uuidString, storeUUID: stub.uuid, volumes: [system])
        ])
      let target = NativePreservedInstallTarget(
        disk: "disk0", title: "Aurora NixOS", group: group,
        stub: stub, esp: esp, boot: boot, root: linuxRoot,
        identityDigest: "sha256:" + String(repeating: "a", count: 64))
      let archive = try await IPSWArchive.open(
        NativeRawImageWriterTests.Source(bytes: NativeRawImageWriterTests.source()))
      let bootMember = try XCTUnwrap(archive.members.first { $0.name == "boot.img" })
      let rootMember = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      let espPlan = try await NativeESPFileTests.plan()
      let prepared = NativePreservedInstallAdmission.Prepared(
        target: target, diskSnapshot: baseline, transcript: transcript, archive: archive,
        boot: bootMember, root: rootMember, esp: espPlan, espVolumeID: volumeID,
        stage1: NativeStubFileIdentity(bytes: 1, sha256: String(repeating: "0", count: 64)))
      let bootstrap = try NativeSourceBootstrap(
        systemUUID: UUID().uuidString, groupUUID: UUID().uuidString,
        ownerUUID: UUID().uuidString)
      let disks = NativeAPFSPlatform(
        collect: { throw NativePreservedInstallError.changedLayout },
        snapshot: { baseline },
        verifyPartition: { partition, disk in
          guard disk == baseline.disk, partition.identifier == esp.identifier, partition == esp
          else { throw NativePreservedInstallError.changedLayout }
        },
        verifySourceOwner: { _, _, expected, _ in
          guard expected == bootstrap else { throw NativeHandoffValidationError.invalidOwner }
        },
        command: { _ in throw NativePreservedInstallError.changedLayout },
        containerReference: { _, _ in throw NativePreservedInstallError.changedLayout })
      let device = try Device(image)
      let authorization = try MachineOwnerAuthorization(
        username: "mina", password: Data("synthetic".utf8))
      return Fixture(
        journal: journal, prepared: prepared,
        execution: NativePreservedESPVolumeIDExecution(
          package: package, approved: approved, prepared: prepared,
          disks: disks, device: device.platform),
        capacity: NativePreservedESPCapacity(
          prepared: prepared, disks: disks, device: device.platform),
        device: device, espUUID: esp.uuid, authorization: authorization, bootstrap: bootstrap)
    }

    func testMismatchedSerialIsWrittenToBothBootSectors() async throws {
      let original = Self.image(serial: 0x4F4D_5801)
      let fixture = try await makeFixture(image: original, volumeID: 0x4866_D833)
      try fixture.execution.admit(journal: fixture.journal)
      try fixture.journal.begin()
      try fixture.prepare()
      var expected = original
      for sector in [0, 6] {
        expected.replaceSubrange(
          sector * 4096 + 0x43..<sector * 4096 + 0x47, with: [0x33, 0xD8, 0x66, 0x48])
      }
      XCTAssertEqual(fixture.device.bytes, expected)
      XCTAssertEqual(fixture.device.bytes[0x41], 1)
      XCTAssertEqual(fixture.device.writable, 1)
      XCTAssertEqual(fixture.device.flushed, 1)
      let recorded = NativePreservedESPVolumeID(
        partitionUUID: fixture.espUUID.lowercased(), previous: 0x4F4D_5801,
        installed: 0x4866_D833)
      XCTAssertEqual(try fixture.journal.espVolumeIDBaseline(), recorded)
      XCTAssertEqual(try fixture.journal.espVolumeIDReceipt(), recorded)
    }

    func testMatchingSerialIsNeverWritten() async throws {
      let original = Self.image(serial: 0x4866_D833)
      let fixture = try await makeFixture(image: original, volumeID: 0x4866_D833)
      // Reading through a mounted ESP is harmless when nothing is written.
      fixture.device.mounted = true
      try fixture.execution.admit(journal: fixture.journal)
      try fixture.journal.begin()
      try fixture.prepare()
      try fixture.prepare()
      try fixture.restore()
      XCTAssertEqual(fixture.device.bytes, original)
      XCTAssertGreaterThan(fixture.device.opened, 0)
      XCTAssertEqual(fixture.device.writable, 0)
      XCTAssertEqual(fixture.device.flushed, 0)
      XCTAssertEqual(
        try fixture.journal.espVolumeIDReceipt(),
        NativePreservedESPVolumeID(
          partitionUUID: fixture.espUUID.lowercased(), previous: 0x4866_D833,
          installed: 0x4866_D833))
    }

    func testNonFAT32OrInconsistentBootSectorsAreRefusedWithoutAWrite() async throws {
      let original = Self.image(serial: 0x4F4D_5801)
      let backup = 6 * 4096
      func changed(_ offsets: [Int], to value: UInt8) -> Data {
        var image = original
        for offset in offsets { image[offset] = value }
        return image
      }
      let faults: [(String, Data)] = [
        ("FAT16 type", Self.image(serial: 0x4F4D_5801, type: "FAT16   ")),
        ("sector smaller than a device block", Self.image(serial: 0x4F4D_5801, sectorBytes: 512)),
        ("no backup boot sector", Self.image(serial: 0x4F4D_5801, backupSector: 0)),
        ("backup on the FSInfo sector", Self.image(serial: 0x4F4D_5801, backupSector: 1)),
        ("backup past the reserved sectors", Self.image(serial: 0x4F4D_5801, backupSector: 40)),
        ("no extended boot signature", changed([0x42, backup + 0x42], to: 0x28)),
        ("no boot sector signature", changed([510, backup + 510], to: 0)),
        ("different backup label", changed([backup + 0x47], to: 0x58)),
        ("different backup serial", changed([backup + 0x43], to: 0)),
        ("different backup state", changed([backup + 0x41], to: 2)),
        ("different backup tail", changed([backup + 4095], to: 1)),
        ("not a FAT file system", Data(repeating: 0xCC, count: Self.espBytes)),
      ]
      let fixture = try await makeFixture(image: original, volumeID: 0x4866_D833)
      try fixture.journal.begin()
      for (name, image) in faults {
        try fixture.device.replace(with: image)
        XCTAssertThrowsError(try fixture.execution.admit(journal: fixture.journal), name)
        XCTAssertThrowsError(try fixture.prepare(), name)
        XCTAssertEqual(fixture.device.bytes, image, name)
      }
      try fixture.device.replace(with: original)
      fixture.device.mounted = true
      XCTAssertThrowsError(try fixture.execution.admit(journal: fixture.journal)) {
        XCTAssertEqual($0 as? NativeESPVolumeIDError, .mounted)
      }
      XCTAssertThrowsError(try fixture.prepare()) {
        XCTAssertEqual($0 as? NativeESPVolumeIDError, .mounted)
      }
      XCTAssertEqual(fixture.device.bytes, original)
      XCTAssertEqual(fixture.device.writable, 0)
      XCTAssertNil(try fixture.journal.espVolumeIDBaseline())
      XCTAssertNil(try fixture.journal.espVolumeIDReceipt())
    }

    func testRetryAndRollbackRestoreThePreviousSerial() async throws {
      let original = Self.image(serial: 0x4F4D_5801)
      let fixture = try await makeFixture(image: original, volumeID: 0x4866_D833)
      try fixture.journal.begin()
      // An interrupted first attempt journaled the previous serial and wrote
      // only the backup boot sector.
      let recorded = NativePreservedESPVolumeID(
        partitionUUID: fixture.espUUID.lowercased(), previous: 0x4F4D_5801,
        installed: 0x4866_D833)
      try fixture.journal.recordESPVolumeIDBaseline(recorded)
      let partial = Self.setting(0x4866_D833, sectors: [6], in: original)
      try fixture.device.replace(with: partial)
      try fixture.execution.admit(journal: fixture.journal)
      try fixture.prepare()
      let installed = Self.setting(0x4866_D833, sectors: [0, 6], in: original)
      XCTAssertEqual(fixture.device.bytes, installed)
      XCTAssertEqual(fixture.device.writable, 1)
      XCTAssertEqual(try fixture.journal.espVolumeIDReceipt(), recorded)

      try fixture.execution.admit(journal: fixture.journal)
      try fixture.prepare()
      XCTAssertEqual(fixture.device.bytes, installed)
      XCTAssertEqual(fixture.device.writable, 1)

      try fixture.restore()
      XCTAssertEqual(fixture.device.bytes, original)
      XCTAssertEqual(fixture.device.writable, 2)
      try fixture.restore()
      XCTAssertEqual(fixture.device.writable, 2)
      // The journal says the payload serial was written; a restored ESP is
      // not silently adopted again.
      XCTAssertThrowsError(try fixture.prepare())
      XCTAssertEqual(fixture.device.bytes, original)

      // A rollback interrupted between the two sectors resumes too.
      try fixture.device.replace(with: Self.setting(0x4F4D_5801, sectors: [6], in: installed))
      try fixture.restore()
      XCTAssertEqual(fixture.device.bytes, original)
      XCTAssertEqual(fixture.device.writable, 3)

      // A serial neither journaled value names is never overwritten.
      let foreign = Self.setting(0x1234_5678, sectors: [0, 6], in: original)
      try fixture.device.replace(with: foreign)
      XCTAssertThrowsError(try fixture.restore())
      XCTAssertThrowsError(try fixture.prepare())
      XCTAssertEqual(fixture.device.bytes, foreign)
      XCTAssertEqual(fixture.device.writable, 3)
    }

    func testPayloadWithoutVolumeIDLeavesTheESPAlone() async throws {
      let original = Data(repeating: 0xCC, count: Self.espBytes)
      let fixture = try await makeFixture(image: original, volumeID: nil)
      try fixture.execution.admit(journal: fixture.journal)
      try fixture.journal.begin()
      try fixture.prepare()
      try fixture.restore()
      XCTAssertEqual(fixture.device.opened, 0)
      XCTAssertEqual(fixture.device.bytes, original)
      XCTAssertNil(try fixture.journal.espVolumeIDBaseline())
      XCTAssertNil(try fixture.journal.espVolumeIDReceipt())
    }

    func testSmallerKeptESPIsAdmittedOnlyWithRoomForThePayloadAndRollbackCopies() async throws {
      let fixture = try await makeFixture(image: Self.formatted(used: 0), volumeID: 0x4866_D833)
      let conf = try InstallConf(encrypt: false, lane: "edge")
      var files = [(path: String, bytes: Data)]()
      for entry in fixture.prepared.esp.entries {
        let bytes = try await fixture.prepared.esp.archive.read(
          entry.member, maximumBytes: 64 << 20)
        files.append((entry.path, bytes))
      }
      files.append((InstallConf.relativePath, conf.serializedData))
      func cost(_ bytes: Data) -> UInt64 { UInt64((bytes.count + 4095) / 4096 * 4096 + 4096) }
      let required = files.reduce(UInt64(0)) { $0 + cost($1.bytes) }
      // The 8 MiB ESP is far smaller than the image's, yet has room to spare.
      try await fixture.capacity.admit(installConf: conf)
      // Exactly enough room is enough; one cluster less is refused.
      let unused = 2010 - 1
      try fixture.device.replace(with: Self.formatted(used: unused - Int(required / 4096)))
      try await fixture.capacity.admit(installConf: conf)
      let full = Self.formatted(used: unused - Int(required / 4096) + 1)
      try fixture.device.replace(with: full)
      do {
        try await fixture.capacity.admit(installConf: conf)
        XCTFail("An ESP without room for the payload was admitted")
      } catch {
        XCTAssertEqual(
          error as? NativePreservedInstallError,
          .espFull(requiredBytes: required, availableBytes: required - 4096))
        let summary = try XCTUnwrap(PinnedAsahiEngineExecutor.preservedSummary(for: error))
        XCTAssertTrue(summary.hasPrefix("The EFI partition has "), summary)
        XCTAssertLessThanOrEqual(summary.count, EngineFailureNotice.maximumSummaryCharacters)
      }
      XCTAssertEqual(fixture.device.bytes, full)
      XCTAssertEqual(fixture.device.writable, 0)

      // A file already identical to the payload needs no room; the file a
      // payload member replaces stays as its rollback copy and frees none.
      func volume(_ image: Data) throws -> RemovalFATVolume {
        try RemovalFATVolume(size: UInt64(image.count)) { offset, count in
          image.subdata(in: Int(offset)..<Int(offset) + count)
        }
      }
      let boot = try XCTUnwrap(files.first { $0.path == "m1n1/boot.bin" }).bytes
      let same = try volume(Self.formatted(used: 0, bootBin: boot))
      let other = try volume(Self.formatted(used: 0, bootBin: boot + Data([0])))
      XCTAssertEqual(
        try NativePreservedESPCapacity.requiredBytes(files, on: same), required - cost(boot))
      XCTAssertEqual(try NativePreservedESPCapacity.requiredBytes(files, on: other), required)
      XCTAssertEqual(
        try volume(Self.formatted(used: 0)).freeBytes()
          - other.freeBytes(), UInt64(1 + (boot.count + 4096) / 4096) * 4096)
    }

    func testPayloadVolumeIDIsReadAsAFreshInstallFormatsIt() {
      XCTAssertEqual(NativeFATBootSectors.serial(volumeID: "0x4866d833"), 0x4866_D833)
      XCTAssertEqual(NativeFATBootSectors.serial(volumeID: "0X4F4D5801"), 0x4F4D_5801)
      XCTAssertEqual(NativeFATBootSectors.serial(volumeID: "1234"), 1234)
      XCTAssertEqual(NativeFATBootSectors.serial(volumeID: "017"), 0o17)
      XCTAssertEqual(NativeFATBootSectors.serial(volumeID: "0"), 0)
      for text in ["4866D833", "0x", "08", "0x123456789", "", "+1", "-1"] {
        XCTAssertNil(NativeFATBootSectors.serial(volumeID: text), text)
      }
    }
  }
#endif
