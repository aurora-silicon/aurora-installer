#if os(macOS)
  import CryptoKit
  import Foundation
  @testable import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class RecoveryAccountTests: XCTestCase {
    func testStartupDiscoveryIgnoresAnEmptyProtectedPreflightJournal() throws {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      try fm.createDirectory(
        at: journals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let file = journals.appendingPathComponent(String(repeating: "a", count: 64) + ".jsonl")
      try Data().write(to: file)
      XCTAssertEqual(chmod(file.path, 0o600), 0)
      XCTAssertNil(try RecoveryAccountHandoff.discover(in: root, owner: getuid()))
      XCTAssertEqual(try Data(contentsOf: file), Data(), "keep the failed preparation evidence")
      XCTAssertEqual(chmod(file.path, 0o666), 0)
      XCTAssertThrowsError(try RecoveryAccountHandoff.discover(in: root, owner: getuid()))
    }

    func testStartupDiscoveryKeepsTheFreshInstallBesideItsCompletedReset() throws {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      try fm.createDirectory(
        at: journals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

      // The fresh install that created the installation and handed off to Recovery.
      let ids = (1...4).map { String(format: "%08d-2222-4222-8222-222222222222", $0) }
      let digest = String(repeating: "b", count: 64)
      let freshHex = String(repeating: "f", count: 64)
      let fresh = journals.appendingPathComponent(freshHex + ".jsonl")
      let evidence: [String: Data] = [
        "apfs-target-prepared": try JSONSerialization.data(withJSONObject: [
          "plan_digest": digest, "uuid": ids[0], "size_bytes": 6000,
        ]),
        "stub-and-esp-installed": try JSONSerialization.data(withJSONObject: [
          "plan_digest": digest, "apfs_vgid": target.groupUUID, "efi_partition": ids[1],
          "populated_partitions": zip(["EFI", "Boot", "Root"], ids.dropFirst()).map {
            ["name": $0, "partition_uuid": $1, "partition_size_bytes": 1000] as [String: Any]
          },
        ]),
        "recovery-handoff-prepared": try JSONSerialization.data(withJSONObject: [
          "plan_digest": digest
        ]),
      ]
      var rows: [[String: Any]] = []
      func add(_ type: String, _ payload: [String: Any]) {
        rows.append([
          "schema_version": 1, "sequence": rows.count + 1, "type": type, "payload": payload,
        ])
      }
      add("inspection", ["device_identifier": "apple,j700", "support": "supported"])
      add("inventory", [:])
      add("plan", ["plan_digest": digest])
      for id in ["apfs-target-prepared", "stub-and-esp-installed", "recovery-handoff-prepared"] {
        add("event", ["name": id, "plan_digest": digest])
        let hash = SHA256.hash(data: evidence[id]!).map { String(format: "%02x", $0) }.joined()
        add(
          "checkpoint",
          ["identifier": id, "plan_digest": digest, "evidence_digest": "sha256:" + hash])
        try evidence[id]!.write(to: URL(fileURLWithPath: fresh.path + ".\(id).evidence"))
      }
      add("completion", ["plan_digest": digest, "outcome": "awaiting_recovery"])
      var transcript = Data()
      for row in rows {
        transcript.append(try JSONSerialization.data(withJSONObject: row))
        transcript.append(10)
      }
      try transcript.write(to: fresh)
      XCTAssertEqual(chmod(fresh.path, 0o600), 0)

      // A completed reset of that installation, recorded through its own journal.
      let resetHex = String(repeating: "c", count: 64)
      let reset = journals.appendingPathComponent(resetHex + ".jsonl")
      try Data().write(to: reset)
      XCTAssertEqual(chmod(reset.path, 0o600), 0)
      let (resetTranscript, approved) = try NativePreservedInstallJournalTests.transcript()
      let package = ImportedEngineHandoffPackage(
        packageURL: root, manifestURL: root.appendingPathComponent("manifest.json"),
        requestURL: root.appendingPathComponent("request.json"),
        identityURL: root.appendingPathComponent("identity.json"),
        metadataURL: root.appendingPathComponent("metadata"),
        payloadURL: root.appendingPathComponent("payload"),
        bindingDigest: "sha256:" + resetHex, planDigest: approved.planDigest,
        deviceIdentifier: approved.deviceIdentifier, storeIdentifier: approved.storeIdentifier,
        installationIntent: .reinstall)
      do {
        let journal = try NativePreservedInstallJournal(
          url: reset, package: package, transcript: resetTranscript, owner: geteuid())
        try journal.bindInstallConf(InstallConf(encrypt: false, lane: "edge"))
        try journal.begin()
        let image = NativeRawImageReceipt(
          partitionIdentifier: "disk0s5", partitionUUID: ids[2].lowercased(),
          partitionSizeBytes: 1 << 20, installedBytes: 4096,
          contentSHA256: String(repeating: "d", count: 64),
          verification: "source-sha256-write-flushed-v1")
        try journal.recordWritten(
          NativePreservedInstallReceipt(
            planDigest: approved.planDigest,
            targetIdentity: "sha256:" + String(repeating: "a", count: 64),
            espUUID: ids[1].lowercased(), boot: image, root: image,
            espDigest: String(repeating: "e", count: 64)))
        try journal.complete { _ in }
        XCTAssertEqual(try journal.snapshot().state, .complete)
      }

      let listingBytes = try PropertyListSerialization.data(
        fromPropertyList: [
          "AllDisksAndPartitions": [
            [
              "Partitions": ids.enumerated().map {
                ["DiskUUID": $0.element, "Size": $0.offset == 0 ? 6000 : 1000] as [String: Any]
              }
            ]
          ]
        ], format: .xml, options: 0)
      let listing = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: listingBytes, format: nil) as? [String: Any])
      var listed = 0
      func discover(_ binding: String? = nil) throws -> CompletedRecoveryInstallation? {
        try RecoveryAccountHandoff.discover(
          in: root, binding: binding, owner: getuid(),
          read: { url, limit in
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= limit else { throw AccountSetupFailure("Too large.") }
            return bytes
          },
          partitions: {
            listed += 1
            return listing
          },
          liveTarget: { group, esp in
            guard group == self.target.groupUUID.uppercased(), esp == ids[1].uppercased() else {
              throw AccountSetupFailure("Absent.")
            }
            return self.target
          })
      }

      XCTAssertEqual(
        try discover(),
        CompletedRecoveryInstallation(binding: freshHex, target: target, espUUID: ids[1]))
      listed = 0
      XCTAssertNil(try discover(resetHex))
      XCTAssertEqual(listed, 0, "a completed reset needs no account target of its own")

      // A fresh-install record that lost its evidence is refused, not skipped.
      let handoff = URL(fileURLWithPath: fresh.path + ".recovery-handoff-prepared.evidence")
      try fm.removeItem(at: handoff)
      XCTAssertThrowsError(try discover())
      try evidence["recovery-handoff-prepared"]!.write(to: handoff)

      // A reset record that doesn't verify is refused, not skipped.
      let written = URL(fileURLWithPath: reset.path + ".preserved-install-written.evidence")
      let receipt = try Data(contentsOf: written)
      try (receipt + Data(" ".utf8)).write(to: written)
      XCTAssertThrowsError(try discover(resetHex))
      XCTAssertThrowsError(try discover())
      try receipt.write(to: written)
      XCTAssertNotNil(try discover())
    }

    func testInterruptedRecoveryAppUpdatesRestoreOrKeepOnlyTheCommittedVersion() throws {
      let fm = FileManager.default
      for boundary in ["before-rename", "old-renamed", "new-renamed", "committed"] {
        let system = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: system) }
        let core = system.appendingPathComponent("System/Library/CoreServices")
        let state = system.appendingPathComponent("Aurora/Recovery/State")
        let backup = system.appendingPathComponent(
          "Aurora/Recovery/AppBackups/\(UUID().uuidString).app")
        let app = system.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName)
        for directory in [core, state, backup.deletingLastPathComponent(), app] {
          try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        }
        let version = core.appendingPathComponent("SystemVersion.plist")
        let hidden = core.appendingPathComponent("SystemVersion-disabled.plist")
        let marker = system.appendingPathComponent(".IAPhysicalMedia")
        try Data("original metadata".utf8).write(to: version)
        try Data("original launcher".utf8).write(to: marker)
        try Data("old app".utf8).write(to: app.appendingPathComponent("version"))
        let files = [version, hidden, marker]
        let snapshot = state.appendingPathComponent("app-update-\(UUID().uuidString)")
        let transaction = try RecoveryFileTransaction(directory: snapshot, files: files)
        let pending = state.appendingPathComponent("app-update.pending.json")
        let record: [String: Any] = [
          "target": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)),
          "backup": backup.lastPathComponent, "snapshot": snapshot.lastPathComponent,
          "originalFiles": files.map(\.path),
        ]
        try RecoveryFileTransaction.write(
          try JSONSerialization.data(withJSONObject: record), to: pending)
        try RecoveryFileTransaction.write(
          try JSONEncoder().encode(target), to: backup.appendingPathExtension("json"))
        if boundary != "before-rename" { try fm.moveItem(at: app, to: backup) }
        if boundary == "new-renamed" || boundary == "committed" {
          try fm.createDirectory(at: app, withIntermediateDirectories: false)
          try Data("new app".utf8).write(to: app.appendingPathComponent("version"))
          try Data("new launcher".utf8).write(to: marker)
          try fm.moveItem(at: version, to: hidden)
        }
        if boundary == "committed" {
          try transaction.commit(relocated: [version.path: hidden])
        }
        let read: (URL, Int) throws -> Data = { path, limit in
          let bytes = try Data(contentsOf: path)
          XCTAssertLessThanOrEqual(bytes.count, limit)
          return bytes
        }
        let other = RecoveryAccountTarget(
          volumeName: target.volumeName, systemUUID: UUID().uuidString, dataUUID: target.dataUUID,
          groupUUID: target.groupUUID, prebootUUID: target.prebootUUID)
        XCTAssertThrowsError(
          try RecoveryAccountHandoff.resumeAppUpdate(system: system, target: other, read: read))
        XCTAssertTrue(fm.fileExists(atPath: pending.path))
        try RecoveryAccountHandoff.resumeAppUpdate(system: system, target: target, read: read)
        try RecoveryAccountHandoff.resumeAppUpdate(system: system, target: target, read: read)
        XCTAssertFalse(fm.fileExists(atPath: pending.path))
        let committed = boundary == "committed"
        XCTAssertEqual(
          try Data(contentsOf: app.appendingPathComponent("version")),
          Data((committed ? "new app" : "old app").utf8))
        XCTAssertEqual(
          try Data(contentsOf: marker),
          Data((committed ? "new launcher" : "original launcher").utf8))
        XCTAssertEqual(fm.fileExists(atPath: version.path), !committed)
        XCTAssertEqual(fm.fileExists(atPath: hidden.path), committed)
      }
    }

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
      XCTAssertTrue(RecoveryAccountInstaller.validName("aurora-owner"))
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
      // A limit the runner refuses names the limit, not a status.
      XCTAssertThrowsError(try AccountNativeCommand.run("/usr/bin/true", [], timeout: 91)) {
        XCTAssertEqual(
          ($0 as? AccountSetupFailure)?.message,
          "The native command time limit must be 1 to 90 seconds.")
      }
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
