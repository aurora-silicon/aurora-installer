#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class PinnedAsahiEngineExecutorTests: XCTestCase {
    private struct FixtureNativeHandoff: NativeRecoveryHandoffExecuting {
      func execute(
        package: ImportedEngineHandoffPackage, journal: URL,
        authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool
      ) async throws -> Data {
        try Data(
          contentsOf: package.packageURL.deletingLastPathComponent()
            .appendingPathComponent("native-transcript.jsonl"))
      }
    }

    private struct RefusingPreservedReinstall: NativePreservedReinstallExecuting {
      func execute(
        _ package: ImportedEngineHandoffPackage, journal: URL,
        authorization: MachineOwnerAuthorization, installConf: InstallConf
      ) async throws -> Data {
        throw PinnedAsahiEngineExecutionError.nativeReinstallUnavailable
      }
    }

    private struct FirmwareTooOldPreservedReinstall: NativePreservedReinstallExecuting {
      func execute(
        _ package: ImportedEngineHandoffPackage, journal: URL,
        authorization: MachineOwnerAuthorization, installConf: InstallConf
      ) async throws -> Data {
        throw NativeFirmwareSelectionError.macOSUpdateRequired(version: "14.8.3")
      }
    }

    private struct MarkerPreservedReinstall: NativePreservedReinstallExecuting {
      let marker: URL
      func execute(
        _ package: ImportedEngineHandoffPackage, journal: URL,
        authorization: MachineOwnerAuthorization, installConf: InstallConf
      ) async throws -> Data {
        try installConf.serializedData.write(to: marker)
        return Data("native preserved transcript\n".utf8)
      }
    }

    func testPreservedReinstallCannotFallThroughToFreshDiskExecution()
      async throws
    {
      let fixture = try makeFixture(installationIntent: .reinstall)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError, .nativeReinstallUnavailable)
      }
    }

    func testPreservedReinstallUsesItsNativeCoordinator() async throws {
      let fixture = try makeFixture(installationIntent: .reinstall)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let marker = fixture.root.appendingPathComponent("preserved")
      let executor = fixtureExecutor(
        effectiveUserID: { 0 },
        preservedReinstall: MarkerPreservedReinstall(marker: marker))
      let configuration = try InstallConf(encrypt: true, lane: "stable")
      let result = try await executor.execute(
        fixture.package, authorization: try machineOwnerAuthorization(),
        operation: .install, installConf: configuration)
      XCTAssertEqual(result, Data("native preserved transcript\n".utf8))
      XCTAssertEqual(try Data(contentsOf: marker), configuration.serializedData)
    }

    func testPreservedReinstallOnOlderFirmwareNamesTheMacOSToInstall() async throws {
      let fixture = try makeFixture(installationIntent: .reinstall)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, preservedReinstall: FirmwareTooOldPreservedReinstall())
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package, authorization: try machineOwnerAuthorization(),
          operation: .install, installConf: try InstallConf(encrypt: true, lane: "stable"))
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected typed firmware refusal")
          return
        }
        XCTAssertEqual(report.notice.reason, .macOSUpdateRequired)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(report.notice.summary, "This Mac needs macOS 14.8.3 or later.")
      }
    }

    private struct FirmwareMarker: NativeFirmwarePreparing {
      let url: URL
      func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
        try Data("prepared".utf8).write(to: url)
        return nil
      }
    }
    private struct RawFirmwareFixture: NativeFirmwarePreparing {
      let url: URL
      func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        return url
      }
    }
    private struct ConvertedPeripheralFixture: NativePeripheralPreparing {
      let url: URL
      func prepare(package: ImportedEngineHandoffPackage, rawDirectory: URL) async throws
        -> PreparedNativePeripheralInputs
      {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        return try PreparedNativePeripheralInputs(
          directory: url, recipeSHA256: String(repeating: "a", count: 64), owner: geteuid())
      }
    }

    private struct NoNativeESPFixture: NativeESPFilesPreparing {
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeESPFilesExecuting
      )? { nil }
    }

    private struct FailingNativePartitionsFixture: NativeOSPartitionsPreparing {
      func preflight(_ package: ImportedEngineHandoffPackage) throws
        -> any NativeOSPartitionsExecuting
      { throw NativeHandoffValidationError.invalidTarget }
    }

    private struct FailingNativeImagesFixture: NativePayloadImagesPreparing {
      func preflight(_ package: ImportedEngineHandoffPackage) async throws
        -> any NativePayloadImagesExecuting
      { throw NativeHandoffValidationError.invalidTarget }
    }

    private struct NativeESPFixture: NativeESPFilesPreparing, NativeESPFilesExecuting {
      let marker: URL
      let images: URL
      var requiresNativeFinishing = false
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeESPFilesExecuting
      )? { self }
      func prepare(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap
      ) async throws {
        guard FileManager.default.fileExists(atPath: images.path) else {
          throw NativeHandoffValidationError.invalidTarget
        }
        try Data("ESP prepared".utf8).write(to: marker)
      }
    }

    private struct NativeFinishingFixture: NativeInstallationFinishingPreparing,
      NativeInstallationFinishing
    {
      let esp: URL
      let marker: URL
      func preflight(
        package: ImportedEngineHandoffPackage, stub: NativeStubFilePlan?,
        peripherals: PreparedNativePeripheralInputs?
      ) throws -> (any NativeInstallationFinishing)? { self }
      func prepare(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap, recovery: PreparedNativeRecoveryTemplate
      ) async throws {
        guard FileManager.default.fileExists(atPath: esp.path) else {
          throw NativeHandoffValidationError.invalidTarget
        }
        try Data("native finishing".utf8).write(to: marker)
      }
    }

    func testCompleteNativeClosureRunsEveryStageAndTheNativeHandoff() async throws {
      let fixture = try makeFixture(
        transcript: NativeAdmissionTestData.journal(stages: 2))
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let apfs = fixture.root.appendingPathComponent("apfs")
      let files = fixture.root.appendingPathComponent("files")
      let partitions = fixture.root.appendingPathComponent("partitions")
      let images = fixture.root.appendingPathComponent("images")
      let esp = fixture.root.appendingPathComponent("esp")
      let finished = fixture.root.appendingPathComponent("finished")
      let legacyESP = NativeESPFixture(
        marker: esp, images: images, requiresNativeFinishing: true)
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, apfsPreparer: NativeAPFSFixture(marker: apfs),
        stubFilesPreparer: NativeFilesFixture(marker: files, apfs: apfs),
        osPartitionsPreparer: NativePartitionsFixture(marker: partitions, files: files),
        payloadImagesPreparer: NativeImagesFixture(marker: images, partitions: partitions),
        espFilesPreparer: legacyESP,
        installationFinisher: NativeFinishingFixture(esp: esp, marker: finished))
      let transcript = try await executor.execute(
        fixture.package, authorization: machineOwnerAuthorization())
      _ = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
      XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }

    func testEveryIncompleteNativeClosureRefusesBeforeDiskMutation()
      async throws
    {
      for missing in ["apfs", "stub", "partitions", "images", "esp", "finish"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let apfs = fixture.root.appendingPathComponent("apfs")
        let files = fixture.root.appendingPathComponent("files")
        let partitions = fixture.root.appendingPathComponent("partitions")
        let images = fixture.root.appendingPathComponent("images")
        let esp = fixture.root.appendingPathComponent("esp")
        let finished = fixture.root.appendingPathComponent("finished")
        let apfsPreparer: any NativeAPFSPreparing =
          missing == "apfs" ? NoNativeAPFSFixture() : NativeAPFSFixture(marker: apfs)
        let stubPreparer: any NativeStubFilesPreparing =
          missing == "stub"
          ? NoNativeStubFilesFixture()
          : NativeFilesFixture(marker: files, apfs: apfs)
        let partitionsPreparer: any NativeOSPartitionsPreparing =
          missing == "partitions"
          ? FailingNativePartitionsFixture()
          : NativePartitionsFixture(marker: partitions, files: files)
        let imagesPreparer: any NativePayloadImagesPreparing =
          missing == "images"
          ? FailingNativeImagesFixture()
          : NativeImagesFixture(marker: images, partitions: partitions)
        let espPreparer: any NativeESPFilesPreparing =
          missing == "esp"
          ? NoNativeESPFixture()
          : NativeESPFixture(marker: esp, images: images, requiresNativeFinishing: true)
        let finisher: any NativeInstallationFinishingPreparing =
          missing == "finish"
          ? NativeInstallationFinisher(enabled: false)
          : NativeFinishingFixture(esp: esp, marker: finished)
        let executor = fixtureExecutor(
          effectiveUserID: { 0 }, apfsPreparer: apfsPreparer,
          stubFilesPreparer: stubPreparer, osPartitionsPreparer: partitionsPreparer,
          payloadImagesPreparer: imagesPreparer, espFilesPreparer: espPreparer,
          installationFinisher: finisher)

        await assertThrowsErrorAsync(
          try await executor.execute(fixture.package, authorization: machineOwnerAuthorization())
        ) {
          guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
          else { return XCTFail("Expected a native preflight failure for \(missing)") }
          XCTAssertEqual(report.notice.reason, .planIntegrity)
          XCTAssertTrue(report.notice.diskUnchanged)
        }
        for marker in [apfs, files, partitions, images, esp, finished] {
          XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
      }
    }

    func testLegacyESPWithoutNativeFinishingRefusesBeforeDiskChanges() async throws {
      let fixture = try makeFixture(
        transcript: NativeAdmissionTestData.journal())
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let apfs = fixture.root.appendingPathComponent("apfs")
      let files = fixture.root.appendingPathComponent("files")
      let partitions = fixture.root.appendingPathComponent("partitions")
      let images = fixture.root.appendingPathComponent("images")
      let esp = fixture.root.appendingPathComponent("esp")
      let legacyESP = NativeESPFixture(
        marker: esp, images: images, requiresNativeFinishing: true)
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, apfsPreparer: NativeAPFSFixture(marker: apfs),
        stubFilesPreparer: NativeFilesFixture(marker: files, apfs: apfs),
        osPartitionsPreparer: NativePartitionsFixture(marker: partitions, files: files),
        payloadImagesPreparer: NativeImagesFixture(marker: images, partitions: partitions),
        espFilesPreparer: legacyESP)
      do {
        _ = try await executor.execute(fixture.package, authorization: machineOwnerAuthorization())
        XCTFail("Legacy ESP reached disk execution")
      } catch let PinnedAsahiEngineExecutionError.engineFailed(report) {
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: apfs.path))
    }

    func testRequiredNativeClosureRefusesMissingStageBeforeDisk() async throws {
      let fixture = try makeFixture(
        transcript: NativeAdmissionTestData.journal())
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let marker = fixture.root.appendingPathComponent("finished")
      let executor = fixtureExecutor(
        effectiveUserID: { 0 },
        installationFinisher: NativeFinishingFixture(esp: marker, marker: marker))
      do {
        _ = try await executor.execute(fixture.package, authorization: machineOwnerAuthorization())
        XCTFail("Missing native stages reached execution")
      } catch let PinnedAsahiEngineExecutionError.engineFailed(report) {
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDisabledNativeFinisherRefusesFreshInstallation() async throws {
      let fixture = try makeFixture(transcript: NativeAdmissionTestData.journal())
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 },
        installationFinisher: NativeInstallationFinisher(enabled: false))
      do {
        _ = try await executor.execute(fixture.package, authorization: machineOwnerAuthorization())
        XCTFail("Fresh installation ran without native finishing")
      } catch let PinnedAsahiEngineExecutionError.engineFailed(report) {
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
    }

    private struct NativeImagesFixture: NativePayloadImagesPreparing, NativePayloadImagesExecuting {
      var marker: URL? = nil
      var partitions: URL? = nil
      func preflight(_ package: ImportedEngineHandoffPackage) async throws
        -> any NativePayloadImagesExecuting
      { self }
      func prepare(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap
      ) async throws {
        if let partitions {
          guard FileManager.default.fileExists(atPath: partitions.path) else {
            throw NativeRawImageError.invalidTarget
          }
        }
        if let marker { try Data("images prepared".utf8).write(to: marker) }
      }
    }

    private struct NativePartitionsFixture: NativeOSPartitionsPreparing, NativeOSPartitionsExecuting
    {
      var marker: URL? = nil
      var files: URL? = nil
      func preflight(_ package: ImportedEngineHandoffPackage) throws
        -> any NativeOSPartitionsExecuting
      { self }
      func prepare(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap
      ) throws {
        if let files {
          guard FileManager.default.fileExists(atPath: files.path) else {
            throw NativeOSPartitionError.changedLayout
          }
        }
        if let marker { try Data("partitions prepared".utf8).write(to: marker) }
      }
    }

    private struct NoNativeStubFilesFixture: NativeStubFilesPreparing {
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeStubFilesExecuting
      )? { nil }
    }

    private struct NoNativeAPFSFixture: NativeAPFSPreparing {
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeAPFSExecuting
      )? { nil }
    }

    private struct NativeAPFSFixture: NativeAPFSPreparing, NativeAPFSExecuting {
      let marker: URL
      var recordMutation = false
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeAPFSExecuting
      )? { self }
      func prepareTarget(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap
      ) throws {
        try Data("prepared".utf8).write(to: marker)
        if recordMutation {
          try NativeAdmissionTestData.journal(stages: 1).write(to: journal)
          let evidence = URL(fileURLWithPath: journal.path + ".apfs-target-prepared.evidence")
          try NativeAdmissionTestData.evidence.write(to: evidence)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: evidence.path)
        }
      }
    }

    private struct NativeFilesFixture: NativeStubFilesPreparing, NativeStubFilesExecuting {
      let marker: URL
      let apfs: URL
      func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
        any NativeStubFilesExecuting
      )? { self }
      func prepare(
        journal: URL, authorization: MachineOwnerAuthorization,
        sourceBootstrap: NativeSourceBootstrap
      ) async throws {
        guard FileManager.default.fileExists(atPath: apfs.path) else {
          throw NativeStubFileError.invalidPlan
        }
        try Data("files prepared".utf8).write(to: marker)
      }
    }

    func testMalformedRetainedJournalCannotBypassAdmissionOrClaimNoMutation() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let directory = fixture.root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let journal = directory.appendingPathComponent(String(repeating: "b", count: 64) + ".jsonl")
      try Data("{\"type\":\"plan\"}\n".utf8).write(to: journal)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          return XCTFail("Expected journal rejection")
        }
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertFalse(report.notice.diskUnchanged)
      }
      XCTAssertEqual(try Data(contentsOf: journal), Data("{\"type\":\"plan\"}\n".utf8))
    }

    func testARetiredEngineRepairJobAsksThePersonToStartOver() async throws {
      for operation in [EngineHandoffOperation.install, .retryRecoveryAuthorization] {
        let fixture = try makeFixture(installationIntent: .repair)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let apfs = fixture.root.appendingPathComponent("apfs")
        let firmware = fixture.root.appendingPathComponent("firmware")
        let executor = fixtureExecutor(
          effectiveUserID: { 0 }, firmwarePreparer: FirmwareMarker(url: firmware),
          apfsPreparer: NativeAPFSFixture(marker: apfs))
        await assertThrowsErrorAsync(
          try await executor.execute(
            fixture.package, authorization: try machineOwnerAuthorization(), operation: operation)
        ) {
          guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
          else { return XCTFail("Expected a start-over refusal") }
          XCTAssertEqual(report.notice.reason, .startOverRequired)
          XCTAssertEqual(report.notice.diskUnchanged, operation == .install)
          XCTAssertFalse(report.redactedStandardErrorTail.contains("owner-password"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: apfs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firmware.path))
      }
    }

    func testAnExistingInstallationIsReplacedOnlyThroughANativeStage() async throws {
      let fixture = try makeFixture(installationIntent: .replace)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
        else { return XCTFail("Expected a native-only refusal") }
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
    }

    func testDecoderAdmissionFailureStopsBeforeExtractionAndAttestsOnlyInitialNoMutation()
      async throws
    {
      for operation in [EngineHandoffOperation.install] {
        for rejection in ["missing", "requirement", "signature"] {
          let fixture = try makeFixture(includeDecoder: rejection != "missing")
          defer { try? FileManager.default.removeItem(at: fixture.root) }
          let requirement =
            rejection == "requirement"
            ? nil : RestoreImageHelper.adHocRequirement(codeHash: String(repeating: "a", count: 40))
          let executor = fixtureExecutor(
            effectiveUserID: { 0 }, restoreImageRequirement: requirement,
            rejectDecoder: rejection == "signature")
          await assertThrowsErrorAsync(
            try await executor.execute(
              fixture.package,
              authorization: try machineOwnerAuthorization(), operation: operation)
          ) {
            guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
              return XCTFail("Expected typed decoder admission failure")
            }
            XCTAssertEqual(report.notice.reason, .recoveryPreparation)
            XCTAssertEqual(report.notice.diskUnchanged, operation == .install)
          }
        }
      }
    }

    func testNonRootExecutionIsRejectedBeforeAnyFileAccess() async throws {
      let fixture = try makeFixture()
      try FileManager.default.removeItem(at: fixture.root)
      let executor = fixtureExecutor(effectiveUserID: { 501 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .privilegeRequired
        )
      }
    }

    func testAnOlderJobAwaitingRecoveryAuthorizationRequiresItsExactCheckpoints()
      async throws
    {
      // The journal an older installer left after its disk stages finished and
      // Recovery authorization did not. Retry continues it natively.
      let targetEvidence = checkpointFixture("target-readback")
      let installedEvidence = checkpointFixture("installed-readback")
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      try writeRetainedJournal(
        recoveryRetryTranscript(
          targetEvidence: targetEvidence, installedEvidence: installedEvidence),
        evidence: [
          "apfs-target-prepared": targetEvidence,
          "stub-and-esp-installed": installedEvidence,
        ],
        for: fixture.package)
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      XCTAssertTrue(
        executor.canRetryRecoveryAuthorization(
          InstallerJobPlanIdentity(package: fixture.package),
          in: fixture.package.packageURL.deletingLastPathComponent()))
      let journal = try XCTUnwrap(
        EngineJournalLocator.journalURL(
          workingDirectory: fixture.package.packageURL.deletingLastPathComponent(),
          bindingDigest: fixture.package.bindingDigest))
      let identity = InstallerJobPlanIdentity(package: fixture.package)
      XCTAssertTrue(
        executor.canResumeInterruptedRecoveryAuthorization(
          identity, in: fixture.package.packageURL.deletingLastPathComponent()))
      let descriptor = open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { close(descriptor) }
      XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
      XCTAssertFalse(
        executor.canResumeInterruptedRecoveryAuthorization(
          identity, in: fixture.package.packageURL.deletingLastPathComponent()))
      XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
      let evidence = URL(fileURLWithPath: journal.path + ".stub-and-esp-installed.evidence")
      XCTAssertEqual(chmod(evidence.path, 0o600), 0)
      try Data("changed evidence".utf8).write(to: evidence)
      XCTAssertFalse(
        executor.canRetryRecoveryAuthorization(
          InstallerJobPlanIdentity(package: fixture.package),
          in: fixture.package.packageURL.deletingLastPathComponent()))
      XCTAssertFalse(
        executor.canResumeInterruptedRecoveryAuthorization(
          identity, in: fixture.package.packageURL.deletingLastPathComponent()))
    }

    func testUnsafeExistingJournalDirectoryIsRejected() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let journalDirectory = fixture.root.appendingPathComponent(
        "execution-journals",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: journalDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: journalDirectory.path
      )
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .unsafeTranscript
        )
      }
    }

    private struct FailedFirmware: NativeFirmwarePreparing {
      func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
        throw CocoaError(
          .fileReadUnknown,
          userInfo: [NSLocalizedDescriptionKey: "owner-password extraction failed"])
      }
    }

    func testNativeFirmwareFailureAttestsNoMutationAndRedactsTheOwnerPassword() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware())
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package, authorization: try machineOwnerAuthorization()
        )
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected a typed firmware failure")
          return
        }
        XCTAssertEqual(report.notice.reason, .firmwarePreparation)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertFalse(report.redactedStandardErrorTail.contains("owner-password"))
      }
    }

    func testRecoveryAuthorizationRetryDoesNotRepeatNativeFirmwareDownloads() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(), rejectPayload: true,
        rejectSourceOwner: true)
      let result = try await executor.execute(
        fixture.package,
        authorization: try machineOwnerAuthorization(), operation: .retryRecoveryAuthorization)
      XCTAssertEqual(result, fixture.transcript)
    }

    func testPayloadPreflightFailureStopsBeforeFirmwareAndBackendExecution() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(), rejectPayload: true)
      await assertThrowsErrorAsync(
        try await executor.execute(fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected typed payload preflight failure")
          return
        }
        XCTAssertEqual(report.notice.reason, .planIntegrity)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(report.notice.summary, "The installation images could not be verified.")
      }
    }

    func testIncompatibleBootFirmwareHasAFirmwarePreparationFailureBeforeLaunch() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(),
        rejectFirmwareSelection: .noCompatibleFirmware)
      await assertThrowsErrorAsync(
        try await executor.execute(fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected typed firmware preflight failure")
          return
        }
        XCTAssertEqual(report.notice.reason, .firmwarePreparation)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(report.notice.summary, "Compatible boot firmware could not be selected.")
      }
    }

    func testFirmwareOlderThanTheReleaseNamesTheMacOSToInstallBeforeLaunch() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(),
        rejectFirmwareSelection: .macOSUpdateRequired(version: "26.6.2"))
      await assertThrowsErrorAsync(
        try await executor.execute(fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected typed firmware refusal")
          return
        }
        XCTAssertEqual(report.notice.reason, .macOSUpdateRequired)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(report.notice.summary, "This Mac needs macOS 26.6.2 or later.")
        XCTAssertEqual(
          EngineFailureReason.requiredMacOSVersion(inSummary: report.notice.summary), "26.6.2")
      }
    }

    func testSourceOwnerFailureStopsBeforePayloadFirmwareAndBackendExecution() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(), rejectPayload: true,
        rejectSourceOwner: true)
      await assertThrowsErrorAsync(
        try await executor.execute(fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          XCTFail("Expected typed source-owner preflight failure")
          return
        }
        XCTAssertEqual(report.notice.reason, .recoveryPreparation)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(
          report.notice.summary, "The current macOS volume owner could not be verified.")
      }
    }

    func testRecoveryPreparationFailureNeverClaimsAnInstalledRetryWasUnchanged() async throws {
      for operation in [EngineHandoffOperation.install, .retryRecoveryAuthorization] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = fixtureExecutor(effectiveUserID: { 0 }, rejectRecovery: true)
        await assertThrowsErrorAsync(
          try await executor.execute(
            fixture.package, authorization: try machineOwnerAuthorization(), operation: operation
          )
        ) {
          guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
            XCTFail("Expected typed preparation failure")
            return
          }
          XCTAssertEqual(report.notice.reason, .recoveryPreparation)
          XCTAssertEqual(report.notice.diskUnchanged, operation == .install)
        }
      }
    }

    private func fixtureExecutor(
      effectiveUserID: @escaping @Sendable () -> uid_t,
      expectedFileOwnerID: @escaping @Sendable () -> uid_t = { geteuid() },
      firmwarePreparer: any NativeFirmwarePreparing = NativeFirmwarePreparer(),
      peripheralPreparer: any NativePeripheralPreparing = NativeNeoPeripheralPreparer(),
      apfsPreparer: any NativeAPFSPreparing = NoNativeAPFSFixture(),
      stubFilesPreparer: any NativeStubFilesPreparing = NoNativeStubFilesFixture(),
      osPartitionsPreparer: any NativeOSPartitionsPreparing = NativePartitionsFixture(),
      payloadImagesPreparer: any NativePayloadImagesPreparing = NativeImagesFixture(),
      espFilesPreparer: any NativeESPFilesPreparing = NoNativeESPFixture(),
      installationFinisher: any NativeInstallationFinishingPreparing = NativeInstallationFinisher(
        enabled: false),
      preservedReinstall: any NativePreservedReinstallExecuting = RefusingPreservedReinstall(),
      rejectRecovery: Bool = false,
      restoreImageRequirement: String? = RestoreImageHelper.adHocRequirement(
        codeHash: String(repeating: "a", count: 40)),
      rejectDecoder: Bool = false,
      rejectPayload: Bool = false,
      rejectFirmwareSelection: NativeFirmwareSelectionError? = nil,
      rejectSourceOwner: Bool = false
    ) -> PinnedAsahiEngineExecutor {
      PinnedAsahiEngineExecutor(
        effectiveUserID: effectiveUserID, expectedFileOwnerID: expectedFileOwnerID,
        restoreImageRequirement: restoreImageRequirement,
        verifyRestoreImage: { _, _ in
          if rejectDecoder { throw RestoreImageHelperError.signatureRejected }
        },
        firmwarePreparer: firmwarePreparer,
        peripheralPreparer: peripheralPreparer,
        apfsPreparer: apfsPreparer, stubFilesPreparer: stubFilesPreparer,
        osPartitionsPreparer: osPartitionsPreparer, payloadImagesPreparer: payloadImagesPreparer,
        espFilesPreparer: espFilesPreparer, installationFinisher: installationFinisher,
        preservedReinstall: preservedReinstall,
        nativeHandoff: FixtureNativeHandoff(),
        validatePayload: { _ in
          if let rejectFirmwareSelection { throw rejectFirmwareSelection }
          if rejectPayload { throw NativePayloadPreflightError.invalidFilesystem }
        },
        validateSourceOwner: { _, _ in
          if rejectSourceOwner { throw NativeHandoffValidationError.invalidOwner }
          return try NativeSourceBootstrap(
            systemUUID: "00000000-0000-0000-0000-000000000101",
            groupUUID: "00000000-0000-0000-0000-000000000102",
            ownerUUID: "00000000-0000-0000-0000-000000000103")
        },
        prepareRecoveryTemplate: { package in
          if rejectRecovery { throw NativeRecoveryTemplateError.unavailable }
          let directory = package.packageURL.deletingLastPathComponent().appendingPathComponent(
            "fixture-recovery-\(UUID().uuidString)")
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          let app = directory.appendingPathComponent("Recovery.app")
          let manifest = directory.appendingPathComponent("manifest.json")
          try Data("app".utf8).write(to: app)
          try Data("{}".utf8).write(to: manifest)
          return PreparedNativeRecoveryTemplate(
            directory: directory, app: app, manifest: manifest, requirement: "fixture")
        })
    }

    private func makeFixture(
      transcript: Data = Data("validated-transcript\n".utf8),
      includeDecoder: Bool = true,
      installationIntent: ImportedInstallationIntent = .fresh,
      planDigest: String = NativeAdmissionTestData.plan.planDigest
    ) throws -> PinnedExecutorFixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-pinned-executor-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      let packageURL = root.appendingPathComponent(
        "imported-handoff",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: packageURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      // What the fixture native handoff returns as its completed transcript.
      try writePrivate(transcript, to: root.appendingPathComponent("native-transcript.jsonl"))
      let decoderURL = packageURL.appendingPathComponent(RestoreImageHelper.fileName)
      try writePrivate(Data("decoder".utf8), to: decoderURL)
      let manifestURL = packageURL.appendingPathComponent("manifest.json")
      let requestURL = packageURL.appendingPathComponent("request.json")
      let identityURL = packageURL.appendingPathComponent("identity.json")
      let metadataURL = packageURL.appendingPathComponent(
        "installer-data.json"
      )
      let payloadURL = packageURL.appendingPathComponent("omarchy.img.zst")
      for url in [manifestURL, requestURL, identityURL, metadataURL, payloadURL] {
        try writePrivate(Data("fixture".utf8), to: url)
      }

      return PinnedExecutorFixture(
        root: root,
        package: ImportedEngineHandoffPackage(
          packageURL: packageURL,
          manifestURL: manifestURL,
          requestURL: requestURL,
          identityURL: identityURL,
          metadataURL: metadataURL,
          payloadURL: payloadURL,
          restoreImageURL: includeDecoder ? decoderURL : nil,
          bindingDigest: "sha256:" + String(repeating: "b", count: 64),
          planDigest: planDigest,
          deviceIdentifier: "apple,j314s",
          storeIdentifier: "disk0",
          installationIntent: installationIntent
        ),
        transcript: transcript
      )
    }

    /// Writes the private journal and checkpoint evidence a run of an older
    /// installer kept for this package.
    private func writeRetainedJournal(
      _ transcript: Data, evidence: [String: Data],
      for package: ImportedEngineHandoffPackage
    ) throws {
      let directory = package.packageURL.deletingLastPathComponent()
        .appendingPathComponent("execution-journals", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let journal = try XCTUnwrap(
        EngineJournalLocator.journalURL(
          workingDirectory: package.packageURL.deletingLastPathComponent(),
          bindingDigest: package.bindingDigest))
      try transcript.write(to: journal)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: journal.path)
      for (identifier, bytes) in evidence {
        let url = URL(fileURLWithPath: journal.path + ".\(identifier).evidence")
        try bytes.write(to: url)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    }

    private func checkpointFixture(_ marker: String) -> Data {
      try! JSONSerialization.data(
        withJSONObject: [
          "plan_digest": NativeAdmissionTestData.plan.planDigest,
          "fixture": marker,
        ], options: [.sortedKeys])
    }

    private func recoveryRetryTranscript(
      targetEvidence: Data,
      installedEvidence: Data
    ) -> Data {
      let planDigest = NativeAdmissionTestData.plan.planDigest
      let targetDigest = digest(targetEvidence)
      let installedDigest = digest(installedEvidence)
      let prefix = try! NativeAdmissionTestData.journal()
      let lines = [
        #"{"schema_version":1,"sequence":4,"type":"event","payload":{"plan_digest":"\#(planDigest)","name":"apfs_preparation_started"}}"#,
        #"{"schema_version":1,"sequence":5,"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"apfs-target-prepared","phase":"apfs_preparation","evidence_digest":"\#(targetDigest)"}}"#,
        #"{"schema_version":1,"sequence":6,"type":"event","payload":{"plan_digest":"\#(planDigest)","name":"stub_and_esp_started"}}"#,
        #"{"schema_version":1,"sequence":7,"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"stub-and-esp-installed","phase":"stub_and_esp","evidence_digest":"\#(installedDigest)"}}"#,
        #"{"schema_version":1,"sequence":8,"type":"event","payload":{"plan_digest":"\#(planDigest)","name":"recovery_handoff_started"}}"#,
      ]
      return prefix + Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
      try data.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: url.path
      )
    }

    private func digest(_ data: Data) -> String {
      return "sha256:"
        + SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private func machineOwnerAuthorization() throws
      -> MachineOwnerAuthorization
    {
      try MachineOwnerAuthorization(
        username: "mina",
        password: Data("owner-password".utf8)
      )
    }
  }

  private struct PinnedExecutorFixture {
    let root: URL
    let package: ImportedEngineHandoffPackage
    let transcript: Data
  }

  private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected expression to throw")
    } catch {
      errorHandler(error)
    }
  }
#endif
