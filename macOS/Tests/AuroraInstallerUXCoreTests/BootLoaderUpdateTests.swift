#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest

  @testable import AuroraInstallerUXCore

  @MainActor
  final class BootLoaderUpdateTests: XCTestCase {
    private func environment(_ layout: DiskLayoutDisplay) -> MockInstallerEnvironment {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: MockInstallerEnvironment.supportedHost.chipAndSpace, supported: true,
        diskLayout: layout)
      return environment
    }

    private static let staged = CompletionDisplay(
      nextAction: .enterRecovery, headline: PlainLanguage.bootLoaderUpdateHeadline,
      subheadline: PlainLanguage.bootLoaderShutdownBody, verified: [],
      handoff: HandoffDisplay(
        headline: PlainLanguage.bootLoaderUpdateHeadline,
        steps: PlainLanguage.bootLoaderUpdateRecoverySteps()))

    private func reviewed(_ session: InstallerSession, row: String) async throws -> PlanDisplay {
      await session.updateBootLoader(row)
      session.continueToPlanReview()
      guard case .planReview(let plan, _) = session.phase else {
        throw XCTSkip("Expected the update review, got \(session.phase)")
      }
      return plan
    }

    func testUpdateIsOfferedOnlyWhereResetIsAndUsesThatInstallationsPlan() async throws {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      // An installation recognition doesn't fully confirm gets no update.
      XCTAssertFalse(session.canUpdateBootLoader("disk0s5"))
      await session.updateBootLoader("disk0s5")
      XCTAssertEqual(environment.preservedPrepareCount, 0)
      XCTAssertTrue(session.canUpdateBootLoader("disk0s4"))
      let plan = try await reviewed(session, row: "disk0s4")
      XCTAssertEqual(environment.preservedSources, ["disk0s4"])
      XCTAssertTrue(plan.updatesBootLoader)
      XCTAssertTrue(plan.preservesStage1)
      XCTAssertTrue(session.updatingBootLoader)
      // Back on Partitions, Reset is Reset again.
      session.returnToPartitions()
      XCTAssertFalse(session.updatingBootLoader)
      await session.reset("disk0s4")
      session.continueToPlanReview()
      guard case .planReview(let reset, _) = session.phase else {
        return XCTFail("Expected the reset review, got \(session.phase)")
      }
      XCTAssertFalse(reset.updatesBootLoader)
    }

    func testAnApprovedUpdateGoesToRecoveryWithoutTheAccountHandoff() async throws {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      environment.executeResults = [.success(Self.staged)]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      _ = try await reviewed(session, row: "disk0s4")
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      XCTAssertEqual(session.credentialSheet.context?.kind, .updateBootLoader)
      let lookups = environment.accountCalls.filter { $0 == "inspect" }.count
      await session.submit(
        try MachineOwnerAuthorization(username: "owner", password: Data("pw".utf8)))
      XCTAssertEqual(environment.lastOperation, .updateBootLoader)
      guard case .awaitingRecovery(let handoff) = session.phase else {
        return XCTFail("Expected the Recovery steps, got \(session.phase)")
      }
      XCTAssertEqual(handoff.headline, PlainLanguage.bootLoaderUpdateHeadline)
      let name = try XCTUnwrap(layout.row("disk0s4")?.name)
      XCTAssertTrue(handoff.steps.last?.detail?.contains(name) == true, "\(handoff.steps)")
      XCTAssertNil(session.recoveryAccount)
      XCTAssertEqual(
        environment.accountCalls.filter { $0 == "inspect" }.count, lookups,
        "an update looks for no recovery account")
      XCTAssertEqual(session.journal.stepLabels, PlainLanguage.bootLoaderUpdateSteps)
    }

    func testAnUnchangedBootLoaderEndsWithoutRecovery() async throws {
      let environment = environment(LayoutFixture.mixed().display())
      environment.executeResults = [
        .success(
          CompletionDisplay(
            nextAction: .continueInstallation,
            headline: PlainLanguage.bootLoaderUpToDateHeadline,
            subheadline: PlainLanguage.bootLoaderUpToDateMessage, verified: [], handoff: nil))
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      _ = try await reviewed(session, row: "disk0s4")
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(
        try MachineOwnerAuthorization(username: "owner", password: Data("pw".utf8)))
      guard case .done(let completion) = session.phase else {
        return XCTFail("Expected the up-to-date screen, got \(session.phase)")
      }
      XCTAssertEqual(completion.headline, PlainLanguage.bootLoaderUpToDateHeadline)
      XCTAssertFalse(session.restartInstalledSystem())
    }

    func testARejectedPasswordReopensTheSheetForTheUpdate() async throws {
      let environment = environment(LayoutFixture.mixed().display())
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.machineOwnerCredentialsRejected)
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      _ = try await reviewed(session, row: "disk0s4")
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(
        try MachineOwnerAuthorization(username: "owner", password: Data("wrong".utf8)))
      let context = try XCTUnwrap(session.credentialSheet.context)
      XCTAssertEqual(context.kind, .updateBootLoader)
      XCTAssertEqual(context.error, .credentialsRejected)
    }

    func testAnEarlierInstallationsResetPointsToTheUpdate() throws {
      let display = PlainLanguage.engineFailure(
        EngineFailureNotice(
          reason: .reinstallRequired, exitStatus: 1, diskUnchanged: true,
          summary: "This installation's boot loader is from an earlier Aurora installer."),
        technicalDetail: "detail")
      XCTAssertEqual(display.headline, "Update this installation’s boot loader first")
      let remedy = try XCTUnwrap(display.remedy)
      XCTAssertTrue(remedy.hasPrefix(PlainLanguage.bootLoaderUpdateRemedy), remedy)
      XCTAssertTrue(remedy.contains("Update Boot Loader…"), remedy)
    }

    func testAStoppedUpdateSaysWhatChanged() throws {
      for unchanged in [true, false] {
        let display = PlainLanguage.engineFailure(
          EngineFailureNotice(
            reason: .bootLoaderUpdateRefused, exitStatus: 1, diskUnchanged: unchanged,
            summary: "The EFI partition has no m1n1/boot-ctxr.bin yet."),
          technicalDetail: "detail")
        XCTAssertEqual(display.headline, "The boot loader wasn’t updated")
        XCTAssertTrue(display.plainDetail.hasPrefix("The EFI partition has no"))
        XCTAssertEqual(display.plainDetail.contains("No disk changes were made."), unchanged)
        XCTAssertEqual(display.plainDetail.contains("Recovery files may have"), !unchanged)
        XCTAssertFalse(display.replanAvailable)
      }
    }
  }
#endif
