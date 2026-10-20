#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedPayloadImagesTests: XCTestCase, @unchecked Sendable {
    func testExistingBootAndRootRewriteResumeFromVerifiedReceipts() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-preserved-images-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
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
      let archive = try await IPSWArchive.open(
        NativeRawImageWriterTests.Source(bytes: NativeRawImageWriterTests.source()))
      let bootMember = try XCTUnwrap(archive.members.first { $0.name == "boot.img" })
      let rootMember = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      let espPlan = try await NativeESPFileTests.plan()
      let prepared = NativePreservedInstallAdmission.Prepared(
        target: target, diskSnapshot: baseline, transcript: transcript, archive: archive,
        boot: bootMember, root: rootMember, esp: espPlan,
        stage1: NativeStubFileIdentity(bytes: 1, sha256: String(repeating: "0", count: 64)))
      let bootFile = try NativeRawImageWriterTests.Target(capacity: boot.size)
      let rootFile = try NativeRawImageWriterTests.Target(capacity: linuxRoot.size)
      let targets = [boot.identifier: bootFile, linuxRoot.identifier: rootFile]
      let bootstrap = try NativeSourceBootstrap(
        systemUUID: UUID().uuidString, groupUUID: UUID().uuidString,
        ownerUUID: UUID().uuidString)
      let platform = NativePayloadImagePlatform(
        disks: NativeAPFSPlatform(
          collect: { throw NativePreservedInstallError.changedLayout },
          snapshot: { baseline },
          verifyPartition: { partition, disk in
            guard disk == baseline.disk,
              baseline.partitions.contains(where: {
                $0.identifier == partition.identifier && $0 == partition
              })
            else { throw NativePreservedInstallError.changedLayout }
          },
          verifySourceOwner: { _, _, expected in
            guard expected == bootstrap else { throw NativeHandoffValidationError.invalidOwner }
          },
          command: { _ in throw NativePreservedInstallError.changedLayout },
          containerReference: { _, _ in throw NativePreservedInstallError.changedLayout }),
        writer: NativeRawImagePlatform(
          openTarget: { partition in
            guard let target = targets[partition.identifier] else {
              throw NativeRawImageError.invalidTarget
            }
            return try target.platform.openTarget(partition)
          }, writeChunk: NativeRawImagePlatform.write,
          flush: { descriptor in
            guard fsync(descriptor) == 0 else { throw NativeRawImageError.flushFailed }
          }),
        digest: { identifier, count in
          guard let target = targets[identifier] else { throw NativeRawImageError.invalidTarget }
          let bytes = try Data(contentsOf: target.url).prefix(Int(count))
          return NativeStubFileStore.hash(Data(bytes))
        })
      let writer = NativePreservedPayloadImagesExecution(
        package: package, approved: approved, prepared: prepared, platform: platform)
      let authorization = try MachineOwnerAuthorization(
        username: "mina", password: Data("synthetic".utf8))

      let first = try await writer.prepare(
        journal: journal, authorization: authorization, bootstrap: bootstrap)
      XCTAssertEqual(first.boot.partitionUUID, boot.uuid.lowercased())
      XCTAssertEqual(first.root.partitionUUID, linuxRoot.uuid.lowercased())
      XCTAssertEqual(bootFile.opened, 1)
      XCTAssertEqual(rootFile.opened, 1)
      let repeated = try await writer.prepare(
        journal: journal, authorization: authorization, bootstrap: bootstrap)
      XCTAssertEqual(repeated.boot, first.boot)
      XCTAssertEqual(repeated.root, first.root)
      XCTAssertEqual(bootFile.opened, 1)
      XCTAssertEqual(rootFile.opened, 1)

      try FileManager.default.removeItem(
        at: URL(fileURLWithPath: journalURL.path + ".preserved-image-root.evidence"))
      _ = try await writer.prepare(
        journal: journal, authorization: authorization, bootstrap: bootstrap)
      XCTAssertEqual(bootFile.opened, 1)
      XCTAssertEqual(rootFile.opened, 2)
      let descriptor = open(bootFile.url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { close(descriptor) }
      try NativeRawImagePlatform.write(descriptor, Data([0xff]), 0)
      do {
        _ = try await writer.prepare(
          journal: journal, authorization: authorization, bootstrap: bootstrap)
        XCTFail("Changed Boot contents were adopted")
      } catch {}
      XCTAssertEqual(bootFile.opened, 1)
    }
  }
#endif
