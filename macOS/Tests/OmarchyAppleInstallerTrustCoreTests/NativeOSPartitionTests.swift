#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeOSPartitionTests: XCTestCase, @unchecked Sendable {
    static func metadata() throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "os_list": [
          [
            "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fédora Aurora Remix",
            "partitions": [
              [
                "name": "EFI", "type": "EFI", "source": "esp", "format": "fat", "size": "8MiB",
                "volume_id": "0x1234ABCD",
              ],
              ["name": "Boot", "type": "Linux", "image": "boot.img", "size": "16MiB"],
              [
                "name": "Root", "type": "Linux", "image": "root.img", "size": "32MiB",
                "expand": true,
              ],
            ],
          ]
        ]
      ])
    }

    func testExactLayoutExpansionAndFATLabelMatchTheSharedContract() throws {
      let layout = try NativeOSPartitionPlan(metadata: Self.metadata(), available: 80 << 20)
      XCTAssertEqual(layout.parts.map(\.bytes), [8 << 20, 16 << 20, 56 << 20])
      XCTAssertEqual(layout.parts[0].fatLabel, "EFI - Fedor")
      XCTAssertEqual(layout.parts[0].volumeID, "0x1234ABCD")
      XCTAssertNil(layout.parts[1].fatLabel)
      for available in [UInt64(1), 55 << 20, UInt64.max] {
        XCTAssertThrowsError(
          try NativeOSPartitionPlan(metadata: Self.metadata(), available: available))
      }
    }

    func testInvalidMetadataIsRejectedBeforeAnyDiskCommand() throws {
      for fault in ["type", "expand", "format", "source", "volume_id", "size"] {
        var document = try JSONSerialization.jsonObject(with: Self.metadata()) as! [String: Any]
        var templates = document["os_list"] as! [[String: Any]]
        var rows = templates[0]["partitions"] as! [[String: Any]]
        rows[0][fault] =
          [
            "type": "Apple_APFS", "expand": true, "format": "apfs", "source": "../esp",
            "volume_id": "--bad", "size": "-1GiB",
          ][fault]
        templates[0]["partitions"] = rows
        document["os_list"] = templates
        XCTAssertThrowsError(
          try NativeOSPartitionPlan(
            metadata: JSONSerialization.data(withJSONObject: document), available: 80 << 20), fault)
      }
    }

    func testCreateAndResumePreserveUnrelatedVolumesWithoutRepeatingCommands() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let original = fixture.snapshot
      try fixture.prepare()
      XCTAssertEqual(fixture.commands.count, 4)
      XCTAssertEqual(fixture.commands[0].0, "/usr/sbin/diskutil")
      XCTAssertEqual(
        fixture.commands[0].1, ["addPartition", "disk0s4", "%EFI%", "%noformat%", "8388608"])
      XCTAssertEqual(fixture.commands[1].0, "/sbin/newfs_msdos")
      XCTAssertEqual(
        fixture.commands[1].1,
        ["-F", "32", "-v", "EFI - Fedor", "-I", "0x1234ABCD", "/dev/rdisk0s9"])
      let beforeRetry = fixture.snapshot
      try fixture.prepare()
      XCTAssertEqual(fixture.snapshot, beforeRetry)
      XCTAssertEqual(fixture.commands.count, 4)
      var remaining = fixture.snapshot
      remaining.partitions.removeAll {
        ["disk0s9", "disk0s10", "disk0s11"].contains($0.identifier)
      }
      XCTAssertEqual(remaining, original)
      let receipt = try JSONDecoder().decode(
        NativeOSPartitionsExecution.Receipt.self,
        from: Data(
          contentsOf: URL(
            fileURLWithPath: fixture.base.journal.path + ".native-os-partitions.evidence")))
      XCTAssertEqual(receipt.plan, fixture.base.approved.planDigest)
      XCTAssertEqual(receipt.partitions.map(\.identifier), ["disk0s9", "disk0s10", "disk0s11"])
    }

    func testInterruptedCreationOrFormattingNeverReplaysAnAmbiguousCommand() throws {
      for stop in 1...4 {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.stop = stop
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(fixture.commands.count, stop)
        fixture.stop = nil
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(fixture.commands.count, stop)
      }
    }

    func testCompletedPartitionCanResumeBeforeTheNextIntent() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }
      fixture.cancelAfterFirstReceipt = true
      XCTAssertThrowsError(try fixture.prepare())
      XCTAssertEqual(fixture.commands.count, 2)
      fixture.cancelAfterFirstReceipt = false
      try fixture.prepare()
      XCTAssertEqual(fixture.commands.count, 4)
    }

    func testMountedFATLabelCanAppearWithoutAdmittingAnotherLayoutChange() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }
      try fixture.prepare()
      let index = try XCTUnwrap(fixture.snapshot.partitions.firstIndex { $0.type == "EFI" })
      let saved = fixture.snapshot.partitions[index]
      func rename(_ name: String) {
        fixture.snapshot.partitions[index] = RemovalPartition(
          identifier: saved.identifier, uuid: saved.uuid, type: saved.type,
          offset: saved.offset, size: saved.size, name: name)
      }
      rename(try XCTUnwrap(fixture.layout.parts[0].fatLabel).uppercased())
      try fixture.prepare()
      XCTAssertEqual(fixture.commands.count, 4)
      rename("FOREIGN EFI")
      XCTAssertThrowsError(try fixture.prepare())
      XCTAssertEqual(fixture.commands.count, 4)
    }

    func testForeignPartitionChangedOwnerOrUnexpectedDiskChangesStopWrites() throws {
      for fault in ["foreign", "owner", "offset", "size", "unrelated", "replaced"] {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.fault = fault
        if fault == "replaced" {
          try fixture.prepare()
          let last = fixture.snapshot.partitions.removeLast()
          fixture.snapshot.partitions.append(
            RemovalPartition(
              identifier: last.identifier,
              uuid: UUID().uuidString, type: last.type, offset: last.offset, size: last.size,
              name: last.name))
        }
        let count = fixture.commands.count
        XCTAssertThrowsError(try fixture.prepare(), fault)
        if ["foreign", "owner", "replaced"].contains(fault) {
          XCTAssertEqual(fixture.commands.count, count)
        }
      }
    }

    final class Fixture: @unchecked Sendable {
      let base: NativeStubFileTests.ExecutionFixture
      var snapshot: RemovalSnapshot
      let layout: NativeOSPartitionPlan
      let stubBytes: UInt64
      var commands = [(String, [String])]()
      var stop: Int?
      var fault: String?
      var cancelAfterFirstReceipt = false
      init() throws {
        let base = try NativeStubFileTests.ExecutionFixture()
        self.base = base
        var snapshot = base.snapshot
        let target = snapshot.partitions.first { $0.offset == base.approved.offsetBytes }!
        stubBytes = target.size
        snapshot.partitions.removeAll {
          $0.offset >= target.end
            && $0.offset < base.approved.offsetBytes + base.approved.lengthBytes
        }
        self.snapshot = snapshot
        layout = try NativeOSPartitionPlan(
          metadata: NativeOSPartitionTests.metadata(),
          available: base.approved.lengthBytes - target.size)
        let path = URL(fileURLWithPath: base.journal.path + ".native-stub-files.evidence")
        try Data("synthetic-complete-native-files".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }
      func remove() { try? FileManager.default.removeItem(at: base.directory) }
      func prepare() throws {
        let platform = NativeOSPartitionPlatform(
          disks: NativeAPFSPlatform(
            collect: { throw NativeOSPartitionError.changedLayout },
            snapshot: {
              if self.cancelAfterFirstReceipt && self.commands.count == 2 {
                let receipt = URL(
                  fileURLWithPath: self.base.journal.path + ".native-os-partition-0.evidence")
                if FileManager.default.fileExists(atPath: receipt.path) {
                  throw NativeOSPartitionError.commandFailed
                }
              }
              var result = self.snapshot
              if self.fault == "foreign" {
                result.partitions.append(
                  RemovalPartition(
                    identifier: "disk0s99", uuid: UUID().uuidString,
                    type: "Linux Filesystem",
                    offset: self.base.approved.offsetBytes + self.stubBytes,
                    size: 4096, name: "Foreign"))
              }
              return result
            },
            verifyPartition: { part, disk in
              XCTAssertEqual(disk, "disk0")
              XCTAssertTrue(
                self.snapshot.partitions.contains { $0.identifier == part.identifier && $0 == part }
              )
            },
            verifySourceOwner: { _, _, bootstrap, layout in
              XCTAssertEqual(bootstrap, self.base.bootstrap)
              XCTAssertNotNil(layout, "The stage shares the layout it reads again.")
              if self.fault == "owner" { throw NativeHandoffValidationError.invalidOwner }
            }, command: { _ in XCTFail("Unleased disk command") },
            containerReference: { _, _ in throw NativeOSPartitionError.changedLayout }),
          command: { executable, arguments, lease in
            XCTAssertGreaterThanOrEqual(lease.fileDescriptor, 0)
            self.commands.append((executable, arguments))
            if self.stop == self.commands.count { throw NativeOSPartitionError.commandFailed }
            if arguments[0] == "addPartition" {
              let count = self.commands.filter { $0.1[0] == "addPartition" }.count
              let predecessor = try XCTUnwrap(
                self.snapshot.partitions.first { $0.identifier == arguments[1] })
              self.snapshot.partitions.append(
                RemovalPartition(
                  identifier: "disk0s" + String(count + 8), uuid: UUID().uuidString,
                  type: arguments[2] == "%EFI%" ? "EFI" : "Linux Filesystem",
                  offset: predecessor.end + (self.fault == "offset" ? 4096 : 0),
                  size: UInt64(arguments[4])! + (self.fault == "size" ? 4096 : 0), name: ""))
              self.snapshot.partitions.sort { $0.offset < $1.offset }
              if self.fault == "unrelated" { self.snapshot.partitions[1].size -= 4096 }
            }
          })
        try NativeOSPartitionsExecution(
          package: base.package, approved: base.approved,
          layout: layout, stubBytes: stubBytes, owner: geteuid(), platform: platform
        )
        .prepare(
          journal: base.journal, authorization: base.authorization, sourceBootstrap: base.bootstrap)
      }
    }
  }
#endif
