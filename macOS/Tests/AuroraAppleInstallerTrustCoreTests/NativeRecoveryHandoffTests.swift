#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeRecoveryHandoffTests: XCTestCase {
    func testSystemPrebootLocationIsAcceptedOnlyForTheVerifiedSourcePrebootRole() throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      XCTAssertEqual(
        NativeHandoffEnvironment.live.sourcePrebootMount.path, "/System/Volumes/Preboot")
      let mounts = NativeHandoffMounts(fixture.environment())
      let uuid = fixture.diskSnapshot.containers[0].volumes[2].uuid
      XCTAssertThrowsError(try mounts.mounted("disk4s3", uuid: uuid))
      XCTAssertEqual(
        try mounts.mounted("disk4s3", uuid: uuid, sourcePreboot: true).path,
        fixture.sourcePreboot.path)
      XCTAssertThrowsError(
        try mounts.mounted("disk4s3", uuid: UUID().uuidString, sourcePreboot: true))
    }
    private struct ForbiddenFirmwarePreparation: NativeFirmwarePreparing {
      func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
        throw NativeHandoffValidationError.invalidTarget
      }
    }
    func testSupportedBoardLayoutsKeepTheFastFreshRootPath() async throws {
      for index in [1, 2, 3] {
        let fixture = try NativeRecoveryHandoffFixture(index)
        defer { fixture.remove() }
        let result = try await fixture.executor().execute(
          package: fixture.package,
          journal: fixture.journalURL, authorization: fixture.authorization(),
          requirement: "fixture",
          fullReadback: false)
        let validated = try AppleInstallerTrustCore().validateEngineTranscript(result)
        XCTAssertEqual(validated.completion, .awaitingRecovery)
        XCTAssertEqual(fixture.rawReads, ["disk0s6"])
        XCTAssertEqual(fixture.blessCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeVersion.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.disabledVersion.path))
        XCTAssertEqual(try fixture.journalSnapshot().state, .complete)
      }
    }

    func testRawAndMachOConfigurationsCompleteFreshAndStartedRecoveryHandoffs() async throws {
      // Every mode the installer can write must hand off.
      XCTAssertEqual(NativeRecoveryBootMode.allCases.map(\.rawValue), ["macho-standard", "macho"])
      for mode in NativeRecoveryBootMode.allCases.map(\.rawValue) {
        for retry in [false, true] {
          let fixture = try NativeRecoveryHandoffFixture()
          defer { fixture.remove() }
          let url = fixture.system.appendingPathComponent(
            "Aurora/Recovery/InstallData/install-config.json")
          var config = fixture.vector["config"] as! [String: Any]
          config["bootMode"] = mode
          config["stage2Path"] = AuraStage1Format.stage2Path(executeWindow: mode == "macho")
          try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: url)
          if retry {
            let journal = try NativeRecoveryJournal(
              url: fixture.journalURL, package: fixture.package, owner: geteuid())
            try journal.beginHandoff()
          }
          let result = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture", fullReadback: false)
          XCTAssertEqual(
            try AppleInstallerTrustCore().validateEngineTranscript(result).completion,
            .awaitingRecovery)
          XCTAssertEqual(fixture.rawReads, retry ? ["disk0s6", "disk0s7"] : ["disk0s6"])
          XCTAssertEqual(fixture.blessCalls, 1)
          XCTAssertEqual(try fixture.journalSnapshot().state, .complete)
        }
      }
    }

    func testEachBootModeNamesOnlyItsOwnStage2() async throws {
      for (mode, path, accepted) in [
        ("macho", AuraStage1Format.confinedStage2Path, true),
        ("raw", AuraStage1Format.confinedStage2Path, false),
        ("macho", AuraStage1Format.standardStage2Path, false),
      ] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        let url = fixture.system.appendingPathComponent(
          "Aurora/Recovery/InstallData/install-config.json")
        var config = fixture.vector["config"] as! [String: Any]
        config["bootMode"] = mode
        config["stage2Path"] = path
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: url)
        do {
          _ = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture", fullReadback: false)
          XCTAssertTrue(accepted, "\(mode) accepted \(path)")
        } catch {
          XCTAssertFalse(accepted, String(describing: error))
          XCTAssertEqual(error as? NativeHandoffValidationError, .invalidTarget)
        }
      }
    }

    func testAMachOHandoffChecksTheConfinedStage2ItWroteToTheESP() async throws {
      for onESP in [true, false] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        let bytes = Data("confined stage two".utf8)
        try fixture.writeMachOInstallation(confined: bytes)
        if !onESP {
          try FileManager.default.removeItem(
            at: fixture.esp.appendingPathComponent(AuraStage1Format.confinedStage2Path))
        }
        do {
          let result = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture", fullReadback: false)
          XCTAssertTrue(onESP, "The handoff accepted an ESP without the confined Stage 2")
          XCTAssertEqual(
            try AppleInstallerTrustCore().validateEngineTranscript(result).completion,
            .awaitingRecovery)
          XCTAssertEqual(try fixture.journalSnapshot().state, .complete)
        } catch {
          // A missing file can't be read back, which refuses it like changed content.
          XCTAssertFalse(onESP, String(describing: error))
          XCTAssertNotNil(error as? NativeHandoffValidationError, String(describing: error))
          XCTAssertNotEqual(try fixture.journalSnapshot().state, .complete)
        }
      }
    }

    func testHandoffLayoutKeepsTheConfinedStage2OfAPaddedMachOStage1() throws {
      // The handoff re-derives the ESP layout the installer wrote. For a padded
      // Mach-O Stage 1 that layout has m1n1/boot-ctxr.bin; without it, the file
      // the installer wrote looks foreign and the handoff refuses.
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      let evidence = try NativeHandoffEvidence(
        snapshot: fixture.journalSnapshot(),
        metadata: Data((fixture.vector["metadata"] as! String).utf8))
      let members = Set(
        (fixture.vector["espFiles"] as! [String: String]).keys.map { "esp/" + $0 }
          + ["esp/m1n1/boot-ctxr.bin"])
      let firmware = evidence.qualifiedCommonFirmware.first ?? "26.6.2"
      let padded = try evidence.espLayout(
        members: members, firmware: firmware, executeWindow: true)
      XCTAssertEqual(padded["esp/m1n1/boot-ctxr.bin"], AuraStage1Format.confinedStage2Path)
      XCTAssertEqual(padded["esp/m1n1/boot.bin"], AuraStage1Format.standardStage2Path)
      let raw = try evidence.espLayout(members: members, firmware: firmware, executeWindow: false)
      XCTAssertNil(raw["esp/m1n1/boot-ctxr.bin"])
      XCTAssertFalse(raw.values.contains(AuraStage1Format.confinedStage2Path))
    }

    func testUnknownMissingOrNonStringBootModeNeverSelectsRecovery() async throws {
      for mode: Any in ["unknown", "MachO", "", 1, NSNull()] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        let url = fixture.system.appendingPathComponent(
          "Aurora/Recovery/InstallData/install-config.json")
        var config = fixture.vector["config"] as! [String: Any]
        config["bootMode"] = mode is NSNull ? nil : mode
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: url)
        do {
          _ = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture", fullReadback: false)
          XCTFail("Invalid boot mode was accepted")
        } catch {
          XCTAssertEqual(error as? NativeHandoffValidationError, .invalidTarget)
        }
        XCTAssertEqual(fixture.blessCalls, 0)
        XCTAssertEqual(try fixture.journalSnapshot().state, .started)
      }
    }

    func testOldNeoCommonPayloadCannotCompleteRecoveryWithTheWrongBootMember() async throws {
      for index in [0, 4] {
        let fixture = try NativeRecoveryHandoffFixture(index)
        defer { fixture.remove() }
        do {
          _ = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture",
            fullReadback: false)
          XCTFail("Old Neo boot member was accepted")
        } catch {
          XCTAssertEqual(error as? NativeHandoffValidationError, .changedContent)
        }
        XCTAssertEqual(fixture.blessCalls, 0)
      }
    }

    func testFailedAuthorizationPreservesAnEightRecordRetryAndRetryRechecksAllImages() async throws
    {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      fixture.rejectBless = true
      do {
        _ = try await fixture.executor().execute(
          package: fixture.package, journal: fixture.journalURL,
          authorization: fixture.authorization(), requirement: "fixture", fullReadback: false)
        XCTFail("Expected authorization failure")
      } catch {
        XCTAssertEqual(error as? NativeInstallerExecutionError, .recoveryAuthorizationFailed)
      }
      XCTAssertEqual(try fixture.journalSnapshot().state, .started)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.activeVersion.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.disabledVersion.path))
      fixture.rejectBless = false
      fixture.rawReads = []
      _ = try await fixture.executor().execute(
        package: fixture.package, journal: fixture.journalURL,
        authorization: fixture.authorization(), requirement: "fixture", fullReadback: true)
      XCTAssertEqual(fixture.rawReads, ["disk0s6", "disk0s7"])
      XCTAssertEqual(fixture.blessCalls, 2)
      XCTAssertEqual(try fixture.journalSnapshot().state, .complete)
    }

    func testReadyStartedAndPreparedStatesCanResumeButCompletionIsNeverReauthorized() async throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      let checker = NativeInstallerExecutor(effectiveUserID: { 0 })
      let identity = InstallerJobPlanIdentity(package: fixture.package)
      XCTAssertTrue(checker.canRetryRecoveryAuthorization(identity, in: fixture.root))
      var journal: NativeRecoveryJournal? = try NativeRecoveryJournal(
        url: fixture.journalURL,
        package: fixture.package, owner: geteuid())
      try journal?.beginHandoff()
      XCTAssertTrue(checker.canRetryRecoveryAuthorization(identity, in: fixture.root))
      try journal?.recordPrepared()
      XCTAssertEqual(try journal?.snapshot().state, .prepared)
      XCTAssertTrue(checker.canRetryRecoveryAuthorization(identity, in: fixture.root))
      // Simulate interruption after a durable prepared checkpoint, before completion.
      journal = nil
      fixture.rejectBless = true
      fixture.rejectSignature = true
      let result = try await fixture.executor().execute(
        package: fixture.package,
        journal: fixture.journalURL, authorization: fixture.authorization(), requirement: "fixture",
        fullReadback: true)
      XCTAssertEqual(
        try AppleInstallerTrustCore().validateEngineTranscript(result).completion, .awaitingRecovery
      )
      XCTAssertEqual(fixture.blessCalls, 0)
      XCTAssertTrue(fixture.rawReads.isEmpty)
      XCTAssertFalse(checker.canRetryRecoveryAuthorization(identity, in: fixture.root))
    }

    func testNativeRetryDoesNotNeedTheBackendDecoderOrFirmwarePreparation() async throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      var journal: NativeRecoveryJournal? = try NativeRecoveryJournal(
        url: fixture.journalURL,
        package: fixture.package, owner: geteuid())
      try journal?.beginHandoff()
      journal = nil
      let pinned = NativeInstallerExecutor(
        effectiveUserID: { 0 },
        verifyRestoreImage: { _, _ in throw NativeHandoffValidationError.invalidTarget },
        firmwarePreparer: ForbiddenFirmwarePreparation(), nativeHandoff: fixture.executor(),
        prepareRecoveryTemplate: { package in
          let directory = package.packageURL.deletingLastPathComponent().appendingPathComponent(
            "prepared-recovery")
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          return PreparedNativeRecoveryTemplate(
            directory: directory,
            app: directory.appendingPathComponent("fixture.app"),
            manifest: directory.appendingPathComponent("manifest.json"), requirement: "fixture")
        })
      let result = try await pinned.execute(
        fixture.package, authorization: fixture.authorization(),
        operation: .retryRecoveryAuthorization)
      XCTAssertEqual(
        try AppleInstallerTrustCore().validateEngineTranscript(result).completion, .awaitingRecovery
      )
      XCTAssertEqual(fixture.rawReads, ["disk0s6", "disk0s7"])
    }

    func testChangedContentSourceOwnerSignatureOrStartupReadbackNeverClaimsCompletion() async throws
    {
      for fault in [
        "icon", "efi", "root", "owner", "signature", "startup", "mount", "layout", "device",
        "media",
      ] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        switch fault {
        case "icon":
          try Data("changed".utf8).write(
            to: fixture.system.appendingPathComponent(".VolumeIcon.icns"))
        case "efi":
          try Data("changed".utf8).write(to: fixture.esp.appendingPathComponent("m1n1/boot.bin"))
        case "root": fixture.rejectRoot = true
        case "owner": fixture.rejectOwner = true
        case "signature": fixture.rejectSignature = true
        case "startup": fixture.rejectStartup = true
        case "mount": fixture.rejectMount = true
        case "device": fixture.observedDevice = "apple,j614s"
        case "media":
          try FileManager.default.removeItem(
            at: fixture.system.appendingPathComponent(".IAPhysicalMedia"))
        default: fixture.rejectLayout = true
        }
        do {
          _ = try await fixture.executor().execute(
            package: fixture.package, journal: fixture.journalURL,
            authorization: fixture.authorization(), requirement: "fixture", fullReadback: true)
          XCTFail("Expected rejection: \(fault)")
        } catch {}
        XCTAssertEqual(try fixture.journalSnapshot().state, .started, fault)
        XCTAssertEqual(fixture.blessCalls, fault == "startup" ? 1 : 0, fault)
      }
    }

    func testJournalExcludesConcurrentWritersAndRejectsDamagedOrForeignEvidence() throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      var first: NativeRecoveryJournal? = try NativeRecoveryJournal(
        url: fixture.journalURL,
        package: fixture.package, owner: geteuid())
      XCTAssertThrowsError(
        try NativeRecoveryJournal(
          url: fixture.journalURL,
          package: fixture.package, owner: geteuid())
      ) {
        XCTAssertEqual($0 as? NativeRecoveryJournalError, .busy)
      }
      try first?.beginHandoff()
      first = nil
      let file = URL(fileURLWithPath: fixture.journalURL.path + ".stub-and-esp-installed.evidence")
      try Data("changed".utf8).write(to: file)
      XCTAssertThrowsError(
        try NativeRecoveryJournal(
          url: fixture.journalURL,
          package: fixture.package, owner: geteuid()))
    }

    func testEvidencePublicationIsPrivateAndExclusiveAndReusesAnIdenticalOrphan() throws {
      for change in [false, true] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        let journal = try NativeRecoveryJournal(
          url: fixture.journalURL, package: fixture.package, owner: geteuid())
        try journal.beginHandoff()
        let evidence = URL(
          fileURLWithPath: fixture.journalURL.path + ".recovery-handoff-prepared.evidence")
        let bytes = NativeRecoveryJournalSnapshot.handoffEvidence(fixture.package.planDigest)
        try (change ? Data("changed".utf8) : bytes).write(to: evidence)
        XCTAssertEqual(chmod(evidence.path, 0o600), 0)
        if change {
          XCTAssertThrowsError(try journal.recordPrepared())
        } else {
          try journal.recordPrepared()
          var status = stat()
          XCTAssertEqual(lstat(evidence.path, &status), 0)
          XCTAssertEqual(status.st_nlink, 1)
          XCTAssertEqual(status.st_mode & 0o777, 0o600)
          _ = try journal.complete()
        }
      }
    }

    func testProtectedFilenameTransitionsAcceptMountRootModeButRejectLinksAndWritableChildren()
      throws
    {
      for fault in ["none", "directory", "symlink", "both-versions", "wrong-device"] {
        let fixture = try NativeRecoveryHandoffFixture()
        defer { fixture.remove() }
        switch fault {
        case "directory":
          XCTAssertEqual(chmod(fixture.system.appendingPathComponent("System").path, 0o775), 0)
        case "symlink":
          try FileManager.default.removeItem(at: fixture.activeVersion)
          try FileManager.default.createSymbolicLink(
            at: fixture.activeVersion,
            withDestinationURL: fixture.system.appendingPathComponent(".VolumeIcon.icns"))
        case "both-versions": try Data("other".utf8).write(to: fixture.disabledVersion)
        case "wrong-device": fixture.rejectMount = true
        default: break
        }
        do {
          let tree = try NativeHandoffFileTree(
            fixture.system, protected: true, owner: geteuid(),
            volumeRoot: true, volumeDevice: "disk8s1",
            verifyMount: fixture.environment().verifyMount)
          try tree.prepareForRecovery()
          try tree.prepareForAuthorization()
          if fault != "none" { XCTFail("Expected refusal: \(fault)") }
        } catch { if fault == "none" { throw error } }
      }
    }
    func testDisabledMediaNameIsRestoredAndMountRootExceptionRequiresVolumeVerification() throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      XCTAssertThrowsError(
        try NativeHandoffFileTree(fixture.system, protected: true, owner: geteuid()))
      XCTAssertThrowsError(
        try NativeHandoffFileTree(
          fixture.system, protected: true, owner: geteuid(), volumeRoot: true))
      let inactive = fixture.system.appendingPathComponent("IAPhysicalMedia-disabled.plist")
      let active = fixture.system.appendingPathComponent(".IAPhysicalMedia")
      try FileManager.default.moveItem(at: active, to: inactive)
      let tree = try NativeHandoffFileTree(
        fixture.system, protected: true, owner: geteuid(), volumeRoot: true,
        volumeDevice: "disk8s1", verifyMount: fixture.environment().verifyMount)
      _ = try tree.handoffVersion()
      try tree.prepareForRecovery()
      XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: inactive.path))
    }

    func testIdenticalNamePairsFromTheDeferredRecoveryLauncherAreAccepted() throws {
      let fixture = try NativeRecoveryHandoffFixture()
      defer { fixture.remove() }
      let inactive = fixture.system.appendingPathComponent("IAPhysicalMedia-disabled.plist")
      let active = fixture.system.appendingPathComponent(".IAPhysicalMedia")
      try FileManager.default.copyItem(at: active, to: inactive)
      try FileManager.default.copyItem(at: fixture.activeVersion, to: fixture.disabledVersion)
      let tree = try NativeHandoffFileTree(
        fixture.system, protected: true, owner: geteuid(), volumeRoot: true,
        volumeDevice: "disk8s1", verifyMount: fixture.environment().verifyMount)
      _ = try tree.handoffVersion()
      try tree.prepareForRecovery()
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeVersion.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.disabledVersion.path))
      XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: inactive))
      try tree.prepareForAuthorization()
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.activeVersion.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.disabledVersion.path))
      try tree.prepareForRecovery()
      XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: inactive))
    }
  }

  final class NativeRecoveryHandoffFixture: @unchecked Sendable {
    let root: URL
    let system: URL
    let esp: URL
    let sourcePreboot: URL
    let package: ImportedEngineHandoffPackage
    let journalURL: URL
    let vector: [String: Any]
    let diskSnapshot: RemovalSnapshot
    var rawReads = [String]()
    var blessCalls = 0
    var rejectBless = false, rejectRoot = false, rejectOwner = false, rejectSignature = false
    var rejectStartup = false, rejectMount = false, rejectLayout = false
    var observedDevice: String?
    var activeVersion: URL {
      system.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
    }
    var disabledVersion: URL {
      system.appendingPathComponent("System/Library/CoreServices/SystemVersion-disabled.plist")
    }

    init(_ index: Int = 1) throws {
      let resources = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
      let document =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf:
              resources.appendingPathComponent("native-handoff-vectors.json"))) as! [String: Any]
      vector = (document["vectors"] as! [[String: Any]])[index]
      diskSnapshot = try JSONDecoder().decode(
        RemovalSnapshot.self,
        from: JSONSerialization.data(withJSONObject: vector["snapshot"]!))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "native-handoff-" + UUID().uuidString)
      let volumes = root.appendingPathComponent("Volumes")
      system = volumes.appendingPathComponent("Fedora")
      esp = volumes.appendingPathComponent("EFI")
      sourcePreboot = root.appendingPathComponent("System/Volumes/Preboot")
      let imported = root.appendingPathComponent("imported-handoff-fixture")
      for directory in [
        root, volumes, system, esp, root.appendingPathComponent("System"),
        root.appendingPathComponent("System/Volumes"), sourcePreboot, imported,
        root.appendingPathComponent("execution-journals"),
      ] {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
      let metadata = imported.appendingPathComponent("metadata.json")
      let payload = imported.appendingPathComponent("payload.zip")
      try Data((vector["metadata"] as! String).utf8).write(to: metadata)
      try Data(contentsOf: resources.appendingPathComponent("native-handoff-payload.zip")).write(
        to: payload)
      XCTAssertEqual(chmod(metadata.path, 0o400), 0)
      XCTAssertEqual(chmod(payload.path, 0o400), 0)
      let binding = "sha256:" + String(repeating: "b", count: 64)
      package = ImportedEngineHandoffPackage(
        packageURL: imported, manifestURL: imported,
        requestURL: imported, identityURL: imported,
        metadataURL: metadata, payloadURL: payload, bindingDigest: binding,
        planDigest: vector["planDigest"] as! String, deviceIdentifier: vector["device"] as! String,
        storeIdentifier: "disk0",
        installationIntent: vector["intent"] as? String == "replace" ? .replace : .fresh)
      journalURL = root.appendingPathComponent(
        "execution-journals/" + String(repeating: "b", count: 64) + ".jsonl")
      try Data((vector["transcript"] as! String).utf8).write(to: journalURL)
      XCTAssertEqual(chmod(journalURL.path, 0o600), 0)
      for (name, value) in vector["evidence"] as! [String: String] {
        let path = URL(fileURLWithPath: journalURL.path + "." + name + ".evidence")
        try Data(value.utf8).write(to: path)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
      }
      func write(_ bytes: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o755])
        try bytes.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
      }
      try write(
        JSONSerialization.data(withJSONObject: vector["config"]!, options: [.sortedKeys]),
        system.appendingPathComponent("Aurora/Recovery/InstallData/install-config.json"))
      try write(
        Data(base64Encoded: vector["icon"] as! String)!,
        system.appendingPathComponent(".VolumeIcon.icns"))
      try write(
        PropertyListSerialization.data(
          fromPropertyList: ["ProductVersion": "26.6.2"],
          format: .binary, options: 0), activeVersion)
      try write(Data("media".utf8), system.appendingPathComponent(".IAPhysicalMedia"))
      let config = vector["config"] as! [String: Any]
      let bootstrap = config["bootstrap"] as! [String: Any]
      try write(
        PropertyListSerialization.data(
          fromPropertyList: ["mina": ["GeneratedUID": vector["ownerUUID"]!]], format: .binary,
          options: 0),
        sourcePreboot.appendingPathComponent(
          (bootstrap["sourceGroupUUID"] as! String) + "/var/db/AdminUserRecoveryInfo.plist"))
      for (path, bytes) in vector["espFiles"] as! [String: String] {
        try write(Data(base64Encoded: bytes)!, esp.appendingPathComponent(path))
      }
      // Normal mounted System roots may be root:admin 0775.
      XCTAssertEqual(chmod(system.path, 0o775), 0)
      XCTAssertEqual(chmod(sourcePreboot.path, 0o775), 0)
    }

    /// What a padded Mach-O installation leaves: the configuration naming
    /// m1n1/boot-ctxr.bin, the file in the payload and on the ESP, and the ESP
    /// evidence and its checkpoint counting it.
    func writeMachOInstallation(confined: Data) throws {
      let member = "esp/" + AuraStage1Format.confinedStage2Path
      let work = root.appendingPathComponent("payload-work")
      let file = work.appendingPathComponent(member)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try confined.write(to: file)
      XCTAssertEqual(chmod(package.payloadURL.path, 0o600), 0)
      let zip = Process()
      zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      zip.arguments = ["-q", "-X", "-0", package.payloadURL.path, member]
      zip.currentDirectoryURL = work
      try zip.run()
      zip.waitUntilExit()
      XCTAssertEqual(zip.terminationStatus, 0)
      XCTAssertEqual(chmod(package.payloadURL.path, 0o400), 0)
      try confined.write(to: esp.appendingPathComponent(AuraStage1Format.confinedStage2Path))
      var config = vector["config"] as! [String: Any]
      config["bootMode"] = "macho"
      config["stage2Path"] = AuraStage1Format.confinedStage2Path
      try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(
        to: system.appendingPathComponent("Aurora/Recovery/InstallData/install-config.json"))
      // The tree hash the handoff recomputes, over the layout a padded Stage 1 gets.
      let evidence = try NativeHandoffEvidence(
        snapshot: journalSnapshot(), metadata: Data((vector["metadata"] as! String).utf8))
      let names = Set(
        (vector["espFiles"] as! [String: String]).keys.map { "esp/" + $0 }
          + ["esp/m1n1/boot-j700.bin", "esp/m1n1/boot.bin", "esp/aurora/stage1.bin", member])
      let layout = try evidence.espLayout(members: names, firmware: "26.6.2", executeWindow: true)
      var tree = SHA256()
      var installed: UInt64 = 0
      for name in layout.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
        let bytes = try Data(contentsOf: esp.appendingPathComponent(layout[name]!))
        var length = UInt64(name.utf8.count).bigEndian
        tree.update(data: withUnsafeBytes(of: &length) { Data($0) })
        tree.update(data: Data(name.utf8))
        tree.update(data: Data(SHA256.hash(data: bytes)))
        installed += UInt64(bytes.count)
      }
      let evidenceName = "stub-and-esp-installed"
      let evidenceURL = URL(fileURLWithPath: journalURL.path + "." + evidenceName + ".evidence")
      let old = try Data(contentsOf: evidenceURL)
      var record = try JSONSerialization.jsonObject(with: old) as! [String: Any]
      var partitions = record["populated_partitions"] as! [[String: Any]]
      partitions[0]["content_sha256"] = tree.finalize().map { String(format: "%02x", $0) }
        .joined()
      partitions[0]["installed_bytes"] = installed
      record["populated_partitions"] = partitions
      let updated = try JSONSerialization.data(
        withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
      XCTAssertEqual(chmod(evidenceURL.path, 0o600), 0)
      try updated.write(to: evidenceURL)
      XCTAssertEqual(chmod(evidenceURL.path, 0o600), 0)
      func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      let journal = try String(contentsOf: journalURL, encoding: .utf8)
      XCTAssertTrue(journal.contains(digest(old)))
      try journal.replacingOccurrences(of: digest(old), with: digest(updated)).write(
        to: journalURL, atomically: false, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(username: "mina", password: Data("owner-password".utf8))
    }
    func journalSnapshot() throws -> NativeRecoveryJournalSnapshot {
      let bytes = try Data(contentsOf: journalURL)
      return try NativeRecoveryJournalSnapshot.decode(bytes, package: package) {
        try Data(contentsOf: URL(fileURLWithPath: self.journalURL.path + "." + $0 + ".evidence"))
      }
    }
    func environment() -> NativeHandoffEnvironment {
      NativeHandoffEnvironment(
        snapshot: {
          var result = self.diskSnapshot
          if self.rejectLayout { result.partitions[3].size += 4096 }
          return result
        }, device: { self.observedDevice ?? self.package.deviceIdentifier },
        command: { try self.command($0, $1) },
        ownerUUID: { _ in self.rejectOwner ? UUID().uuidString : self.vector["ownerUUID"] as! String
        },
        rawDigest: { identifier, _ in
          self.rawReads.append(identifier)
          return self.rejectRoot && identifier == "disk0s7"
            ? String(repeating: "d", count: 64)
            : (self.vector["rawDigests"] as! [String: String])[identifier]!
        },
        verifyRecovery: { _, requirement in
          XCTAssertEqual(requirement, "fixture")
          if self.rejectSignature { throw NativeHandoffValidationError.invalidTarget }
        }, owner: geteuid(), mountRoot: root.appendingPathComponent("Volumes"),
        sourcePrebootMount: sourcePreboot,
        verifyMount: { fd, url, device in
          let paths = ["disk8s1": self.system, "disk0s5": self.esp, "disk4s3": self.sourcePreboot]
          var opened = stat()
          var named = stat()
          guard !self.rejectMount, paths[device]?.path == url.path, fstat(fd, &opened) == 0,
            lstat(url.path, &named) == 0, opened.st_ino == named.st_ino
          else {
            throw NativeHandoffValidationError.invalidTarget
          }
        })
    }
    func executor() -> NativeRecoveryHandoffExecutor {
      let platform = NativeRecoveryHandoffPlatform(
        environment: environment(),
        bless: { arguments, input, secret in
          self.blessCalls += 1
          XCTAssertEqual(
            arguments, ["--setBoot", "--device", "/dev/disk8s1", "--user", "mina", "--stdinpass"])
          XCTAssertEqual(input, Data("owner-password\n".utf8))
          XCTAssertEqual(secret, Data("owner-password".utf8))
          if self.rejectBless { throw NativeHandoffValidationError.authorizationFailed }
        })
      return NativeRecoveryHandoffExecutor(platform: platform, owner: geteuid())
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> Data {
      let config = vector["config"] as! [String: Any]
      let bootstrap = config["bootstrap"] as! [String: Any]
      func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
      }
      if executable == "/sbin/mount", arguments == ["-u", "-w", system.path] { return Data() }
      if executable == "/usr/sbin/bless", arguments == ["--getBoot", "--plist"] {
        return try plist(["Boot Volume": "selected-target"])
      }
      if executable == "/usr/sbin/diskutil",
        arguments == ["apfs", "listUsers", bootstrap["sourceSystemUUID"] as! String, "-plist"]
      {
        return try plist([
          "Users": [["APFSCryptoUserUUID": vector["ownerUUID"]!, "VolumeOwner": true]]
        ])
      }
      guard executable == "/usr/sbin/diskutil", arguments.count == 3,
        Array(arguments.prefix(2)) == ["info", "-plist"]
      else { throw NativeHandoffValidationError.invalidTarget }
      let name = arguments[2]
      if name == "/" {
        return try plist([
          "APFSVolumeGroupID": bootstrap["sourceGroupUUID"]!, "APFSContainerReference": "disk4",
        ])
      }
      if name == "disk4s1" {
        return try plist([
          "VolumeUUID": bootstrap["sourceSystemUUID"]!,
          "APFSVolumeGroupID": bootstrap["sourceGroupUUID"]!,
          "APFSContainerReference": "disk4",
        ])
      }
      if name == "selected-target" {
        return try plist([
          "APFSVolumeGroupID": rejectStartup ? UUID().uuidString : config["groupUUID"]!
        ])
      }
      if name == "disk8s1" {
        return try plist([
          "VolumeUUID": config["systemUUID"]!, "APFSVolumeGroupID": config["groupUUID"]!,
          "APFSContainerReference": "disk8", "MountPoint": system.path,
        ])
      }
      if name == diskSnapshot.containers[1].volumes[1].uuid
        || name == config["prebootUUID"] as? String
      {
        return try plist(["APFSContainerReference": "disk8"])
      }
      if name == "disk4s3" {
        return try plist([
          "VolumeUUID": diskSnapshot.containers[0].volumes[2].uuid,
          "MountPoint": sourcePreboot.path,
        ])
      }
      if name == "disk0s5" {
        return try plist(["DiskUUID": config["espUUID"]!, "MountPoint": esp.path])
      }
      throw NativeHandoffValidationError.invalidTarget
    }

  }
#endif
