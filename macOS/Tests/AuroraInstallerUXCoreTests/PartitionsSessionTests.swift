#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest

  @testable import AuroraInstallerUXCore

  @MainActor
  final class PartitionsSessionTests: XCTestCase {
    private func environment(_ layout: DiskLayoutDisplay?) -> MockInstallerEnvironment {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: MockInstallerEnvironment.supportedHost.chipAndSpace, supported: true,
        diskLayout: layout)
      return environment
    }

    private func partitions(_ session: InstallerSession) -> DiskLayoutDisplay? {
      if case .partitions(_, let layout) = session.phase { layout } else { nil }
    }

    func testAComplexDiskShowsPartitionsBeforeAnythingIsFetched() async {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      XCTAssertEqual(partitions(session), layout)
      XCTAssertEqual(session.modelSupported, true)
      XCTAssertEqual(environment.prepareCount, 0)
      XCTAssertTrue(session.canChoosePartitionAction)
      // The single-macOS actions are no-ops here.
      await session.continueToPlan()
      XCTAssertEqual(environment.prepareCount, 0)
    }

    func testASingleMacOSKeepsTodaysFlow() async {
      var disk = LayoutFixture()
      disk.add(.macOS, "Macintosh HD", 400 * LayoutFixture.gb, free: 200 * LayoutFixture.gb)
      let environment = environment(disk.display())
      let session = InstallerSession(environment: environment)
      await session.inspect()
      guard case .welcome = session.phase else {
        return XCTFail("Expected the usual flow, got \(session.phase)")
      }
      await session.continueToPlan()
      XCTAssertEqual(environment.prepareCount, 1)
      XCTAssertTrue(environment.targets.isEmpty)
    }

    func testChosenFreeSpaceIsPlannedAloneAndKeptAcrossSizeChanges() async throws {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      let option = try XCTUnwrap(layout.options.first { $0.kind == .freeSpace })
      await session.install(into: option.target)
      session.continueToPlanReview()
      guard case .planReview = session.phase else {
        return XCTFail("Expected the size screen, got \(session.phase)")
      }
      await session.replan(auroraBytes: 30_000_000_000)
      XCTAssertEqual(environment.targets, [option.target, option.target])
      XCTAssertEqual(environment.lastAuroraBytes, 30_000_000_000)
      // Then the usual Install → password flow.
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      XCTAssertNotNil(session.credentialSheet.context)
    }

    func testOnlyTheScreensOwnOptionsAndResettableRowsAreAccepted() async {
      let environment = environment(LayoutFixture.mixed().display())
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.install(into: .freeSpace(offsetBytes: 12_345))
      await session.install(into: .shrink(sourceIdentifier: "disk0s5"))
      XCTAssertEqual(environment.prepareCount, 0)
      // Asahi has no Reset.
      XCTAssertFalse(session.canReset("disk0s5"))
      await session.reset("disk0s5")
      XCTAssertEqual(environment.preservedPrepareCount, 0)
      XCTAssertNotNil(partitions(session))
    }

    func testResetActsOnTheChosenInstallationOnly() async {
      let environment = environment(LayoutFixture.mixed().display())
      let session = InstallerSession(environment: environment)
      await session.inspect()
      XCTAssertTrue(session.canReset("disk0s4"))
      await session.reset("disk0s4")
      XCTAssertEqual(environment.preservedSources, ["disk0s4"])
      XCTAssertEqual(environment.prepareCount, 0)
      session.continueToPlanReview()
      guard case .planReview(let plan, _) = session.phase else {
        return XCTFail("Expected the reset review, got \(session.phase)")
      }
      XCTAssertTrue(plan.preservesStage1)
    }

    func testThePlanScreenCanGoBackToPartitionsBeforeAnythingRuns() async throws {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      let shrink = try XCTUnwrap(layout.options.first { $0.kind == .shrink })
      await session.install(into: shrink.target)
      session.continueToPlanReview()
      XCTAssertTrue(session.canReturnToPartitions)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertTrue(environment.hasApprovedPlan)
      session.returnToPartitions()
      XCTAssertEqual(partitions(session), layout)
      XCTAssertFalse(environment.hasApprovedPlan)
      XCTAssertFalse(session.canReturnToPartitions)
      // A later choice plans afresh, for its own target only.
      let free = try XCTUnwrap(layout.options.first { $0.kind == .freeSpace })
      await session.install(into: free.target)
      XCTAssertEqual(environment.targets, [shrink.target, free.target])
    }

    func testCancellingTheFirstPreparationReturnsToPartitions() async throws {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      let gate = OperationGate()
      environment.prepareGate = gate
      let session = InstallerSession(environment: environment)
      await session.inspect()
      let option = try XCTUnwrap(layout.options.first)
      let preparing = Task { await session.install(into: option.target) }
      await gate.waitUntilEntered()
      session.cancelPlanPreparation()
      await gate.release()
      await preparing.value
      XCTAssertEqual(partitions(session), layout)
    }

    func testAnUnfinishedRecoveryStepStillComesFirst() async {
      let layout = LayoutFixture.mixed().display()
      let environment = environment(layout)
      environment.hasCompletedInstallation = true
      let session = InstallerSession(environment: environment)
      await session.inspect()
      XCTAssertNotNil(session.recoveryAccount?.target)
      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected the Recovery handoff first, got \(session.phase)")
      }
      session.showExistingInstallOptions()
      XCTAssertEqual(partitions(session), nil)
      // With an existing installation listed, its options are the Partitions screen.
      environment.host = HostDisplay(
        chipAndSpace: MockInstallerEnvironment.supportedHost.chipAndSpace, supported: true,
        existingInstalls: [
          ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "80 GB")
        ],
        diskLayout: layout)
      await session.inspect()
      session.showExistingInstallOptions()
      XCTAssertEqual(partitions(session), layout)
    }

    func testAnUnsupportedOrBlockedMacNeverShowsPartitions() async {
      let environment = environment(LayoutFixture.mixed().display())
      environment.installationBlocked = true
      let session = InstallerSession(environment: environment)
      await session.inspect()
      XCTAssertNil(partitions(session))
      XCTAssertFalse(session.canChoosePartitionAction)
    }
  }
#endif
