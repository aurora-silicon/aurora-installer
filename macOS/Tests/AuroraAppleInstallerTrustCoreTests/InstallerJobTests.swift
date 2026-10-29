#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class InstallerJobTests: XCTestCase {
    func testChangedOrUncertainDiskFailuresRetainInputsAndVerifiedHandoffCanRetryAfterRestart()
      throws
    {
      for unchanged in [false, true] {
        for eligible in [false, true] {
          let root = try workspace()
          let jobs = InstallerJobRegistry(
            workingDirectory: root, work: HelperWorkState(),
            retryEligibility: { _ in eligible })
          let request = try request()
          XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
          let packageURL = root.appendingPathComponent(
            "imported-handoff-" + UUID().uuidString.lowercased())
          try FileManager.default.createDirectory(
            at: packageURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          let package = ImportedEngineHandoffPackage(
            packageURL: packageURL, manifestURL: packageURL,
            requestURL: packageURL, identityURL: packageURL,
            metadataURL: packageURL,
            payloadURL: packageURL, bindingDigest: request.ticket.bindingDigest,
            planDigest: String(repeating: "a", count: 64), deviceIdentifier: "apple,j314s",
            storeIdentifier: "disk0")
          try jobs.admitted(request.ticket.identifier, package: package)
          let failure = PinnedAsahiEngineExecutionError.engineFailed(
            EngineFailureReport(
              notice: EngineFailureNotice(
                reason: .recoveryPreparation, exitStatus: 1,
                diskUnchanged: unchanged, summary: "Handoff did not complete"),
              redactedStandardErrorTail: ""))
          let cleanup = jobs.finish(request.ticket.identifier, result: .failure(failure))
          // Only a job that can still be retried keeps its imported package.
          XCTAssertEqual(cleanup?.path, unchanged || !eligible ? packageURL.path : nil)
          let restarted = InstallerJobRegistry(
            workingDirectory: root, work: HelperWorkState(),
            retryEligibility: { _ in eligible })
          let snapshot = try restarted.status(
            InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0),
            initiatingUID: 501)
          XCTAssertEqual(snapshot.recoveryRetryAvailable, !unchanged && eligible)
          if !unchanged && eligible {
            XCTAssertTrue(
              try restarted.beginRecoveryRetry(
                InstallerJobRecoveryRequest(ticket: request.ticket, attempt: UUID()),
                initiatingUID: 501))
            XCTAssertEqual(
              try restarted.recoveryContext(request.ticket.identifier).packageName,
              packageURL.lastPathComponent)
          }
        }
      }
    }
    func testStartUpRemovesImportsThatNoJobCanUse() throws {
      final class Eligibility: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        var value: Bool {
          get { lock.withLock { stored } }
          set { lock.withLock { stored = newValue } }
        }
      }
      let root = try workspace()
      let eligibility = Eligibility()
      let jobs = InstallerJobRegistry(
        workingDirectory: root, work: HelperWorkState(),
        retryEligibility: { _ in eligibility.value })
      func imported() throws -> URL {
        let url = root.appendingPathComponent(
          "imported-handoff-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("payload".utf8).write(to: url.appendingPathComponent("payload.zip"))
        return url
      }
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      let retained = try imported()
      try jobs.admitted(
        request.ticket.identifier,
        package: ImportedEngineHandoffPackage(
          packageURL: retained, manifestURL: retained, requestURL: retained,
          identityURL: retained, metadataURL: retained,
          payloadURL: retained, bindingDigest: request.ticket.bindingDigest,
          planDigest: String(repeating: "a", count: 64), deviceIdentifier: "apple,j314s",
          storeIdentifier: "disk0"))
      let failure = PinnedAsahiEngineExecutionError.engineFailed(
        EngineFailureReport(
          notice: EngineFailureNotice(
            reason: .recoveryPreparation, exitStatus: 1, diskUnchanged: false,
            summary: "Handoff did not complete"),
          redactedStandardErrorTail: ""))
      XCTAssertNil(jobs.finish(request.ticket.identifier, result: .failure(failure)))
      let orphan = try imported()
      let unrelated = root.appendingPathComponent("native-stub-cache-plan")
      try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
      let status = InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0)

      jobs.removeUnusedPackages()
      XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "No job names it")
      XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path), "A retry can use it")
      XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
      XCTAssertTrue(try jobs.status(status, initiatingUID: 501).recoveryRetryAvailable)

      // Once no retry can use it, for example after a later attempt changed
      // the disk, the next start removes it too.
      eligibility.value = false
      let restarted = InstallerJobRegistry(
        workingDirectory: root, work: HelperWorkState(),
        retryEligibility: { _ in eligibility.value })
      restarted.removeUnusedPackages()
      XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
      XCTAssertFalse(try restarted.status(status, initiatingUID: 501).recoveryRetryAvailable)
      XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testOnlyAFinishedFailedResetCanBeSetAsideAndItsRecordIsKept() throws {
      for eligible in [false, true] {
        let root = try workspace()
        let jobs = InstallerJobRegistry(
          workingDirectory: root, work: HelperWorkState(), retryEligibility: { _ in true },
          abandonEligibility: { _ in eligible })
        let request = try request()
        let abandon = InstallerJobAbandonRequest(ticket: request.ticket)
        let status = InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0)
        XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
        XCTAssertThrowsError(try jobs.abandon(abandon, initiatingUID: 501)) {
          XCTAssertEqual($0 as? InstallerJobError, .invalidRequest)
        }
        let packageURL = root.appendingPathComponent(
          "imported-handoff-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
          at: packageURL, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let package = ImportedEngineHandoffPackage(
          packageURL: packageURL, manifestURL: packageURL,
          requestURL: packageURL, identityURL: packageURL,
          metadataURL: packageURL,
          payloadURL: packageURL, bindingDigest: request.ticket.bindingDigest,
          planDigest: String(repeating: "a", count: 64), deviceIdentifier: "apple,j700",
          storeIdentifier: "disk0", installationIntent: .reinstall)
        try jobs.admitted(request.ticket.identifier, package: package)
        // A running job is never set aside.
        XCTAssertThrowsError(try jobs.abandon(abandon, initiatingUID: 501)) {
          XCTAssertEqual($0 as? InstallerJobError, .invalidRequest)
        }
        XCTAssertEqual(try jobs.status(status, initiatingUID: 501).startOverAvailable, false)
        let failure = PinnedAsahiEngineExecutionError.engineFailed(
          EngineFailureReport(
            notice: EngineFailureNotice(
              reason: .unclassified, exitStatus: 1, diskUnchanged: false,
              summary: "The preserved installation did not complete."),
            redactedStandardErrorTail: ""))
        XCTAssertNil(jobs.finish(request.ticket.identifier, result: .failure(failure)))
        XCTAssertEqual(try jobs.status(status, initiatingUID: 501).startOverAvailable, eligible)
        XCTAssertThrowsError(try jobs.abandon(abandon, initiatingUID: 502)) {
          XCTAssertEqual($0 as? InstallerJobError, .identityMismatch)
        }
        let name = request.ticket.identifier.uuidString.lowercased() + ".json"
        let record = root.appendingPathComponent("installation-jobs").appendingPathComponent(name)
        guard eligible else {
          // A held or unverified reset stays exactly as it was, still resumable.
          XCTAssertThrowsError(try jobs.abandon(abandon, initiatingUID: 501)) {
            XCTAssertEqual($0 as? InstallerJobError, .invalidRequest)
          }
          XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
          XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
          XCTAssertTrue(try jobs.status(status, initiatingUID: 501).recoveryRetryAvailable)
          continue
        }
        XCTAssertEqual(try jobs.abandon(abandon, initiatingUID: 501)?.path, packageURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        let kept = try XCTUnwrap(
          JSONSerialization.jsonObject(
            with: Data(
              contentsOf: root.appendingPathComponent("abandoned-installation-jobs")
                .appendingPathComponent(name))) as? [String: Any])
        XCTAssertEqual(kept["phase"] as? String, "failed")
        XCTAssertNotNil(kept["failure"])
        XCTAssertNotNil(kept["abandonedAt"])
        XCTAssertThrowsError(try jobs.status(status, initiatingUID: 501)) {
          XCTAssertEqual($0 as? InstallerJobError, .unavailable)
        }
        XCTAssertThrowsError(try jobs.abandon(abandon, initiatingUID: 501)) {
          XCTAssertEqual($0 as? InstallerJobError, .unavailable)
        }
        let restarted = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
        XCTAssertThrowsError(try restarted.status(status, initiatingUID: 501))
        XCTAssertTrue(try restarted.begin(try self.request(), initiatingUID: 501))
      }
    }

    func testAnInterruptedJobIsNeverSetAsideButAnUnadmittedFailureIs() throws {
      let root = try workspace()
      let request = try request()
      let abandon = InstallerJobAbandonRequest(ticket: request.ticket)
      let first = InstallerJobRegistry(
        workingDirectory: root, work: HelperWorkState(), abandonEligibility: { _ in true })
      XCTAssertTrue(try first.begin(request, initiatingUID: 501))
      // The helper stopped before the job finished; a child may still run.
      let restarted = InstallerJobRegistry(
        workingDirectory: root, work: HelperWorkState(), abandonEligibility: { _ in true })
      let snapshot = try restarted.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertEqual(snapshot.phase, .interrupted)
      XCTAssertEqual(snapshot.startOverAvailable, false)
      XCTAssertThrowsError(try restarted.abandon(abandon, initiatingUID: 501)) {
        XCTAssertEqual($0 as? InstallerJobError, .invalidRequest)
      }

      // A job that failed before the helper admitted it never reached the disk.
      let jobs = InstallerJobRegistry(
        workingDirectory: try workspace(), work: HelperWorkState(),
        abandonEligibility: { _ in false })
      let unadmitted = try self.request()
      XCTAssertTrue(try jobs.begin(unadmitted, initiatingUID: 501))
      jobs.finish(unadmitted.ticket.identifier, result: .failure(InstallerJobError.unsafeState))
      XCTAssertNil(
        try jobs.abandon(InstallerJobAbandonRequest(ticket: unadmitted.ticket), initiatingUID: 501))
    }

    private func workspace() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      addTeardownBlock { try? FileManager.default.removeItem(at: url) }
      return url
    }

    private func request() throws -> InstallerJobStartRequest {
      InstallerJobStartRequest(
        ticket: try InstallerJobTicket(
          bindingDigest: "sha256:" + String(repeating: "a", count: 64),
          selection: AuroraInstallationSelection(distribution: .fedora, desktop: .gnome)),
        operation: "install",
        installConf: try InstallConf(encrypt: true, lane: "stable").serializedData)
    }

    func testOnlyAnInitialTerminalFailureWithNoDiskChangesCanReleaseItsHint() throws {
      let request = try request()
      for phase in [InstallerJobPhase.failed, .interrupted, .running] {
        for attempt in [nil, UUID()] as [UUID?] {
          for unchanged in [false, true] {
            let notice = EngineFailureNotice(
              reason: .firmwarePreparation, exitStatus: 1,
              diskUnchanged: unchanged, summary: "Preparation failed")
            let failure = InstallerJobFailure(
              error: PinnedAsahiEngineExecutionError.engineFailed(
                EngineFailureReport(notice: notice, redactedStandardErrorTail: "")))
            let snapshot = InstallerJobSnapshot(
              identifier: request.ticket.identifier,
              bindingDigest: request.ticket.bindingDigest, selection: request.ticket.selection,
              phase: phase, plan: nil, transcript: nil, installConf: nil, failure: failure,
              journal: Data(), journalOffset: 0, recoveryAttempt: attempt,
              recoveryRetryAvailable: false, startOverAvailable: nil)
            XCTAssertEqual(
              snapshot.initialFailureWithoutDiskChanges != nil,
              phase == .failed && attempt == nil && unchanged)
          }
        }
      }
    }

    func testClearingATerminalHintCannotClearAnotherJob() throws {
      let store = PendingInstallerJobStore(directory: try workspace())
      let first = PendingInstallerJob(
        ticket: try request().ticket,
        helperMachServiceName: InstallerProductIdentity.helperMachServiceName,
        helperCodeSigningRequirement: "identifier \"\(InstallerProductIdentity.helperIdentifier)\"")
      let other = PendingInstallerJob(
        ticket: try request().ticket,
        helperMachServiceName: first.helperMachServiceName,
        helperCodeSigningRequirement: first.helperCodeSigningRequirement)
      try store.save(first)
      XCTAssertThrowsError(try store.clear(ifMatching: other))
      XCTAssertEqual(try store.load(), first)
      try store.clear(ifMatching: first)
      XCTAssertNil(try store.load())
    }

    func testExactDuplicateObservesOnceWhileChangedOptionsAndOtherUIDAreRejected() throws {
      let root = try workspace()
      let work = HelperWorkState()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: work)
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      XCTAssertFalse(try jobs.begin(request, initiatingUID: 501))
      XCTAssertFalse(work.beginReplacement(token: "replacement"))
      XCTAssertThrowsError(try jobs.begin(request, initiatingUID: 502)) {
        XCTAssertEqual($0 as? InstallerJobError, .identityMismatch)
      }
      let changed = InstallerJobStartRequest(
        ticket: request.ticket, operation: request.operation,
        installConf: try InstallConf(encrypt: false, lane: "stable").serializedData)
      XCTAssertThrowsError(try jobs.begin(changed, initiatingUID: 501)) {
        XCTAssertEqual($0 as? InstallerJobError, .identityMismatch)
      }
      jobs.finish(request.ticket.identifier, result: .failure(InstallerJobError.interrupted))
      XCTAssertTrue(work.beginReplacement(token: "replacement"))
    }

    func testWrongObservationTokenCannotReadAnotherJobAndRootRecordNeverStoresTheToken() throws {
      let root = try workspace()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      var fields = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request.ticket)) as? [String: Any])
      fields["observationToken"] = String(repeating: "b", count: 64)
      let wrong = try JSONDecoder().decode(
        InstallerJobTicket.self, from: JSONSerialization.data(withJSONObject: fields))
      XCTAssertThrowsError(
        try jobs.status(
          InstallerJobStatusRequest(ticket: wrong, journalOffset: 0), initiatingUID: 501))
      let saved = root.appendingPathComponent("installation-jobs")
        .appendingPathComponent(request.ticket.identifier.uuidString.lowercased() + ".json")
      let text = try String(contentsOf: saved, encoding: .utf8)
      XCTAssertFalse(text.contains(request.ticket.observationToken))
      XCTAssertTrue(text.contains(request.ticket.tokenDigest))
    }

    func testHelperRestartReportsInterruptedAndNeverStartsTheOldJobAgain() throws {
      let root = try workspace()
      let first = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try first.begin(request, initiatingUID: 501))
      let replacementGate = HelperWorkState()
      let restarted = InstallerJobRegistry(workingDirectory: root, work: replacementGate)
      let snapshot = try restarted.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertEqual(snapshot.phase, .interrupted)
      XCTAssertNil(snapshot.transcript)
      XCTAssertThrowsError(try snapshot.requireResult()) {
        XCTAssertEqual($0 as? InstallerJobError, .interrupted)
      }
      XCTAssertFalse(try restarted.begin(request, initiatingUID: 501))
      XCTAssertFalse(replacementGate.beginReplacement(token: "replacement"))
      XCTAssertThrowsError(try restarted.begin(try self.request(), initiatingUID: 501)) {
        XCTAssertEqual($0 as? InstallerJobError, .interrupted)
      }
    }

    func testOnlyVerifiedInterruptedRecoveryCanReuseItsExistingWorkHold() throws {
      for eligible in [false, true] {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
        let request = try self.request()
        XCTAssertTrue(try first.begin(request, initiatingUID: 501))
        let packageURL = root.appendingPathComponent(
          "imported-handoff-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
          at: packageURL, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let package = ImportedEngineHandoffPackage(
          packageURL: packageURL, manifestURL: packageURL,
          requestURL: packageURL, identityURL: packageURL,
          metadataURL: packageURL, payloadURL: packageURL,
          bindingDigest: request.ticket.bindingDigest,
          planDigest: String(repeating: "a", count: 64),
          deviceIdentifier: "apple,j314s", storeIdentifier: "disk0")
        try first.admitted(request.ticket.identifier, package: package)
        let work = HelperWorkState()
        let restored = InstallerJobRegistry(
          workingDirectory: root, work: work, retryEligibility: { _ in true },
          interruptedRetryEligibility: { _ in eligible })
        let status = try restored.status(
          InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
        XCTAssertEqual(status.phase, .interrupted)
        XCTAssertEqual(status.recoveryRetryAvailable, eligible)
        XCTAssertFalse(work.beginReplacement(token: "replacement"))
        let retry = InstallerJobRecoveryRequest(ticket: request.ticket, attempt: UUID())
        if eligible {
          XCTAssertTrue(try restored.beginRecoveryRetry(retry, initiatingUID: 501))
          XCTAssertEqual(
            try restored.recoveryContext(request.ticket.identifier).packageName,
            packageURL.lastPathComponent)
          XCTAssertFalse(work.beginReplacement(token: "replacement"))
          let failure = PinnedAsahiEngineExecutionError.engineFailed(
            EngineFailureReport(
              notice: EngineFailureNotice(
                reason: .recoveryPreparation, exitStatus: 1,
                diskUnchanged: false, summary: "Recovery stopped"),
              redactedStandardErrorTail: ""))
          _ = restored.finish(request.ticket.identifier, result: .failure(failure))
          XCTAssertTrue(work.beginReplacement(token: "replacement"))
        } else {
          XCTAssertThrowsError(try restored.beginRecoveryRetry(retry, initiatingUID: 501))
          XCTAssertFalse(work.beginReplacement(token: "replacement"))
        }
      }
    }

    func testRejectedCredentialsCannotExhaustTheJobHistory() throws {
      let root = try workspace()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      for _ in 0..<40 {
        let request = try request()
        XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
        jobs.finish(
          request.ticket.identifier,
          result: .failure(ClosedEngineHelperError.invalidMachineOwnerCredentials))
      }
      let saved = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("installation-jobs").path)
      XCTAssertLessThanOrEqual(saved.count, 8)
      XCTAssertTrue(try jobs.begin(try request(), initiatingUID: 501))
    }

    func testObservationWaitsForAdmissionAfterALostReplyWithoutSubmittingAgain() async throws {
      let request = try request()
      let terminal = InstallerJobSnapshot(
        identifier: request.ticket.identifier, bindingDigest: request.ticket.bindingDigest,
        selection: request.ticket.selection, phase: .succeeded, plan: nil,
        transcript: Data("result\n".utf8), installConf: .recorded, failure: nil,
        journal: Data(), journalOffset: 0, recoveryAttempt: nil, recoveryRetryAvailable: false,
        startOverAvailable: nil)
      let source = JobObservationFixture(responses: [
        .failure(InstallerJobError.unavailable),
        .failure(EngineXPCSubmissionError.connectionFailed),
        .success(terminal),
      ])
      let result = try await InstallerJobObservation.wait(
        fetch: { _ in try await source.next() }, sleep: { _ in })
      XCTAssertEqual(result.phase, .succeeded)
      let calls = await source.calls
      XCTAssertEqual(calls, 3)
    }

    func testUnresolvedAdmissionIsBoundedAndNeverReportedAsNotAdmitted() async throws {
      let source = JobObservationFixture(
        responses: Array(
          repeating: .failure(InstallerJobError.unavailable), count: 9))
      do {
        _ = try await InstallerJobObservation.wait(
          fetch: { _ in try await source.next() }, sleep: { _ in })
        XCTFail("Expected an unresolved lookup")
      } catch { XCTAssertEqual(error as? InstallerJobError, .unavailable) }
      let calls = await source.calls
      XCTAssertEqual(calls, 9)
    }

    func testStatusReportsTheStepARunningJobIsOnAndForgetsItWhenTheJobEnds() throws {
      let root = try workspace()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      let status = InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0)
      // A job that was never begun keeps no step.
      jobs.note(request.ticket.identifier, step: "source_owner")
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      XCTAssertNil(try jobs.status(status, initiatingUID: 501).preparationStep)
      jobs.note(request.ticket.identifier, step: "source_owner")
      XCTAssertEqual(try jobs.status(status, initiatingUID: 501).preparationStep, "source_owner")
      jobs.note(request.ticket.identifier, step: "stub_files_preflight")
      XCTAssertEqual(
        try jobs.status(status, initiatingUID: 501).preparationStep, "stub_files_preflight")
      jobs.finish(request.ticket.identifier, result: .failure(InstallerJobError.interrupted))
      jobs.note(request.ticket.identifier, step: "finishing_preflight")
      XCTAssertNil(try jobs.status(status, initiatingUID: 501).preparationStep)
    }

    func testObservationReportsEachNewHelperStepOnce() async throws {
      let request = try request()
      func snapshot(_ phase: InstallerJobPhase, step: String?) -> InstallerJobSnapshot {
        InstallerJobSnapshot(
          identifier: request.ticket.identifier, bindingDigest: request.ticket.bindingDigest,
          selection: request.ticket.selection, phase: phase, plan: nil,
          transcript: phase == .succeeded ? Data("result\n".utf8) : nil,
          installConf: phase == .succeeded ? .recorded : nil, failure: nil,
          journal: Data(), journalOffset: 0, recoveryAttempt: nil, recoveryRetryAvailable: false,
          startOverAvailable: nil, preparationStep: step)
      }
      let source = JobObservationFixture(responses: [
        .success(snapshot(.preparing, step: nil)),
        .success(snapshot(.preparing, step: "credential_validation")),
        .success(snapshot(.preparing, step: "credential_validation")),
        .success(snapshot(.preparing, step: "source_owner")),
        .success(snapshot(.succeeded, step: nil)),
      ])
      let reported = StepLog()
      let result = try await InstallerJobObservation.wait(
        fetch: { _ in try await source.next() }, preparation: { reported.append($0) },
        sleep: { _ in })
      XCTAssertEqual(result.phase, .succeeded)
      XCTAssertEqual(reported.steps, ["credential_validation", "source_owner"])
    }

    func testSnapshotsFromHelpersThatReportNoStepStillDecode() throws {
      let request = try request()
      let snapshot = InstallerJobSnapshot(
        identifier: request.ticket.identifier, bindingDigest: request.ticket.bindingDigest,
        selection: request.ticket.selection, phase: .running, plan: nil, transcript: nil,
        installConf: nil, failure: nil, journal: Data(), journalOffset: 0, recoveryAttempt: nil,
        recoveryRetryAvailable: false, startOverAvailable: nil, preparationStep: "source_owner")
      var fields = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
      XCTAssertEqual(fields["preparationStep"] as? String, "source_owner")
      fields.removeValue(forKey: "preparationStep")
      let older = try JSONDecoder().decode(
        InstallerJobSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
      XCTAssertNil(older.preparationStep)
      XCTAssertEqual(older.phase, .running)
    }

    func testTerminalResultSurvivesHelperRestartWithTheSameHandoffOutcome() throws {
      let root = try workspace()
      let first = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try first.begin(request, initiatingUID: 501))
      let transcript = Data("bounded transcript fixture\n".utf8)
      first.finish(
        request.ticket.identifier, result: .success((transcript, .unconfirmed(encrypt: true))))
      let restarted = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let snapshot = try restarted.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      let (result, handoff) = try snapshot.requireResult()
      XCTAssertEqual(result, transcript)
      XCTAssertEqual(handoff, .unconfirmed(encrypt: true))
    }

    func testRecoveryAttemptHistoryPreventsReplayAndKeepsTheOriginalOptionsAfterBadCredentials()
      throws
    {
      let root = try workspace()
      let jobs = InstallerJobRegistry(
        workingDirectory: root, work: HelperWorkState(), retryEligibility: { _ in true })
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      let packageURL = root.appendingPathComponent(
        "imported-handoff-" + UUID().uuidString.lowercased())
      let package = ImportedEngineHandoffPackage(
        packageURL: packageURL, manifestURL: packageURL, requestURL: packageURL,
        identityURL: packageURL,
        metadataURL: packageURL, payloadURL: packageURL,
        bindingDigest: request.ticket.bindingDigest, planDigest: String(repeating: "a", count: 64),
        deviceIdentifier: "apple,j314s", storeIdentifier: "disk0")
      try jobs.admitted(request.ticket.identifier, package: package)
      jobs.finish(
        request.ticket.identifier,
        result: .failure(PinnedAsahiEngineExecutionError.recoveryAuthorizationFailed))
      let first = InstallerJobRecoveryRequest(ticket: request.ticket, attempt: UUID())
      XCTAssertThrowsError(try jobs.beginRecoveryRetry(first, initiatingUID: 502))
      XCTAssertTrue(try jobs.beginRecoveryRetry(first, initiatingUID: 501))
      XCTAssertFalse(try jobs.beginRecoveryRetry(first, initiatingUID: 501))
      jobs.finish(
        request.ticket.identifier,
        result: .failure(ClosedEngineHelperError.invalidMachineOwnerCredentials))
      let status = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertTrue(status.recoveryRetryAvailable)
      XCTAssertEqual(status.recoveryAttempt, first.attempt)
      let second = InstallerJobRecoveryRequest(ticket: request.ticket, attempt: UUID())
      XCTAssertTrue(try jobs.beginRecoveryRetry(second, initiatingUID: 501))
      XCTAssertEqual(
        try jobs.recoveryContext(request.ticket.identifier).installConf, request.installConf)
      jobs.finish(
        request.ticket.identifier,
        result: .failure(PinnedAsahiEngineExecutionError.recoveryAuthorizationFailed))
      XCTAssertThrowsError(try jobs.beginRecoveryRetry(first, initiatingUID: 501))
      XCTAssertFalse(try jobs.beginRecoveryRetry(second, initiatingUID: 501))
    }

    func testUnconfirmableTerminalStateKeepsTheReplacementGateHeld() throws {
      let root = try workspace()
      let work = HelperWorkState()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: work)
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      jobs.finish(
        request.ticket.identifier,
        result: .success(
          (
            Data(repeating: 0, count: Int(PinnedAsahiEngineExecutor.maximumTranscriptBytes) + 1),
            .recorded
          )))
      XCTAssertFalse(work.beginReplacement(token: "replacement"))
      let status = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertEqual(status.phase, .interrupted)
    }

    func testCleanupRequiresDurableTerminalPersistence() throws {
      for rejectPersistence in [false, true] {
        let root = try workspace()
        let work = HelperWorkState()
        let jobs = InstallerJobRegistry(workingDirectory: root, work: work)
        let request = try request()
        XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
        let packageURL = root.appendingPathComponent(
          "imported-handoff-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let package = ImportedEngineHandoffPackage(
          packageURL: packageURL, manifestURL: packageURL, requestURL: packageURL,
          identityURL: packageURL,
          metadataURL: packageURL, payloadURL: packageURL,
          bindingDigest: request.ticket.bindingDigest,
          planDigest: String(repeating: "a", count: 64),
          deviceIdentifier: "apple,j314s", storeIdentifier: "disk0")
        try jobs.admitted(request.ticket.identifier, package: package)
        let state = root.appendingPathComponent("installation-jobs")
        if rejectPersistence { XCTAssertEqual(chmod(state.path, 0o755), 0) }
        let cleanup = jobs.finish(
          request.ticket.identifier, result: .success((Data("done".utf8), .recorded)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        if rejectPersistence {
          XCTAssertNil(cleanup)
          XCTAssertFalse(work.beginReplacement(token: "replacement"))
        } else {
          XCTAssertEqual(cleanup?.path, packageURL.path)
          XCTAssertTrue(work.beginReplacement(token: "replacement"))
        }
        XCTAssertEqual(chmod(state.path, 0o700), 0)
        let restored = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
        let snapshot = try restored.status(
          InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
        XCTAssertEqual(snapshot.phase, rejectPersistence ? .interrupted : .succeeded)
      }
    }

    func testAHintFromAnotherBuildIsAdmittedOnlyWhenAskedAndOnlyForTheSameService() throws {
      let service = InstallerProductIdentity.helperMachServiceName
      let identifier = "identifier \"\(InstallerProductIdentity.helperIdentifier)\""
      let current = identifier + " and cdhash H\"" + String(repeating: "1", count: 40) + "\""
      let earlier = identifier + " and cdhash H\"" + String(repeating: "2", count: 40) + "\""
      let hint = PendingInstallerJob(
        ticket: try request().ticket, helperMachServiceName: service,
        helperCodeSigningRequirement: earlier)
      func admits(_ hint: PendingInstallerJob, otherBuild: Bool) -> Bool {
        AuthenticatedEngineXPCSubmitter.admits(
          hint, machServiceName: service, helperCodeSigningRequirement: current,
          otherBuild: otherBuild)
      }
      XCTAssertFalse(admits(hint, otherBuild: false))
      XCTAssertTrue(admits(hint, otherBuild: true))
      let elsewhere = PendingInstallerJob(
        ticket: hint.ticket, helperMachServiceName: service + ".other",
        helperCodeSigningRequirement: current)
      XCTAssertFalse(admits(elsewhere, otherBuild: false))
      XCTAssertFalse(admits(elsewhere, otherBuild: true))

      // Adopting keeps the job and service and names this build's helper.
      let attempt = UUID()
      let adopted = hint.rebound(toHelperCodeSigningRequirement: current, recoveryAttempt: attempt)
      XCTAssertEqual(adopted.ticket, hint.ticket)
      XCTAssertEqual(adopted.helperMachServiceName, service)
      XCTAssertEqual(adopted.helperCodeSigningRequirement, current)
      XCTAssertEqual(adopted.recoveryAttempt, attempt)
      XCTAssertTrue(admits(adopted, otherBuild: false))
      let store = PendingInstallerJobStore(directory: try workspace())
      try store.save(adopted)
      XCTAssertEqual(try store.load(), adopted)
    }

    func testTheHelperIsAwaitedOnlyWhileItIsStarting() async throws {
      let pings = PingScript([
        .connectionFailed, .helperUnresponsive, .connectionFailed, nil,
      ])
      let slept = Counter()
      try await InstallerJobObservation.waitForHelper(
        attempts: 5, ping: { try await pings.next() }, sleep: { _ in slept.add() })
      let answered = await pings.calls
      XCTAssertEqual(answered, 4)
      XCTAssertEqual(slept.value, 3)

      let refusing = PingScript([.helperRejected(domain: "Helper", code: 1)])
      do {
        try await InstallerJobObservation.waitForHelper(
          attempts: 5, ping: { try await refusing.next() }, sleep: { _ in })
        XCTFail("A refusing helper was waited for.")
      } catch let error as EngineXPCSubmissionError {
        XCTAssertEqual(error, .helperRejected(domain: "Helper", code: 1))
      }
      let refused = await refusing.calls
      XCTAssertEqual(refused, 1)

      let silent = PingScript(Array(repeating: .connectionFailed, count: 10))
      do {
        try await InstallerJobObservation.waitForHelper(
          attempts: 3, ping: { try await silent.next() }, sleep: { _ in })
        XCTFail("A helper that never answered was reported reachable.")
      } catch let error as InstallerJobError {
        XCTAssertEqual(error, .unavailable)
      }
      let unanswered = await silent.calls
      XCTAssertEqual(unanswered, 3)
    }

    func testPendingHintRejectsAFIFOWithoutWaitingForAWriter() throws {
      let root = try workspace()
      let fifo = root.appendingPathComponent("pending-installation.json")
      XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
      XCTAssertThrowsError(try PendingInstallerJobStore(directory: root).load())
    }

    func testPendingHintRejectsSymlinksHardlinksAndPubliclyReadableState() throws {
      let root = try workspace()
      let store = PendingInstallerJobStore(directory: root)
      let hint = PendingInstallerJob(
        ticket: try request().ticket, helperMachServiceName: "org.aurora.helper",
        helperCodeSigningRequirement: "identifier \"org.aurora.helper\"")
      try store.save(hint)
      XCTAssertEqual(try store.load(), hint)
      let file = root.appendingPathComponent("pending-installation.json")
      XCTAssertEqual(chmod(file.path, 0o644), 0)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(chmod(file.path, 0o600), 0)
      let linkURL = root.appendingPathComponent("second-link")
      XCTAssertEqual(link(file.path, linkURL.path), 0)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(unlink(linkURL.path), 0)
      try FileManager.default.moveItem(at: file, to: linkURL)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linkURL)
      XCTAssertThrowsError(try store.load())
    }
  }

  private actor JobObservationFixture {
    private var responses: [Result<InstallerJobSnapshot, any Error>]
    private(set) var calls = 0
    init(responses: [Result<InstallerJobSnapshot, any Error>]) { self.responses = responses }
    func next() throws -> InstallerJobSnapshot {
      calls += 1
      return try responses.removeFirst().get()
    }
  }
  /// Answers each ping with the next scripted error, or nil for an answer.
  private actor PingScript {
    private var answers: [EngineXPCSubmissionError?]
    private(set) var calls = 0
    init(_ answers: [EngineXPCSubmissionError?]) { self.answers = answers }
    func next() throws {
      calls += 1
      if let error = answers.removeFirst() { throw error }
    }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
  }

  /// Steps an observation reported, in order.
  private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var steps: [String] { lock.withLock { recorded } }
    func append(_ step: String) { lock.withLock { recorded.append(step) } }
  }
#endif
