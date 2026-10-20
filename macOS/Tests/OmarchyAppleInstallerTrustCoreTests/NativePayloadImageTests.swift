#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePayloadImageTests: XCTestCase, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
      let base: NativeStubFileTests.ExecutionFixture
      let archive: IPSWArchive
      let members: [IPSWArchiveMember]
      let targets: [String: NativeRawImageWriterTests.Target]
      var opened = 0
      var changedOwner = false
      var changedSnapshot = false
      var espLabel: String?
      init(deviceIdentifier: String = "apple,j700") async throws {
        let base = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: deviceIdentifier)
        self.base = base
        let archive = try await IPSWArchive.open(
          NativeRawImageWriterTests.Source(bytes: NativeRawImageWriterTests.source()))
        self.archive = archive
        members = try ["boot.img", "root.img"].map { name in
          try XCTUnwrap(archive.members.first { $0.name == name })
        }
        let stub = try XCTUnwrap(
          base.snapshot.partitions.first { $0.offset == base.approved.offsetBytes })
        let parts = base.snapshot.partitions.filter {
          $0.offset >= stub.end && $0.offset < base.approved.offsetBytes + base.approved.lengthBytes
        }.sorted { $0.offset < $1.offset }
        var original = base.snapshot
        let created = Set(parts.map(\.uuid))
        original.partitions.removeAll { created.contains($0.uuid) }
        let baselinePath = URL(
          fileURLWithPath: base.journal.path + ".native-os-partition-baseline.evidence")
        try JSONEncoder().encode(original).write(to: baselinePath)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: baselinePath.path)
        let layout = try NativeOSPartitionPlan(
          metadata: NativeOSPartitionTests.metadata(),
          available: base.approved.lengthBytes - stub.size)
        let receipt = NativeOSPartitionsExecution.Receipt(
          plan: base.approved.planDigest,
          stubUUID: stub.uuid, layout: layout, partitions: parts)
        let path = URL(fileURLWithPath: base.journal.path + ".native-os-partitions.evidence")
        try JSONEncoder().encode(receipt).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var targets = [String: NativeRawImageWriterTests.Target]()
        for partition in parts.dropFirst() {
          targets[partition.identifier] = try .init(capacity: partition.size)
        }
        self.targets = targets
      }
      deinit { try? FileManager.default.removeItem(at: base.directory) }
      var platform: NativePayloadImagePlatform {
        NativePayloadImagePlatform(
          disks: NativeAPFSPlatform(
            collect: { throw NativeOSPartitionError.changedLayout },
            snapshot: {
              var snapshot = self.base.snapshot
              if let label = self.espLabel,
                let index = snapshot.partitions.firstIndex(where: { $0.type == "EFI" })
              {
                let old = snapshot.partitions[index]
                snapshot.partitions[index] = RemovalPartition(
                  identifier: old.identifier, uuid: old.uuid, type: old.type,
                  offset: old.offset, size: old.size, name: label)
              }
              if self.changedSnapshot { snapshot.partitions[1].size -= 4096 }
              return snapshot
            },
            verifyPartition: { partition, disk in
              XCTAssertEqual(disk, self.base.snapshot.disk)
              XCTAssertTrue(
                self.base.snapshot.partitions.contains {
                  $0.identifier == partition.identifier
                    && NativeESPLabelAdmission.matches(
                      partition, saved: $0, label: self.espLabel)
                })
            },
            verifySourceOwner: { _, _, bootstrap in
              XCTAssertEqual(bootstrap, self.base.bootstrap)
              if self.changedOwner { throw NativeHandoffValidationError.invalidOwner }
            }, command: { _ in XCTFail("Image stage must never run disk commands") },
            containerReference: { _, _ in throw NativeOSPartitionError.changedLayout }),
          writer: NativeRawImagePlatform(
            openTarget: { partition in
              self.opened += 1
              return try XCTUnwrap(self.targets[partition.identifier]).platform.openTarget(
                partition)
            }, writeChunk: NativeRawImagePlatform.write,
            flush: { descriptor in
              guard fsync(descriptor) == 0 else { throw NativeRawImageError.flushFailed }
            }),
          digest: { partition, count in
            let data = try Data(contentsOf: XCTUnwrap(self.targets[partition]).url).prefix(
              Int(count))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          })
      }
      func prepare() async throws {
        try await NativePayloadImagesExecution(
          package: base.package, approved: base.approved,
          archive: archive, members: members, owner: geteuid(), platform: platform
        )
        .prepare(
          journal: base.journal, authorization: base.authorization, sourceBootstrap: base.bootstrap)
      }
    }

    func testBothImagesResumeFromReceiptsWithoutRewritingCompletedPartitions() async throws {
      let fixture = try await Fixture()
      try await fixture.prepare()
      XCTAssertEqual(fixture.opened, 2)
      let journal = try Data(contentsOf: fixture.base.journal)
      try await fixture.prepare()
      XCTAssertEqual(fixture.opened, 2)
      XCTAssertEqual(try Data(contentsOf: fixture.base.journal), journal)
      for name in ["boot", "root"] {
        let path = URL(
          fileURLWithPath: fixture.base.journal.path + ".native-image-" + name + ".evidence")
        let receipt = try JSONDecoder().decode(
          NativeRawImageReceipt.self, from: Data(contentsOf: path))
        XCTAssertGreaterThan(receipt.installedBytes, 0)
      }
    }

    func testMountedFATLabelDoesNotRewriteCompletedImages() async throws {
      let fixture = try await Fixture()
      try await fixture.prepare()
      fixture.espLabel = "EFI - FEDOR"
      try await fixture.prepare()
      XCTAssertEqual(fixture.opened, 2)
      fixture.espLabel = "FOREIGN EFI"
      do {
        try await fixture.prepare()
        XCTFail("Foreign ESP name was accepted")
      } catch {}
      XCTAssertEqual(fixture.opened, 2)
    }

    func testChangedCompletedImageOrOwnerCannotResumeOrWriteAnotherImage() async throws {
      for fault in ["contents", "owner", "snapshot"] {
        let fixture = try await Fixture()
        try await fixture.prepare()
        if fault == "owner" {
          fixture.changedOwner = true
        } else if fault == "snapshot" {
          fixture.changedSnapshot = true
        } else {
          let target = try XCTUnwrap(fixture.targets["disk0s6"])
          let descriptor = open(target.url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
          XCTAssertGreaterThanOrEqual(descriptor, 0)
          defer { close(descriptor) }
          try NativeRawImagePlatform.write(descriptor, Data([0xff]), 0)
        }
        do {
          try await fixture.prepare()
          XCTFail("Changed installed identity was admitted: " + fault)
        } catch {}
        XCTAssertEqual(fixture.opened, 2)
      }
    }
  }
#endif
