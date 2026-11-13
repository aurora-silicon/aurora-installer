#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeSourceOwnerAdmissionTests: XCTestCase, @unchecked Sendable {
    func testOptInLiveSourceOwnerAdmissionIsReadOnly() throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_OWNER_PROBE"] == "1" else {
        throw XCTSkip("Opt-in live source-owner inspection")
      }
      let identity = try AppleSiliconHostInspector().inspectIdentity()
      let disk = try MacRemovalDiskOperator().snapshot(maximumPartitions: 4096)
      let unused = URL(fileURLWithPath: "/unused-source-owner-probe")
      let package = ImportedEngineHandoffPackage(
        packageURL: unused, manifestURL: unused, requestURL: unused, identityURL: unused,
        metadataURL: unused, payloadURL: unused,
        bindingDigest: String(repeating: "a", count: 64),
        planDigest: String(repeating: "b", count: 64),
        deviceIdentifier: identity.deviceIdentifier, storeIdentifier: disk.disk)
      // This inspection never reads the password; authentication belongs to
      // the calling helper before admission. No disk or boot changes occur.
      let authorization = try MachineOwnerAuthorization(
        username: ProcessInfo.processInfo.environment["AURORA_LIVE_OWNER_PROBE_USER"]
          ?? NSUserName(),
        password: Data("unused-inspection-value".utf8))
      // The lines a saved Installer Log would show, so the probe also
      // records this Mac's Preboot layout.
      let log = InstallerLogBuffer(capacity: 256)
      defer {
        for entry in log.snapshot() where entry.message.hasPrefix("Owner check: ") {
          print("\(entry.level.label) \(entry.message)")
        }
      }
      do {
        let result = try InstallerLog.$taskBuffer.withValue(log) {
          try NativeSourceOwnerAdmission().check(package: package, authorization: authorization)
        }
        XCTAssertNotEqual(result.ownerUUID, "00000000-0000-0000-0000-000000000000")
        print("Live source-owner admission passed on \(identity.deviceIdentifier)")
      } catch {
        XCTFail(
          "Live source-owner admission refused on \(identity.deviceIdentifier): "
            + "\(NativeInstallerExecutor.sourceOwnerSummary(for: error)) [\(error)]")
      }
    }

    func testBootstrapMatchesTheLockedBackendSourceOwnerVectors() throws {
      struct Fixture: Decodable {
        struct Vector: Decodable {
          let fault: String
          let expected: String?
        }
        let vectors: [Vector]
      }
      let url = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-source-owner-vectors", withExtension: "json",
          subdirectory: "Fixtures"))
      let vectors = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).vectors
      XCTAssertEqual(vectors.count, 10)
      for vector in vectors {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.fault = vector.fault
        switch vector.fault {
        case "wrong-guid": try fixture.writeAdmins(["mina": ["GeneratedUID": UUID().uuidString]])
        case "wrong-user": try fixture.writeAdmins(["other": ["GeneratedUID": fixture.owner]])
        case "missing": try FileManager.default.removeItem(at: fixture.admins)
        case "duplicate-system": fixture.updateVolumes { $0.append($0[0]) }
        default: break
        }
        if let expected = vector.expected {
          let actual = try fixture.admit()
          XCTAssertEqual(
            try JSONSerialization.data(
              withJSONObject: actual.configuration, options: [.sortedKeys]),
            Data(expected.utf8), vector.fault)
        } else {
          XCTAssertThrowsError(try fixture.admit(), vector.fault)
        }
      }
    }
    func testSourceOwnerIsResolvedBeforeAnyTargetExistsAndSkipsTheBootSnapshot() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let bootstrap = try fixture.admit()
      XCTAssertEqual(bootstrap.systemUUID, fixture.system)
      XCTAssertEqual(bootstrap.groupUUID, fixture.group)
      XCTAssertEqual(bootstrap.ownerUUID, fixture.owner)
      XCTAssertNotEqual(bootstrap.systemUUID, fixture.bootSnapshot)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.system.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.esp.path))
      XCTAssertFalse(fixture.commands.contains { $0.first == "unmount" })
      XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted))
    }

    func testSourcePrebootGroupWithNeoPermissionsStillRequiresProtectedOwnerMetadata() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let group = fixture.base.sourcePreboot.appendingPathComponent(fixture.group)
      XCTAssertEqual(chmod(group.path, 0o777), 0)
      XCTAssertEqual(try fixture.admit().ownerUUID, fixture.owner)
      XCTAssertEqual(chmod(fixture.base.sourcePreboot.path, 0o755), 0)
      let generic = try NativeHandoffFileTree(
        fixture.base.sourcePreboot, protected: true, owner: getuid())
      XCTAssertThrowsError(
        try generic.read(
          fixture.group + "/var/db/AdminUserRecoveryInfo.plist", maximum: 1 << 20))
      XCTAssertThrowsError(try generic.sourceOwnerMetadata(groupUUID: fixture.group))
      // Folder modes alone decide nothing: every folder shared, as macOS
      // 27.2 leaves var and var/db, is still a root-owned path.
      for directory in ["var", "var/db"] {
        XCTAssertEqual(chmod(group.appendingPathComponent(directory).path, 0o777), 0)
      }
      XCTAssertEqual(try fixture.admit().ownerUUID, fixture.owner)
      // Anyone can add a name there for some other root file.
      let second = group.appendingPathComponent("var/db/second-name")
      XCTAssertEqual(link(fixture.admins.path, second.path), 0)
      XCTAssertThrowsError(try fixture.admit())
      XCTAssertEqual(unlink(second.path), 0)
      XCTAssertEqual(chmod(fixture.admins.path, 0o666), 0)
      XCTAssertThrowsError(try fixture.admit())
    }

    func testTargetBootstrapAndLiveSourceUseTheSameOwnerProof() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let admission = NativeSourceOwnerAdmission(environment: fixture.environment())
      let bootstrap = try fixture.admit()
      let target = UUID().uuidString
      let config: [String: Any] = ["bootstrap": bootstrap.configuration, "groupUUID": target]
      try admission.requireExpected(
        config: config, snapshot: fixture.snapshot,
        authorization: fixture.base.authorization(),
        mounts: NativeHandoffMounts(fixture.environment()))
      for fault in ["system", "group", "owner", "mode", "owners", "target"] {
        var changed = bootstrap.configuration
        var targetGroup = target
        switch fault {
        case "system": changed["sourceSystemUUID"] = UUID().uuidString
        case "group": changed["sourceGroupUUID"] = UUID().uuidString
        case "owner": changed["ownerUUIDs"] = [UUID().uuidString]
        case "mode": changed["mode"] = "other"
        case "owners": changed["ownerUUIDs"] = [fixture.owner, fixture.owner]
        default: targetGroup = bootstrap.groupUUID
        }
        XCTAssertThrowsError(
          try admission.requireExpected(
            config: ["bootstrap": changed, "groupUUID": targetGroup], snapshot: fixture.snapshot,
            authorization: fixture.base.authorization(),
            mounts: NativeHandoffMounts(fixture.environment())), fault)
      }
    }

    func testChangedOwnerSourceGroupGraphOrMountedPrebootFailsClosed() throws {
      // Each guard refuses with its own reason, so the shown summary names it.
      let expected: [(String, (NativeSourceOwnerRefusal) -> Bool)] = [
        ("device", { $0 == .otherMac }),
        ("store", { $0 == .otherDisk }),
        ("root-group", { $0 == .volumes(system: 0, data: 0, preboot: 1, recovery: 1) }),
        ("source-system", { $0 == .systemVolume }),
        ("source-reference", { $0 == .systemVolume }),
        ("local-guid", { $0 == .notVolumeOwner }),
        ("volume-owner", { $0 == .notVolumeOwner }),
        ("numeric-owner", { $0 == .notVolumeOwner }),
        ("preboot-uuid", { if case .preboot = $0 { true } else { false } }),
        ("preboot-path", { if case .preboot = $0 { true } else { false } }),
        ("mount-device", { if case .preboot = $0 { true } else { false } }),
        ("duplicate-system", { $0 == .volumes(system: 2, data: 1, preboot: 1, recovery: 1) }),
        ("missing-data", { $0 == .volumes(system: 1, data: 0, preboot: 1, recovery: 1) }),
        ("duplicate-preboot", { $0 == .volumes(system: 1, data: 1, preboot: 2, recovery: 1) }),
        ("missing-recovery", { $0 == .volumes(system: 1, data: 1, preboot: 1, recovery: 0) }),
        ("unknown-account", { $0 == .unknownAccount }),
        (
          "users-unreadable",
          { if case .diskQuery("APFS volume users", _) = $0 { true } else { false } }
        ),
        ("layout-race", { $0 == .layoutChanged }),
      ]
      for (fault, matches) in expected {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.fault = fault
        if fault == "duplicate-system" { fixture.updateVolumes { $0.append($0[0]) } }
        if fault == "missing-data" {
          fixture.updateVolumes { $0.removeAll { $0.roles == ["Data"] } }
        }
        if fault == "duplicate-preboot" { fixture.updateVolumes { $0.append($0[2]) } }
        if fault == "missing-recovery" {
          fixture.updateVolumes { $0.removeAll { $0.roles == ["Recovery"] } }
        }
        XCTAssertThrowsError(try fixture.admit(), fault) {
          let refusal = $0 as? NativeSourceOwnerRefusal
          XCTAssertTrue(refusal.map(matches) ?? false, "\(fault): \($0)")
        }
        XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted), fault)
        XCTAssertFalse(fixture.commands.contains { $0.first == "unmount" }, fault)
      }
    }

    func testEveryRefusalSummaryReachesTheNoticeWhole() {
      let refusals: [NativeSourceOwnerRefusal] = [
        .otherMac, .otherDisk, .diskQuery(step: "APFS volume users", detail: "x"),
        .runningSystem, .volumes(system: 12, data: 12, preboot: 12, recovery: 12), .systemVolume,
        .unknownAccount, .notVolumeOwner, .preboot(detail: "x"), .adminListMissing,
        .adminListUnreadable(detail: "x"), .notInAdminList, .adminIdentityMismatch,
        .layoutChanged,
      ]
      XCTAssertEqual(Set(refusals.map(\.summary)).count, refusals.count)
      for refusal in refusals {
        let summary = NativeInstallerExecutor.sourceOwnerSummary(for: refusal)
        XCTAssertTrue(
          summary.hasPrefix(NativeInstallerExecutor.sourceOwnerSummaryPrefix + ": "), summary)
        // The notice keeps printable ASCII up to its limit and drops the rest.
        XCTAssertEqual(EngineFailureNotice.sanitizedSummary(summary), summary)
        XCTAssertFalse(String(describing: refusal).isEmpty)
      }
    }

    /// The owner records as macOS writes them on a Mac with Touch ID and
    /// FileVault on (measured on a Touch ID MacBook Pro, 2026-11-02): APFS
    /// lists a Personal Recovery user beside the account, the account has an
    /// Apple Account alias, and its Preboot entry carries SecureToken and
    /// Kerberos authorities and its full name. None of that blocks the proof.
    func testTouchIDMacOwnerRecordsAreAdmitted() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      fixture.fault = "touch-id-mac"
      try fixture.writeAdmins([
        "mina": [
          "AuthenticationAuthority": [
            ";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2,SRP-RFC5054-4096-SHA512-PBKDF2>",
            ";SecureToken;",
            ";Kerberosv5;;mina@LKDC:SHA1.0000;LKDC:SHA1.0000;",
          ],
          "GeneratedUID": fixture.owner, "RealName": "Mina",
        ]
      ])
      let bootstrap = try fixture.admit()
      XCTAssertEqual(bootstrap.ownerUUID, fixture.owner)
    }

    func testANameTypedInAnotherCaseIsLookedUpUnderTheAccountsShortName() throws {
      // OpenDirectory authenticates "Mina" as "mina"; Preboot keys "mina".
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      fixture.canonicalName = { $0.lowercased() }
      let bootstrap = try fixture.admit(username: "Mina")
      XCTAssertEqual(bootstrap.ownerUUID, fixture.owner)

      let literal = try OwnerFixture()
      defer { literal.base.remove() }
      XCTAssertThrowsError(try literal.admit(username: "Mina")) {
        XCTAssertEqual($0 as? NativeSourceOwnerRefusal, .notInAdminList)
      }
    }

    func testOnlyTheAuthorizedAccountsAdminEntryIsRead() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      try fixture.writeAdmins([
        "mina": ["GeneratedUID": fixture.owner], "other": "not an account record", "count": 2,
      ])
      XCTAssertEqual(try fixture.admit().ownerUUID, fixture.owner)
      try fixture.writeAdmins(["mina": "not an account record"])
      XCTAssertThrowsError(try fixture.admit()) {
        XCTAssertEqual($0 as? NativeSourceOwnerRefusal, .notInAdminList)
      }
      try fixture.writeAdmins(["mina", "other"])
      XCTAssertThrowsError(try fixture.admit()) {
        XCTAssertEqual(
          $0 as? NativeSourceOwnerRefusal,
          .adminListUnreadable(detail: "the file is not a dictionary"))
      }
    }

    func testDiskQueriesReadOnlyStandardOutputWhenTheEnvironmentSeparatesIt() throws {
      // AccountNativeCommand captures standard error with the output, so a
      // single diskutil warning makes the property list unreadable.
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      fixture.fault = "stderr-warning"
      XCTAssertThrowsError(try fixture.admit()) {
        guard case .diskQuery("running system", _) = $0 as? NativeSourceOwnerRefusal else {
          return XCTFail("\($0)")
        }
      }
      // The live environment answers queries from standard output alone.
      let separated = try OwnerFixture()
      defer { separated.base.remove() }
      separated.fault = "stderr-warning"
      separated.separateQueries = true
      XCTAssertEqual(try separated.admit().ownerUUID, separated.owner)
      XCTAssertTrue(separated.commands.contains(["apfs", "listUsers", separated.system, "-plist"]))
    }

    func testAStandaloneCheckReadsTheLayoutBeforeAndAfterResolvingTheOwner() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      _ = try fixture.admit()
      XCTAssertEqual(fixture.snapshots, 2)
    }

    func testACallersLayoutIsUsedInsteadOfReadingOneButTheOwnerIsStillChecked() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let bootstrap = try fixture.admit(layout: fixture.snapshot)
      XCTAssertEqual(bootstrap.ownerUUID, fixture.owner)
      XCTAssertEqual(fixture.snapshots, 0, "The caller reads the layout again itself.")
      XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted))

      for fault in ["root-group", "volume-owner", "device"] {
        let faulty = try OwnerFixture()
        defer { faulty.base.remove() }
        faulty.fault = fault
        XCTAssertThrowsError(try faulty.admit(layout: faulty.snapshot), fault)
        XCTAssertEqual(faulty.snapshots, 0, fault)
      }
      // A layout of another disk is refused as a read one is.
      let other = try OwnerFixture()
      defer { other.base.remove() }
      let disk = other.snapshot
      let moved = RemovalSnapshot(
        disk: "disk9", devicePath: disk.devicePath, diskSize: disk.diskSize,
        macOSStoreUUID: disk.macOSStoreUUID, macOSContainerUUID: disk.macOSContainerUUID,
        partitions: disk.partitions, containers: disk.containers)
      XCTAssertThrowsError(try other.admit(layout: moved))
    }

    func testProtectedPrebootMetadataRejectsMissingWrongWritableAndLinkedOwners() throws {
      let expected: [String: (NativeSourceOwnerRefusal) -> Bool] = [
        "missing": { $0 == .adminListMissing },
        "wrong-guid": { $0 == .adminIdentityMismatch },
        "wrong-user": { $0 == .notInAdminList },
        "writable": { if case .adminListUnreadable = $0 { true } else { false } },
        "symlink": { if case .adminListUnreadable = $0 { true } else { false } },
      ]
      for fault in ["missing", "wrong-guid", "wrong-user", "writable", "symlink"] {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        switch fault {
        case "missing": try FileManager.default.removeItem(at: fixture.admins)
        case "wrong-guid": try fixture.writeAdmins(["mina": ["GeneratedUID": UUID().uuidString]])
        case "wrong-user": try fixture.writeAdmins(["other": ["GeneratedUID": fixture.owner]])
        case "writable": XCTAssertEqual(chmod(fixture.admins.path, 0o664), 0)
        default:
          let other = fixture.base.root.appendingPathComponent("other-admins.plist")
          try Data(contentsOf: fixture.admins).write(to: other)
          try FileManager.default.removeItem(at: fixture.admins)
          try FileManager.default.createSymbolicLink(at: fixture.admins, withDestinationURL: other)
        }
        XCTAssertThrowsError(try fixture.admit(), fault) {
          let refusal = $0 as? NativeSourceOwnerRefusal
          XCTAssertTrue(refusal.map(expected[fault]!) ?? false, "\(fault): \($0)")
        }
      }
    }

    /// Each Preboot layout in the fixture is admitted or refused as it
    /// records, and a refusal names the component and the rule in its
    /// summary. What was found at each component reaches the log at progress
    /// level and the refusal at error level, so a log saved with the
    /// default filter shows both.
    func testPrebootAdminListLayoutsAreDecidedAndLoggedAsTheFixtureRecords() throws {
      struct Fixture: Decodable {
        struct Layout: Decodable {
          let name: String, group: String, `var`: String, db: String, file: String
          let content: String, extraLink: String?, expected: String
        }
        let layouts: [Layout]
      }
      let url = try XCTUnwrap(
        Bundle.module.url(
          forResource: "source-preboot-admin-layouts", withExtension: "json",
          subdirectory: "Fixtures"))
      let layouts = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).layouts
      XCTAssertGreaterThanOrEqual(layouts.count, 24)
      XCTAssertEqual(layouts.filter { $0.expected == "admit" }.count, 10)
      for layout in layouts {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        let group = fixture.base.sourcePreboot.appendingPathComponent(fixture.group)
        let variable = group.appendingPathComponent("var")
        let db = variable.appendingPathComponent("db")
        let content: Data =
          switch layout.content {
          case "xml":
            try PropertyListSerialization.data(
              fromPropertyList: [
                "mina": ["GeneratedUID": fixture.owner, "RealName": "Mina"],
                "other": ["GeneratedUID": UUID().uuidString, "RealName": "Other"],
              ], format: .xml, options: 0)
          case "binary":
            try PropertyListSerialization.data(
              fromPropertyList: ["mina": ["GeneratedUID": fixture.owner]], format: .binary,
              options: 0)
          case "empty": Data()
          case "garbage": Data([0xFF, 0x00, 0x13, 0x37, 0xFE])
          case "array":
            try PropertyListSerialization.data(
              fromPropertyList: ["mina"], format: .binary, options: 0)
          case "oversize": Data(count: (1 << 20) + 1)
          default: throw XCTSkip("unknown content \(layout.content)")
          }
        try content.write(to: fixture.admins)
        if let folder = layout.extraLink {
          let directory = ["group": group, "var": variable, "db": db][folder]!
          XCTAssertEqual(
            link(fixture.admins.path, directory.appendingPathComponent("second-name").path), 0,
            layout.name)
        }
        func apply(_ value: String, to item: URL) throws {
          switch value {
          case "missing": try FileManager.default.removeItem(at: item)
          case "symlink":
            let moved = fixture.base.root.appendingPathComponent("moved-" + item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: moved)
            try FileManager.default.createSymbolicLink(at: item, withDestinationURL: moved)
          default:
            XCTAssertEqual(chmod(item.path, mode_t(value, radix: 8)!), 0, layout.name)
          }
        }
        if layout.file == "other-owner" {
          // A name for a file this test does not own, standing in for a
          // file root does not own.
          try FileManager.default.removeItem(at: fixture.admins)
          XCTAssertEqual(link("/private/etc/hosts", fixture.admins.path), 0, layout.name)
        } else {
          try apply(layout.file, to: fixture.admins)
        }
        try apply(layout.db, to: db)
        try apply(layout.var, to: variable)
        try apply(layout.group, to: group)
        let log = InstallerLogBuffer(capacity: 256)
        let outcome = InstallerLog.$taskBuffer.withValue(log) {
          Result { try fixture.admit() }
        }
        let progress = log.snapshot().filter { $0.level == .progress }.map(\.message)
        let errors = log.snapshot().filter { $0.level == .error }.map(\.message).filter {
          $0.hasPrefix("Owner check: ")
        }
        switch (layout.expected, outcome) {
        case ("admit", .success(let bootstrap)):
          XCTAssertEqual(bootstrap.ownerUUID, fixture.owner, layout.name)
          XCTAssertTrue(
            progress.contains { $0.hasPrefix("Owner check: Preboot <group>: folder, owner ") },
            "\(layout.name): \(progress)")
          XCTAssertTrue(
            progress.contains {
              $0.hasPrefix("Owner check: Preboot AdminUserRecoveryInfo.plist: file, owner ")
                && $0.contains("mode \(layout.file)")
            }, "\(layout.name): \(progress)")
          XCTAssertTrue(
            progress.contains {
              $0.hasPrefix("Owner check: Recovery administrator list: \(content.count) bytes")
                && $0.hasSuffix("; this account's entry matches")
            }, "\(layout.name): \(progress)")
          XCTAssertEqual(errors, [], layout.name)
        case ("missing", .failure(let error)):
          XCTAssertEqual(error as? NativeSourceOwnerRefusal, .adminListMissing, layout.name)
          XCTAssertEqual(
            errors, ["Owner check: Recovery administrator list refused: var/db is missing"])
        case (let reason, .failure(let error)):
          XCTAssertEqual(
            error as? NativeSourceOwnerRefusal, .adminListUnreadable(detail: reason), layout.name)
          XCTAssertEqual(
            errors, ["Owner check: Recovery administrator list refused: \(reason)"], layout.name)
          let summary = NativeInstallerExecutor.sourceOwnerSummary(for: error)
          XCTAssertTrue(summary.hasSuffix(": " + reason + "."), summary)
          XCTAssertEqual(EngineFailureNotice.sanitizedSummary(summary), summary)
          XCTAssertTrue(NativeInstallerExecutor.isPrebootAdminListSummary(summary), summary)
        case (_, let outcome):
          XCTFail("\(layout.name): expected \(layout.expected), got \(outcome)")
        }
        // No log line names the account, its GUID or the volume group.
        for line in progress + errors {
          XCTAssertFalse(line.contains("mina"), line)
          XCTAssertFalse(line.contains(fixture.owner), line)
          XCTAssertFalse(line.contains(fixture.group), line)
        }
      }
    }

    func testOnlyPrebootAdminListRefusalsAreGivenTheRebuildRemedy() {
      let listed: [NativeSourceOwnerRefusal] = [
        .adminListMissing, .adminListUnreadable(detail: "var/db is writable by other users"),
        .notInAdminList,
      ]
      for refusal in listed {
        XCTAssertTrue(
          NativeInstallerExecutor.isPrebootAdminListSummary(
            NativeInstallerExecutor.sourceOwnerSummary(for: refusal)), "\(refusal)")
      }
      let others: [NativeSourceOwnerRefusal] = [
        .otherMac, .otherDisk, .runningSystem, .systemVolume, .unknownAccount, .notVolumeOwner,
        .preboot(detail: "x"), .adminIdentityMismatch, .layoutChanged,
        .diskQuery(step: "APFS volume users", detail: "x"),
      ]
      for refusal in others {
        XCTAssertFalse(
          NativeInstallerExecutor.isPrebootAdminListSummary(
            NativeInstallerExecutor.sourceOwnerSummary(for: refusal)), "\(refusal)")
      }
      XCTAssertFalse(NativeInstallerExecutor.isPrebootAdminListSummary(""))
    }

    func testAPFSVolumeOwnersReachTheLogWithoutTheAccount() throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      fixture.fault = "touch-id-mac"
      let log = InstallerLogBuffer(capacity: 64)
      _ = try InstallerLog.$taskBuffer.withValue(log) { try fixture.admit() }
      XCTAssertTrue(
        log.snapshot().map(\.message).contains(
          "Owner check: APFS lists 2 users of the System volume, 2 volume owners "
            + "(types: LocalOpenDirectory, PersonalRecovery); this account is a volume owner"))
    }

    func testOnlyInspectionOwnedReadOnlyMountIsCleanedAfterSuccessOrFailure() throws {
      for failure in [false, true] {
        let fixture = try OwnerFixture()
        defer { fixture.base.remove() }
        fixture.prebootMounted = false
        if failure { try FileManager.default.removeItem(at: fixture.admins) }
        if failure { XCTAssertThrowsError(try fixture.admit()) } else { _ = try fixture.admit() }
        XCTAssertFalse(fixture.prebootMounted)
        XCTAssertEqual(
          fixture.commands.filter { $0.first == "mount" }, [["mount", "readOnly", "disk4s3"]])
        XCTAssertEqual(fixture.commands.filter { $0.first == "unmount" }, [["unmount", "disk4s3"]])
        XCTAssertTrue(fixture.commands.allSatisfy(fixture.permitted))
      }
    }

    func testCancellationBeforeSourceAdmissionLaunchesNoCommands() async throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try fixture.admit()
      }
      do {
        _ = try await task.value
        XCTFail("Cancelled admission completed")
      } catch is CancellationError {}
      XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testCancellationAfterRootQueryStartsNoFurtherInspection() async throws {
      let fixture = try OwnerFixture()
      defer { fixture.base.remove() }
      fixture.fault = "cancel-after-root"
      let task = Task { try fixture.admit() }
      do {
        _ = try await task.value
        XCTFail("Cancelled admission completed")
      } catch is CancellationError {}
      XCTAssertEqual(fixture.commands, [["info", "-plist", "/"]])
    }
  }

  private final class OwnerFixture: @unchecked Sendable {
    let base: NativeRecoveryHandoffFixture
    var snapshot: RemovalSnapshot
    var commands = [[String]]()
    var fault = ""
    var prebootMounted = true
    var snapshots = 0
    var canonicalName: @Sendable (String) -> String = { $0 }
    var separateQueries = false
    let system: String, group: String, owner: String
    let bootSnapshot = "00000000-0000-0000-0000-000000000777"
    var admins: URL {
      base.sourcePreboot.appendingPathComponent(group + "/var/db/AdminUserRecoveryInfo.plist")
    }

    init() throws {
      base = try NativeRecoveryHandoffFixture()
      let config = base.vector["config"] as! [String: Any]
      let bootstrap = config["bootstrap"] as! [String: Any]
      system = bootstrap["sourceSystemUUID"] as! String
      group = bootstrap["sourceGroupUUID"] as! String
      owner = (bootstrap["ownerUUIDs"] as! [String])[0]
      var disk = base.diskSnapshot
      disk.containers = [disk.containers[0]]
      disk.partitions.removeAll {
        ["disk0s4", "disk0s5", "disk0s6", "disk0s7"].contains($0.identifier)
      }
      snapshot = disk
      try FileManager.default.removeItem(at: base.system)
      try FileManager.default.removeItem(at: base.esp)
    }

    func updateVolumes(_ update: (inout [RemovalVolume]) -> Void) {
      let container = snapshot.containers[0]
      var volumes = container.volumes
      update(&volumes)
      snapshot.containers[0] = RemovalContainer(
        uuid: container.uuid, storeUUID: container.storeUUID, volumes: volumes)
    }

    func admit(layout: RemovalSnapshot? = nil, username: String = "mina") throws
      -> NativeSourceBootstrap
    {
      try NativeSourceOwnerAdmission(environment: environment()).check(
        package: base.package,
        authorization: MachineOwnerAuthorization(
          username: username, password: Data("owner-password".utf8)),
        layout: layout)
    }

    func writeAdmins(_ value: Any) throws {
      try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        .write(to: admins)
    }

    func permitted(_ args: [String]) -> Bool {
      (args.count == 3 && Array(args.prefix(2)) == ["info", "-plist"])
        || args == ["apfs", "listUsers", system, "-plist"]
        || args == ["mount", "readOnly", "disk4s3"] || args == ["unmount", "disk4s3"]
    }

    func environment() -> NativeHandoffEnvironment {
      let original = base.environment()
      var environment = NativeHandoffEnvironment(
        snapshot: {
          self.snapshots += 1
          if self.fault == "store" {
            let disk = self.snapshot
            return RemovalSnapshot(
              disk: "disk9", devicePath: disk.devicePath, diskSize: disk.diskSize,
              macOSStoreUUID: disk.macOSStoreUUID, macOSContainerUUID: disk.macOSContainerUUID,
              partitions: disk.partitions, containers: disk.containers)
          }
          if self.fault == "layout-race", self.snapshots > 1 {
            var changed = self.snapshot
            changed.partitions[1].size += 4096
            return changed
          }
          return self.snapshot
        }, device: { self.fault == "device" ? "apple,j613" : self.base.package.deviceIdentifier },
        command: { executable, args in
          let reply = try self.answer(executable, args)
          // What a runner that captures standard error with the output sees
          // when diskutil writes a warning before its reply.
          guard self.fault == "stderr-warning", !self.separateQueries, !reply.isEmpty else {
            return reply
          }
          return Data("diskutil: warning: an unrelated notice\n".utf8) + reply
        },
        ownerUUID: { username in
          XCTAssertEqual(username.lowercased(), "mina")
          if self.fault == "unknown-account" { throw NativeHandoffValidationError.invalidOwner }
          return self.fault == "local-guid" ? UUID().uuidString : self.owner
        }, rawDigest: original.rawDigest, verifyRecovery: original.verifyRecovery,
        owner: original.owner, mountRoot: original.mountRoot,
        sourcePrebootMount: original.sourcePrebootMount,
        verifyMount: { fd, url, device in
          if self.fault == "mount-device" { throw NativeHandoffValidationError.invalidOwner }
          try original.verifyMount(fd, url, device)
        })
      environment.ownerName = { self.canonicalName($0) }
      if separateQueries {
        environment.query = { try self.answer("/usr/sbin/diskutil", $0) }
      }
      return environment
    }

    private func answer(_ executable: String, _ args: [String]) throws -> Data {
      guard executable == "/usr/sbin/diskutil", permitted(args) else {
        throw NativeHandoffValidationError.invalidOwner
      }
      commands.append(args)
      func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
      }
      if args == ["info", "-plist", "/"] {
        if fault == "cancel-after-root" { withUnsafeCurrentTask { $0?.cancel() } }
        return try plist([
          "APFSVolumeGroupID": fault == "root-group" ? UUID().uuidString : group,
          "APFSContainerReference": "disk4", "VolumeUUID": bootSnapshot,
        ])
      }
      if args == ["info", "-plist", "disk4s1"] {
        return try plist([
          "VolumeUUID": fault == "source-system" ? UUID().uuidString : system,
          "APFSVolumeGroupID": group,
          "APFSContainerReference": fault == "source-reference" ? "disk9" : "disk4",
        ])
      }
      if args == ["apfs", "listUsers", system, "-plist"] {
        if fault == "users-unreadable" { return try plist(["Volumes": []]) }
        if fault == "touch-id-mac" {
          return try plist([
            "Users": [
              [
                "APFSCryptoUserType": "LocalOpenDirectory", "APFSCryptoUserUUID": owner,
                "VolumeOwner": true,
              ],
              [
                "APFSCryptoUserType": "PersonalRecovery",
                "APFSCryptoUserUUID": "EBC6C064-0000-11AA-AA11-00306543ECAC", "VolumeOwner": true,
              ],
            ]
          ])
        }
        let flag: Any
        if fault == "numeric-owner" {
          flag = 1
        } else {
          flag = fault != "volume-owner"
        }
        return try plist(["Users": [["APFSCryptoUserUUID": owner, "VolumeOwner": flag]]])
      }
      if args == ["info", "-plist", "disk4s3"] {
        return try plist([
          "VolumeUUID": fault == "preboot-uuid"
            ? UUID().uuidString
            : snapshot.containers[0].volumes.first { $0.roles == ["Preboot"] }!.uuid,
          "MountPoint": prebootMounted
            ? (fault == "preboot-path" ? "/tmp/untrusted" : base.sourcePreboot.path)
            : "",
        ])
      }
      if args == ["mount", "readOnly", "disk4s3"] {
        prebootMounted = true
        return Data()
      }
      if args == ["unmount", "disk4s3"] {
        prebootMounted = false
        return Data()
      }
      throw NativeHandoffValidationError.invalidOwner
    }
  }
#endif
