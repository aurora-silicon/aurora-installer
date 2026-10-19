#if os(macOS)
  import CryptoKit
  import Foundation
  @testable import RecoveryAccountCore
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class RecoveryAccountTests: XCTestCase {
    func testCompletedRecoveryDiscoversExternalConfigurationWithoutChangingTheSignedApp() throws {
      let fm = FileManager.default
      let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: system) }
      let external = system.appendingPathComponent("Aurora/Recovery/InstallData")
      let embedded = system.appendingPathComponent("Aurora Installer.app/Contents/Resources")
      try fm.createDirectory(at: external, withIntermediateDirectories: true)
      try fm.createDirectory(at: embedded, withIntermediateDirectories: true)
      let configuration = Data("external installation configuration".utf8)
      try configuration.write(to: external.appendingPathComponent("install-config.json"))
      let old = embedded.appendingPathComponent("install-config.json")
      let stale = Data("stale embedded configuration".utf8)
      try stale.write(to: old)
      let read: (URL, Int) throws -> Data = { url, _ in try Data(contentsOf: url) }
      XCTAssertEqual(
        try RecoveryAccountHandoff.installationConfiguration(system: system, read: read),
        configuration)
      XCTAssertEqual(try Data(contentsOf: old), stale)
      try fm.removeItem(at: old)
      XCTAssertEqual(
        try RecoveryAccountHandoff.installationConfiguration(system: system, read: read),
        configuration)
      // A damaged new layout must not fall back to a stale app-embedded record.
      try fm.removeItem(at: external.appendingPathComponent("install-config.json"))
      try stale.write(to: old)
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.installationConfiguration(system: system, read: read))
      try fm.removeItem(at: external)
      XCTAssertEqual(
        try RecoveryAccountHandoff.installationConfiguration(system: system, read: read), stale)
    }

    func testCompletedRecoveryRefusesASymlinkedExternalDataDirectory() throws {
      let fm = FileManager.default
      let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: system) }
      let parent = system.appendingPathComponent("Aurora/Recovery")
      let other = system.appendingPathComponent("other")
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      try fm.createDirectory(at: other, withIntermediateDirectories: true)
      try fm.createSymbolicLink(
        at: parent.appendingPathComponent("InstallData"), withDestinationURL: other)
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.installationConfiguration(
          system: system, read: { url, _ in try Data(contentsOf: url) }))
    }

    func testRecoveryTemplateMatchIncludesSignedSettingsAndResources() throws {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: root) }
      let app = root.appendingPathComponent("installed.app")
      let template = root.appendingPathComponent("template.app")
      let names = [
        "Contents/Info.plist", "Contents/MacOS/OmarchyRecovery",
        "Contents/_CodeSignature/CodeResources",
      ]
      for bundle in [app, template] {
        for name in names {
          let url = bundle.appendingPathComponent(name)
          try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try Data(name.utf8).write(to: url)
        }
      }
      XCTAssertTrue(try RecoveryAccountHandoff.recoveryAppMatchesTemplate(app, template: template))
      for name in names {
        let url = app.appendingPathComponent(name)
        try Data("changed".utf8).write(to: url)
        XCTAssertFalse(
          try RecoveryAccountHandoff.recoveryAppMatchesTemplate(app, template: template))
        try Data(name.utf8).write(to: url)
      }
    }

    func testTokenAuthorityWaitsForNativePersistence() throws {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      var reads = 0
      try RecoveryAccountInstaller.waitForTokenAuthority(
        generatedUID: id, passwordHashes: hashes,
        read: {
          reads += 1
          return [
            "generateduid": [id], "ShadowHashData": hashes,
            "authentication_authority": reads < 3 ? [] : [";SecureToken;"],
          ]
        }, pause: {})
      XCTAssertEqual(reads, 3)
    }

    func testTokenAuthorityRejectsChangedIdentityOrPasswordHash() {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      let changes: [[String: Any]] = [
        ["generateduid": [UUID().uuidString], "ShadowHashData": hashes],
        ["generateduid": [id], "ShadowHashData": [Data("changed".utf8)]],
      ]
      for changed in changes {
        XCTAssertThrowsError(
          try RecoveryAccountInstaller.waitForTokenAuthority(
            generatedUID: id, passwordHashes: hashes,
            read: {
              changed.merging(["authentication_authority": [";SecureToken;"]]) { _, new in new }
            },
            pause: {}))
      }
    }

    func testTokenAuthorityDoesNotAcceptAnUnpersistedMarker() {
      let id = UUID().uuidString
      let hashes = [Data("fixture-hash".utf8)]
      XCTAssertThrowsError(
        try RecoveryAccountInstaller.waitForTokenAuthority(
          generatedUID: id, passwordHashes: hashes, timeout: 0,
          read: { ["generateduid": [id], "ShadowHashData": hashes] }, pause: {}))
    }

    func testShutdownRequiresSelectedTargetVolumeGroup() throws {
      try RecoveryAccountHandoff.requireStartupSelection(
        target, info: ["APFSVolumeGroupID": target.groupUUID])
      // bless may identify either member of the same APFS volume group.
      try RecoveryAccountHandoff.requireStartupSelection(
        target, info: ["APFSVolumeGroupID": target.groupUUID, "VolumeUUID": target.dataUUID])
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.requireStartupSelection(
          target, info: ["APFSVolumeGroupID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]))
      XCTAssertThrowsError(try RecoveryAccountHandoff.requireStartupSelection(target, info: [:]))
    }

    func testCompletedInstallationRequiresLivePartitionIdentities() throws {
      let ids = (1...4).map { String(format: "%08d-1111-4111-8111-111111111111", $0) }
      let evidence = [
        "apfs-target-prepared": try JSONSerialization.data(withJSONObject: [
          "uuid": ids[0], "size_bytes": 6000,
        ]),
        "stub-and-esp-installed": try JSONSerialization.data(withJSONObject: [
          "populated_partitions": (1...3).map {
            ["partition_uuid": ids[$0], "partition_size_bytes": 1000] as [String: Any]
          }
        ]),
      ]
      let parts: [[String: Any]] = ids.enumerated().map {
        [
          "DiskUUID": $0.element, "Size": $0.offset == 0 ? 6000 : 1000,
          "DeviceIdentifier": "disk9s\($0.offset + 3)",
        ]
      }
      func check(_ partitions: [[String: Any]]) throws {
        let bytes = try PropertyListSerialization.data(
          fromPropertyList: ["AllDisksAndPartitions": [["Partitions": partitions]]],
          format: .xml, options: 0)
        let listing = try XCTUnwrap(
          PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        try RecoveryAccountHandoff.requireLivePartitions(
          evidence: evidence, listing: listing)
      }
      try check(parts)
      // Device renumbering is harmless; UUID and size carry the identity.
      try check(parts.map { $0.merging(["DeviceIdentifier": "renumbered"]) { _, new in new } })
      XCTAssertThrowsError(try check(Array(parts.dropLast())))
      XCTAssertThrowsError(try check(parts + [parts[0]]))
      var resized = parts
      resized[3]["Size"] = 2000
      XCTAssertThrowsError(try check(resized))
      XCTAssertThrowsError(try check([]))
    }

    func testNativeStartupDiskRequiresValidStubVersionMetadata() throws {
      let valid = try PropertyListSerialization.data(
        fromPropertyList: [
          "ProductName": "macOS", "ProductVersion": "26.6.2", "ProductBuildVersion": "25G83",
        ], format: .xml, options: 0)
      try RecoveryVersionMetadata.validate(valid)
      for value in [
        [String: String](), ["ProductName": "macOS"],
        ["ProductName": "macOS", "ProductVersion": "26.6.2", "ProductBuildVersion": ""],
      ] {
        let data = try PropertyListSerialization.data(
          fromPropertyList: value, format: .xml, options: 0)
        XCTAssertThrowsError(try RecoveryVersionMetadata.validate(data))
      }
    }
    func testCompletedAuroraAccountHandoffDisarmsOnlyItsOwnLauncher() throws {
      let fm = FileManager.default
      let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: system) }
      let core = system.appendingPathComponent("System/Library/CoreServices")
      let state = system.appendingPathComponent("Aurora/Recovery/State")
      try fm.createDirectory(at: core, withIntermediateDirectories: true)
      try fm.createDirectory(at: state, withIntermediateDirectories: true)
      let version = try PropertyListSerialization.data(
        fromPropertyList: [
          "ProductName": "macOS", "ProductVersion": "26.6.2", "ProductBuildVersion": "25G83",
        ], format: .xml, options: 0)
      try version.write(to: core.appendingPathComponent("SystemVersion-disabled.plist"))
      let receipt = state.appendingPathComponent("installation.json")
      try JSONSerialization.data(
        withJSONObject: ["status": "installed", "recoveryAccountDeferred": true]
      ).write(to: receipt)
      let marker = system.appendingPathComponent(".IAPhysicalMedia")
      let read: (URL, Int) throws -> Data = { url, _ in try Data(contentsOf: url) }
      let other = try PropertyListSerialization.data(
        fromPropertyList: ["AppName": "Another Installer.app"], format: .xml, options: 0)
      try other.write(to: marker)
      XCTAssertThrowsError(
        try RecoveryVersionMetadata.finishAccountSetup(system: system, read: read))
      XCTAssertTrue(fm.fileExists(atPath: marker.path))
      XCTAssertFalse(fm.fileExists(atPath: core.appendingPathComponent("SystemVersion.plist").path))
      let launch = try PropertyListSerialization.data(
        fromPropertyList: ["AppName": "Aurora Installer.app"], format: .xml, options: 0)
      try launch.write(to: marker)
      let relocated = try RecoveryVersionMetadata.finishAccountSetup(system: system, read: read)
      XCTAssertEqual(relocated.count, 2)
      XCTAssertFalse(fm.fileExists(atPath: marker.path))
      XCTAssertEqual(
        try Data(contentsOf: system.appendingPathComponent("IAPhysicalMedia-disabled.plist")),
        launch)
      XCTAssertEqual(
        try Data(contentsOf: core.appendingPathComponent("SystemVersion.plist")), version)
      let finished = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
      XCTAssertEqual(finished["recoveryAccountDeferred"] as? Bool, false)
    }

    let target = RecoveryAccountTarget(
      volumeName: "Aurora", systemUUID: "11111111-1111-4111-8111-111111111111",
      dataUUID: "22222222-2222-4222-8222-222222222222",
      groupUUID: "33333333-3333-4333-8333-333333333333",
      prebootUUID: "44444444-4444-4444-8444-444444444444")

    func testRecoveryAccountInputAndIdentityValidation() throws {
      try target.validate()
      XCTAssertTrue(RecoveryAccountInstaller.validName("omarchy-owner"))
      for name in ["root", "daemon", "nobody", "../owner", "name\nquit", "OWNER", "-owner"] {
        XCTAssertFalse(RecoveryAccountInstaller.validName(name))
      }
      try RecoveryAccountInstaller.validatePassword(Data("short".utf8))
      for value in [Data(), Data([0]), Data("line\nbreak".utf8), Data(repeating: 65, count: 4097)] {
        XCTAssertThrowsError(try RecoveryAccountInstaller.validatePassword(value))
      }
      let record = RecoveryAccountRecord(
        target: target, username: "owner", generatedUID: UUID().uuidString, phase: "prepared")
      try record.validate()
      XCTAssertEqual(
        try JSONDecoder().decode(RecoveryAccountRecord.self, from: JSONEncoder().encode(record)),
        record)
    }

    func testRelativeAccountLookupHandlesDifferentMountSuffixes() {
      XCTAssertEqual(
        RecoveryAccountInstaller.relativePath(
          from: URL(fileURLWithPath: "/Volumes/Aurora 1/private"),
          to: URL(fileURLWithPath: "/Volumes/Aurora - Data 2/private/var")),
        "../../Aurora - Data 2/private/var")
      XCTAssertEqual(
        RecoveryAccountInstaller.relativePath(
          from: URL(fileURLWithPath: "/Volumes/Aurora 1"),
          to: URL(fileURLWithPath: "/Volumes/Aurora - Data 2/private/var")),
        "../Aurora - Data 2/private/var")
    }

    func testCommandUsesStdinAndBoundsOutputAndTime() throws {
      let secret = Data("unit-test-only\n".utf8)
      let echoed = try AccountNativeCommand.run("/bin/cat", [], input: secret)
      XCTAssertEqual(echoed.status, 0)
      XCTAssertEqual(echoed.output, secret)
      let earlyExit = try AccountNativeCommand.run(
        "/usr/bin/true", [], input: Data(repeating: 65, count: 8192))
      XCTAssertEqual(earlyExit.status, 0)
      XCTAssertThrowsError(try AccountNativeCommand.run("/bin/sleep", ["5"], timeout: 1))
      XCTAssertThrowsError(try AccountNativeCommand.run("/usr/bin/yes", [], timeout: 3))
    }

    func testCompletedCheckpointBindsTargetAndRejectsDamage() throws {
      let digest = String(repeating: "a", count: 64)
      let ids = ["apfs-target-prepared", "stub-and-esp-installed", "recovery-handoff-prepared"]
      let esp = "55555555-5555-4555-8555-555555555555"
      var evidence = [String: Data]()
      for id in ids {
        var value: [String: Any] = ["plan_digest": digest]
        if id == "stub-and-esp-installed" {
          value["apfs_vgid"] = target.groupUUID
          value["efi_partition"] = esp
          value["populated_partitions"] = [
            ["name": "EFI", "partition_uuid": esp], ["name": "Boot"], ["name": "Root"],
          ]
        }
        evidence[id] = try JSONSerialization.data(withJSONObject: value)
      }
      var rows: [[String: Any]] = []
      func add(_ type: String, _ payload: [String: Any]) {
        rows.append([
          "schema_version": 1, "sequence": rows.count + 1, "type": type, "payload": payload,
        ])
      }
      add("inspection", ["device_identifier": "apple,j700", "support": "supported"])
      add("inventory", [:])
      add("plan", ["plan_digest": digest])
      for id in ids {
        add("event", ["name": id, "plan_digest": digest])
        let hash = SHA256.hash(data: evidence[id]!).map { String(format: "%02x", $0) }.joined()
        add(
          "checkpoint",
          ["identifier": id, "plan_digest": digest, "evidence_digest": "sha256:" + hash])
      }
      add("completion", ["plan_digest": digest, "outcome": "awaiting_recovery"])
      var transcript = Data()
      for row in rows {
        transcript.append(try JSONSerialization.data(withJSONObject: row))
        transcript.append(10)
      }
      let result = try RecoveryAccountHandoff.completedEvidence(
        transcript: transcript, evidence: evidence)
      XCTAssertEqual(result.group, target.groupUUID)
      XCTAssertEqual(result.esp, esp)
      var damaged = evidence
      damaged[ids[1]]!.append(32)
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(transcript: transcript, evidence: damaged))
      XCTAssertThrowsError(
        try RecoveryAccountHandoff.completedEvidence(
          transcript: transcript.dropLast(), evidence: evidence))
    }
  }
#endif
