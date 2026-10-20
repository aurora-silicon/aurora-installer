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
            .appendingPathComponent("bundle-source/transcript.jsonl"))
      }
    }

    func testADelegatedHandoffRequiresAnAuthenticatedBackendCapability() async throws {
      let fixture = try makeFixture(supportsNativeHandoff: false)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      await assertThrowsErrorAsync(
        try await fixtureExecutor(effectiveUserID: { 0 }).execute(
          fixture.package, authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          return XCTFail("Expected capability admission failure")
        }
        XCTAssertEqual(report.notice.reason, .recoveryPreparation)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }
    private struct FirmwareMarker: NativeFirmwarePreparing {
      let url: URL
      func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
        try Data("prepared".utf8).write(to: url)
        return nil
      }
    }

    func testNativeAdmissionRecollectsAfterFirmwareAndStopsBeforeBackendLaunch() async throws {
      for failure in ["existing", "unreadable"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.root.appendingPathComponent("firmware-marker")
        let executor = fixtureExecutor(
          effectiveUserID: { 0 },
          firmwarePreparer: FirmwareMarker(url: marker),
          collectInstallAdmission: {
            guard try Data(contentsOf: marker) == Data("prepared".utf8) else {
              throw CocoaError(.fileReadUnknown)
            }
            if failure == "unreadable" { throw CocoaError(.fileReadNoPermission) }
            return NativeAdmissionTestData.facts(existing: true)
          })
        await assertThrowsErrorAsync(
          try await executor.execute(
            fixture.package,
            authorization: try machineOwnerAuthorization())
        ) {
          guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
            return XCTFail("Expected native admission failure, got \($0)")
          }
          XCTAssertEqual(report.notice.reason, .diskLayoutChanged)
          XCTAssertTrue(report.notice.diskUnchanged)
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("prepared".utf8))
        let journal = try XCTUnwrap(journalEntries(in: fixture.root).first)
        XCTAssertTrue(try Data(contentsOf: journal).isEmpty)
        XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testExplicitRepairAndReplacementReachTheBackendWithKnownInstallations() async throws {
      for intent in [ImportedInstallationIntent.repair, .replace] {
        let fixture = try makeFixture(installationIntent: intent)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = fixtureExecutor(
          effectiveUserID: { 0 },
          collectInstallAdmission: {
            NativeAdmissionTestData.facts(existing: true)
          })
        let result = try await executor.execute(
          fixture.package, authorization: try machineOwnerAuthorization())
        XCTAssertEqual(result, fixture.transcript)
      }
    }

    func testRecordedInstallResumesOnlyWithPrivateMatchingCheckpointEvidence() async throws {
      for evidenceState in [
        "valid", "changed", "missing", "symlink", "public", "different-plan",
        "different-read-only-plan",
      ] {
        let foreignPlan = evidenceState.hasPrefix("different")
        let readOnly = evidenceState == "different-read-only-plan"
        let fixture = try makeFixture(
          planDigest: foreignPlan
            ? String(repeating: "d", count: 64)
            : NativeAdmissionTestData.plan.planDigest)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("execution-journals")
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let journal = directory.appendingPathComponent(String(repeating: "b", count: 64) + ".jsonl")
        let retained = try NativeAdmissionTestData.journal(
          stages: readOnly ? 0 : 2, pendingRecovery: !readOnly)
        try retained.write(to: journal)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: journal.path)
        for identifier in ["apfs-target-prepared", "stub-and-esp-installed"] {
          let evidence = URL(fileURLWithPath: journal.path + "." + identifier + ".evidence")
          if evidenceState == "missing" { continue }
          if evidenceState == "symlink" {
            try FileManager.default.createSymbolicLink(at: evidence, withDestinationURL: journal)
          } else {
            try
              (evidenceState == "changed" ? Data("changed".utf8) : NativeAdmissionTestData.evidence)
              .write(to: evidence)
            try FileManager.default.setAttributes(
              [.posixPermissions: evidenceState == "public" ? 0o644 : 0o600],
              ofItemAtPath: evidence.path)
          }
        }
        let executor = fixtureExecutor(
          effectiveUserID: { 0 },
          collectInstallAdmission: {
            throw CocoaError(.fileReadUnknown)
          })
        if evidenceState == "valid" {
          let result = try await executor.execute(
            fixture.package, authorization: try machineOwnerAuthorization())
          XCTAssertEqual(result, fixture.transcript)
        } else {
          await assertThrowsErrorAsync(
            try await executor.execute(
              fixture.package,
              authorization: try machineOwnerAuthorization())
          ) {
            guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
              return XCTFail("Expected checkpoint rejection")
            }
            XCTAssertEqual(report.notice.reason, .planIntegrity)
            XCTAssertFalse(report.notice.diskUnchanged)
          }
          XCTAssertEqual(try Data(contentsOf: journal), retained)
        }
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
          XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
        }
      }
    }

    func testAnOlderEngineCannotSilentlyUseABundledDecoder() async throws {
      let fixture = try makeFixture(supportsSignedDecoder: false)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization())
      ) {
        guard case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError else {
          return XCTFail("Expected incompatible runtime refusal")
        }
        XCTAssertEqual(report.notice.reason, .recoveryPreparation)
        XCTAssertTrue(report.notice.diskUnchanged)
      }
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testVerifiedReadOnlyInspectionRunsWithoutRootAndCleansExecutionRoot()
      async throws
    {
      let transcript = Data(
        """
        {"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j614s","support":"unsupported"}}

        """.utf8
      )
      let fixture = try makeFixture(transcript: transcript)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let scratch = fixture.root.appendingPathComponent(
        "inspection-scratch",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: scratch,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let archive = try PinnedAsahiEngineArchive(
        fileURL: fixture.package.engineURL,
        expectedDigest: try digest(of: fixture.package.engineURL),
        expectedSizeBytes: try size(of: fixture.package.engineURL)
      )
      let executor = fixtureExecutor(effectiveUserID: { 501 })

      let result = try await executor.inspect(archive, in: scratch)

      XCTAssertEqual(result, transcript)
      XCTAssertTrue(try executionEntries(in: scratch).isEmpty)
    }

    func testReadOnlyInspectionRejectsChangedArchiveDigest() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let scratch = fixture.root.appendingPathComponent(
        "inspection-scratch",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: scratch,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let archive = try PinnedAsahiEngineArchive(
        fileURL: fixture.package.engineURL,
        expectedDigest: "sha256:" + String(repeating: "0", count: 64),
        expectedSizeBytes: try size(of: fixture.package.engineURL)
      )
      let executor = fixtureExecutor(effectiveUserID: { 501 })

      await assertThrowsErrorAsync(
        try await executor.inspect(archive, in: scratch)
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .archiveDigestMismatch
        )
      }
      XCTAssertTrue(try executionEntries(in: scratch).isEmpty)
    }

    func testVerifiedPlanReceivesPrivateInputsAndCleansAllTemporaryState()
      async throws
    {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let scratch = fixture.root.appendingPathComponent(
        "planning-scratch",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: scratch,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let archive = try PinnedAsahiEngineArchive(
        fileURL: fixture.package.engineURL,
        expectedDigest: try digest(of: fixture.package.engineURL),
        expectedSizeBytes: try size(of: fixture.package.engineURL)
      )
      let candidate = ValidatedEngineCandidate(
        kind: "free",
        sourceIdentifier: "disk0s3",
        offsetBytes: 128 * 1_048_576,
        lengthBytes: 128 * 1_048_576,
        minimumInstallBytes: 64 * 1_048_576,
        minimumContainerBytes: 0
      )
      let request = try PinnedAsahiPlanRequest(
        inventory: ValidatedEngineInventory(
          layoutDigest: "sha256:" + String(repeating: "c", count: 64),
          systemStoreIdentifier: "disk0",
          candidates: [candidate]
        ),
        candidate: candidate,
        requestedLengthBytes: 96 * 1_048_576
      )
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: "v0.9.0-omarchy.2",
        engineDigest: "sha256:" + String(repeating: "d", count: 64),
        metadataDigest: "sha256:" + String(repeating: "e", count: 64),
        payloadDigest: "sha256:" + String(repeating: "f", count: 64)
      )
      let executor = fixtureExecutor(effectiveUserID: { 501 })

      let result = try await executor.plan(
        archive,
        request: request,
        identity: identity,
        in: scratch
      )

      XCTAssertEqual(result, fixture.transcript)
      XCTAssertTrue(try executionEntries(in: scratch).isEmpty)
      XCTAssertTrue(try planningInputEntries(in: scratch).isEmpty)
    }

    func testNonRootExecutionIsRejectedBeforeArchiveAccess() async throws {
      let package = importedPackage(
        at: URL(fileURLWithPath: "/does-not-exist")
      )
      let executor = fixtureExecutor(effectiveUserID: { 501 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .privilegeRequired
        )
      }
    }

    func testValidPinnedBundleReceivesBoundInputsAndCleansExecutionRoot()
      async throws
    {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      let transcript = try await executor.execute(
        fixture.package,
        authorization: try machineOwnerAuthorization()
      )

      XCTAssertEqual(transcript, fixture.transcript)
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
      let journals = try journalEntries(in: fixture.root)
      XCTAssertEqual(journals.count, 1)
      XCTAssertEqual(try Data(contentsOf: journals[0]), fixture.transcript)
    }

    func testRecoveryRetryUsesDedicatedEngineMode() async throws {
      let fixture = try makeFixture(
        expectedInstallMode: "retry-recovery-authorization"
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      let transcript = try await executor.execute(
        fixture.package,
        authorization: try machineOwnerAuthorization(),
        operation: .retryRecoveryAuthorization
      )

      XCTAssertEqual(transcript, fixture.transcript)
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testRepairExecutionReceivesImportedRepairManifest() async throws {
      let fixture = try makeFixture(
        repairManifest: Data("{\"operation\":\"repair-installed-system\"}".utf8)
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      let transcript = try await executor.execute(
        fixture.package,
        authorization: try machineOwnerAuthorization()
      )

      XCTAssertEqual(transcript, fixture.transcript)
    }

    func testRootStyleExtractionNormalizesGroupWritableArchiveModes()
      async throws
    {
      let fixture = try makeFixture(groupWritableBundleEntry: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 },
        extractionOptions: ["--preserve-permissions"]
      )

      let transcript = try await executor.execute(
        fixture.package,
        authorization: try machineOwnerAuthorization()
      )

      XCTAssertEqual(transcript, fixture.transcript)
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testEscapingBundleSymlinkIsRejected() async throws {
      let fixture = try makeFixture(escapingSymlink: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .invalidBundle
        )
      }
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testNonzeroEngineExitIsRejectedAndExecutionRootIsCleaned()
      async throws
    {
      let fixture = try makeFixture(exitCode: 17)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        guard
          case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
        else {
          return XCTFail("Expected engineFailed, got \($0)")
        }
        XCTAssertEqual(report.notice.exitStatus, 17)
        XCTAssertEqual(report.notice.reason, .unclassified)
        // The synthetic transcript is not a journal: no claim either way.
        XCTAssertFalse(report.notice.diskUnchanged)
      }
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
      XCTAssertEqual(try journalEntries(in: fixture.root).count, 1)
    }

    func testApprovedExtentChangedIsClassifiedRedactedAndProvesNoMutation()
      async throws
    {
      let stderr = """
        Traceback (most recent call last):
          File "main.py", line 1270, in <module>
        debug: owner=owner-password passphrase: "hunter 2" raw=b'owner-password'
        \u{1B}[31mcolored\u{1B}[0m
        omarchy_execution.ExecutionAdmissionError: approved extent changed

        """
      let fixture = try makeFixture(
        exitCode: 1,
        transcript: readOnlyJournal(),
        standardError: Data(stderr.utf8)
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        guard
          case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
        else {
          return XCTFail("Expected engineFailed, got \($0)")
        }
        XCTAssertEqual(report.notice.reason, .approvedSpaceChanged)
        XCTAssertEqual(report.notice.exitStatus, 1)
        XCTAssertTrue(report.notice.diskUnchanged)
        XCTAssertEqual(
          report.notice.summary,
          "omarchy_execution.ExecutionAdmissionError: approved extent changed"
        )
        let tail = report.redactedStandardErrorTail
        XCTAssertFalse(tail.contains("owner-password"))
        XCTAssertFalse(tail.contains("hunter"))
        XCTAssertFalse(tail.contains("\u{1B}"))
        XCTAssertTrue(tail.contains("approved extent changed"))
      }
    }

    func testJournalWithAMutationEventMakesNoDiskUnchangedClaim() async throws {
      let fixture = try makeFixture(
        exitCode: 1,
        transcript: readOnlyJournal(withEvent: true),
        standardError: Data(
          "omarchy_asahi.AsahiAdapterError: approved extent is smaller than Asahi minimum\n".utf8)
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        guard
          case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
        else {
          return XCTFail("Expected engineFailed, got \($0)")
        }
        XCTAssertEqual(report.notice.reason, .approvedSpaceChanged)
        XCTAssertFalse(report.notice.diskUnchanged)
      }
    }

    func testLargeEngineStandardErrorIsDrainedAndBounded() async throws {
      var stderr = Data(repeating: UInt8(ascii: "x"), count: 300_000)
      stderr.append(Data("\nomarchy_execution.ExecutionAdmissionError: disk layout changed\n".utf8))
      let fixture = try makeFixture(
        exitCode: 3,
        transcript: readOnlyJournal(),
        standardError: stderr
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })
      let started = Date()

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        guard
          case .engineFailed(let report) = $0 as? PinnedAsahiEngineExecutionError
        else {
          return XCTFail("Expected engineFailed, got \($0)")
        }
        XCTAssertEqual(report.notice.reason, .diskLayoutChanged)
        XCTAssertLessThanOrEqual(
          report.redactedStandardErrorTail.count,
          EngineStandardErrorRedactor.maximumTailCharacters
        )
      }
      XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testRecoveryAuthorizationFailureRequiresExactRetryCheckpoint()
      async throws
    {
      let targetEvidence = checkpointFixture("target-readback")
      let installedEvidence = checkpointFixture("installed-readback")
      let transcript = recoveryRetryTranscript(
        targetEvidence: targetEvidence,
        installedEvidence: installedEvidence
      )
      let fixture = try makeFixture(
        exitCode: 17,
        transcript: transcript,
        checkpointEvidence: [
          "apfs-target-prepared": targetEvidence,
          "stub-and-esp-installed": installedEvidence,
        ]
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(effectiveUserID: { 0 })

      await assertThrowsErrorAsync(
        try await executor.execute(
          fixture.package,
          authorization: try machineOwnerAuthorization()
        )
      ) {
        XCTAssertEqual(
          $0 as? PinnedAsahiEngineExecutionError,
          .recoveryAuthorizationFailed
        )
      }
      XCTAssertTrue(
        executor.canRetryRecoveryAuthorization(
          InstallerJobPlanIdentity(package: fixture.package),
          in: fixture.package.packageURL.deletingLastPathComponent()))
      let journal = try XCTUnwrap(
        EngineJournalLocator.journalURL(
          workingDirectory: fixture.package.packageURL.deletingLastPathComponent(),
          bindingDigest: fixture.package.bindingDigest))
      let evidence = URL(fileURLWithPath: journal.path + ".stub-and-esp-installed.evidence")
      XCTAssertEqual(chmod(evidence.path, 0o600), 0)
      try Data("changed evidence".utf8).write(to: evidence)
      XCTAssertFalse(
        executor.canRetryRecoveryAuthorization(
          InstallerJobPlanIdentity(package: fixture.package),
          in: fixture.package.packageURL.deletingLastPathComponent()))
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testTruncatedTranscriptIsRejected() async throws {
      let fixture = try makeFixture(transcript: Data("truncated".utf8))
      defer { try? FileManager.default.removeItem(at: fixture.root) }
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testRecoveryAuthorizationRetryDoesNotRepeatNativeFirmwareDownloads() async throws {
      let fixture = try makeFixture(expectedInstallMode: "retry-recovery-authorization")
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
    }

    func testIncompatibleBootFirmwareHasAFirmwarePreparationFailureBeforeLaunch() async throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let executor = fixtureExecutor(
        effectiveUserID: { 0 }, firmwarePreparer: FailedFirmware(), rejectFirmwareSelection: true)
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
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
      XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
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
        XCTAssertTrue(try executionEntries(in: fixture.root).isEmpty)
      }
    }

    private func fixtureExecutor(
      effectiveUserID: @escaping @Sendable () -> uid_t,
      expectedFileOwnerID: @escaping @Sendable () -> uid_t = { geteuid() },
      extractionOptions: [String] = [],
      firmwarePreparer: any NativeFirmwarePreparing = NativeFirmwarePreparer(),
      collectInstallAdmission: @escaping @Sendable () throws -> NativeInstallAdmissionFacts = {
        NativeAdmissionTestData.facts()
      },
      rejectRecovery: Bool = false,
      restoreImageRequirement: String? = RestoreImageHelper.adHocRequirement(
        codeHash: String(repeating: "a", count: 40)),
      rejectDecoder: Bool = false,
      rejectPayload: Bool = false,
      rejectFirmwareSelection: Bool = false,
      rejectSourceOwner: Bool = false
    ) -> PinnedAsahiEngineExecutor {
      PinnedAsahiEngineExecutor(
        effectiveUserID: effectiveUserID, expectedFileOwnerID: expectedFileOwnerID,
        extractionOptions: extractionOptions,
        restoreImageRequirement: restoreImageRequirement,
        verifyRestoreImage: { _, _ in
          if rejectDecoder { throw RestoreImageHelperError.signatureRejected }
        },
        firmwarePreparer: firmwarePreparer,
        nativeHandoff: FixtureNativeHandoff(),
        collectInstallAdmission: collectInstallAdmission,
        validatePayload: { _ in
          if rejectFirmwareSelection { throw NativeFirmwareSelectionError.noCompatibleFirmware }
          if rejectPayload { throw NativePayloadPreflightError.invalidFilesystem }
        },
        validateSourceOwner: { _, _ in
          if rejectSourceOwner { throw NativeHandoffValidationError.invalidOwner }
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
      escapingSymlink: Bool = false,
      groupWritableBundleEntry: Bool = false,
      exitCode: Int32 = 0,
      transcript: Data = Data("validated-transcript\n".utf8),
      expectedInstallMode: String = "install",
      checkpointEvidence: [String: Data] = [:],
      repairManifest: Data? = nil,
      standardError: Data? = nil,
      includeDecoder: Bool = true,
      supportsSignedDecoder: Bool = true,
      supportsNativeHandoff: Bool = true,
      installationIntent: ImportedInstallationIntent? = nil,
      planDigest: String = NativeAdmissionTestData.plan.planDigest
    ) throws -> PinnedExecutorFixture {
      let intent = installationIntent ?? (repairManifest == nil ? .fresh : .repair)
      let backendMode =
        expectedInstallMode == "install" && intent != .repair
        ? "prepare-native-handoff" : expectedInstallMode
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-pinned-executor-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      let packageURL = root.appendingPathComponent(
        "imported-handoff",
        isDirectory: true
      )
      let bundleSource = root.appendingPathComponent(
        "bundle-source",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: packageURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.createDirectory(
        at: bundleSource,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )

      let capability =
        supportsSignedDecoder ? ",\"signedHelperInput\":\"helper-executable-v1\"" : ""
      let handoffCapability =
        supportsNativeHandoff ? ",\"nativeHandoff\":\"helper-finalize-v1\"" : ""
      try Data(
        #"{"schema":1,"nativeRecoveryInput":"helper-template-v1","nativeFirmwareInput":"helper-raw-v1"\#(handoffCapability)\#(capability)}"#
          .utf8
      ).write(to: bundleSource.appendingPathComponent("engine-capabilities.json"))
      let main = bundleSource.appendingPathComponent("main.py")
      try writePrivate(Data("# synthetic engine\n".utf8), to: main)
      var checkpointCommands = [String]()
      for (identifier, evidence) in checkpointEvidence.sorted(
        by: { $0.key < $1.key }
      ) {
        let fileName = "checkpoint-\(identifier)"
        try writePrivate(
          evidence,
          to: bundleSource.appendingPathComponent(fileName)
        )
        checkpointCommands.append(
          #"/bin/cp "$PWD/\#(fileName)" "$OMARCHY_ENGINE_JOURNAL.\#(identifier).evidence""#
        )
      }
      if groupWritableBundleEntry {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o460],
          ofItemAtPath: main.path
        )
      }
      if escapingSymlink {
        try FileManager.default.createSymbolicLink(
          at: bundleSource.appendingPathComponent("escape"),
          withDestinationURL: URL(fileURLWithPath: "/private/tmp")
        )
      }
      let python = bundleSource.appendingPathComponent(
        "Frameworks/Python.framework/Versions/3.13/bin/python3.13"
      )
      try FileManager.default.createDirectory(
        at: python.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let script = """
        #!/bin/sh
        case "$OMARCHY_ENGINE_MODE" in
          inspect) ;;
          plan)
            [ -r "$OMARCHY_ENGINE_REQUEST" ] || exit 77
            [ -r "$OMARCHY_ENGINE_IDENTITY" ] || exit 78
            /usr/bin/grep -q '"candidate_kind":"free"' "$OMARCHY_ENGINE_REQUEST" || exit 79
            /usr/bin/grep -q '"requested_length_bytes":100663296' "$OMARCHY_ENGINE_REQUEST" || exit 80
            /usr/bin/grep -q '"engine_version":"v0.9.0-omarchy.2"' "$OMARCHY_ENGINE_IDENTITY" || exit 81
            ;;
          install|prepare-native-handoff|retry-recovery-authorization)
            [ "$OMARCHY_ENGINE_MODE" = "\(backendMode)" ] || exit 64
            [ "$DISTRO" = "Aurora" ] || exit 68
            [ "$OMARCHY_INSTALLER_NAME" = "\(InstallerProductIdentity.appName)" ] || exit 83
            [ "$DISTRO_DOCS" = "https://omarchy.org/manual/" ] || exit 69
            [ "$OMARCHY_MACHINE_OWNER" = "mina" ] || exit 67
            if [ "$OMARCHY_ENGINE_MODE" = "prepare-native-handoff" ]; then
              IFS= read -r owner_password && exit 84
            else
              IFS= read -r owner_password || exit 66
              [ "$owner_password" = "owner-password" ] || exit 65
            fi
            [ "$OMARCHY_ENGINE_PLAN_DIGEST" = "\(planDigest)" ] || exit 71
            [ "$OMARCHY_ENGINE_BINDING_DIGEST" = "sha256:\(String(repeating: "b", count: 64))" ] || exit 72
            [ -r "$OMARCHY_ENGINE_REQUEST" ] || exit 73
            [ -r "$OMARCHY_ENGINE_IDENTITY" ] || exit 74
            [ -r "$OMARCHY_ENGINE_METADATA" ] || exit 75
            [ -r "$OMARCHY_ENGINE_PAYLOAD" ] || exit 76
            \(repairManifest == nil ? "" : "[ -r \"$OMARCHY_ENGINE_REPAIR_MANIFEST\" ] || exit 82")
            ;;
          *) exit 70 ;;
        esac
        /bin/cp "$PWD/transcript.jsonl" "$OMARCHY_ENGINE_JOURNAL"
        \(checkpointCommands.joined(separator: "\n"))
        \(standardError == nil ? "" : #"/bin/cat "$PWD/stderr.txt" >&2"#)
        exit \(exitCode)
        """
      try script.data(using: .utf8)?.write(
        to: python,
        options: .withoutOverwriting
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: python.path
      )
      try writePrivate(
        transcript,
        to: bundleSource.appendingPathComponent("transcript.jsonl")
      )
      if let standardError {
        try writePrivate(
          standardError,
          to: bundleSource.appendingPathComponent("stderr.txt")
        )
      }

      let engineURL = packageURL.appendingPathComponent("engine.tar.gz")
      try createArchive(from: bundleSource, at: engineURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: engineURL.path
      )
      let decoderURL = packageURL.appendingPathComponent(RestoreImageHelper.fileName)
      try writePrivate(Data("decoder".utf8), to: decoderURL)
      let manifestURL = packageURL.appendingPathComponent("manifest.json")
      let requestURL = packageURL.appendingPathComponent("request.json")
      let identityURL = packageURL.appendingPathComponent("identity.json")
      let metadataURL = packageURL.appendingPathComponent(
        "installer-data.json"
      )
      let payloadURL = packageURL.appendingPathComponent("omarchy.img.zst")
      let repairManifestURL = repairManifest.map { _ in
        packageURL.appendingPathComponent("repair.json")
      }
      for url in [manifestURL, requestURL, identityURL, metadataURL, payloadURL] {
        try writePrivate(Data("fixture".utf8), to: url)
      }
      if let repairManifest, let repairManifestURL {
        try writePrivate(repairManifest, to: repairManifestURL)
      }

      return PinnedExecutorFixture(
        root: root,
        package: ImportedEngineHandoffPackage(
          packageURL: packageURL,
          manifestURL: manifestURL,
          requestURL: requestURL,
          identityURL: identityURL,
          engineURL: engineURL,
          metadataURL: metadataURL,
          payloadURL: payloadURL,
          repairManifestURL: repairManifestURL,
          restoreImageURL: includeDecoder ? decoderURL : nil,
          bindingDigest: "sha256:" + String(repeating: "b", count: 64),
          planDigest: planDigest,
          deviceIdentifier: "apple,j314s",
          storeIdentifier: "disk0",
          installationIntent: intent
        ),
        transcript: transcript
      )
    }

    private func readOnlyJournal(withEvent: Bool = false) -> Data {
      let bytes = try! NativeAdmissionTestData.journal(pendingDisk: withEvent)
      if withEvent { return bytes }
      return Data(bytes.split(separator: 10).prefix(2).flatMap { Array($0) + [10] })
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

    private func createArchive(from source: URL, at archive: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = [
        "-czf", archive.path, "-C", source.path, ".",
      ]
      process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        throw CocoaError(.fileWriteUnknown)
      }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
      try data.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: url.path
      )
    }

    private func executionEntries(in root: URL) throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).filter { $0.lastPathComponent.hasPrefix("engine-execution-") }
    }

    private func planningInputEntries(in root: URL) throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).filter { $0.lastPathComponent.hasPrefix("engine-plan-input-") }
    }

    private func digest(of url: URL) throws -> String {
      let data = try Data(contentsOf: url)
      return digest(data)
    }

    private func digest(_ data: Data) -> String {
      return "sha256:"
        + SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private func size(of url: URL) throws -> UInt64 {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: url.path
      )
      return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func machineOwnerAuthorization() throws
      -> MachineOwnerAuthorization
    {
      try MachineOwnerAuthorization(
        username: "mina",
        password: Data("owner-password".utf8)
      )
    }

    private func journalEntries(in root: URL) throws -> [URL] {
      let directory = root.appendingPathComponent(
        "execution-journals",
        isDirectory: true
      )
      return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    }

    private func importedPackage(at packageURL: URL)
      -> ImportedEngineHandoffPackage
    {
      ImportedEngineHandoffPackage(
        packageURL: packageURL,
        manifestURL: packageURL.appendingPathComponent("manifest.json"),
        requestURL: packageURL.appendingPathComponent("request.json"),
        identityURL: packageURL.appendingPathComponent("identity.json"),
        engineURL: packageURL.appendingPathComponent("engine.tar.gz"),
        metadataURL: packageURL.appendingPathComponent("installer-data.json"),
        payloadURL: packageURL.appendingPathComponent("omarchy.img.zst"),
        restoreImageURL: packageURL.appendingPathComponent(RestoreImageHelper.fileName),
        bindingDigest: "sha256:" + String(repeating: "b", count: 64),
        planDigest: String(repeating: "a", count: 64),
        deviceIdentifier: "apple,j314s",
        storeIdentifier: "disk0"
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
