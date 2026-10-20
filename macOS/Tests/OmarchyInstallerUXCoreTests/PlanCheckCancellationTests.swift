#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyInstallerUXCore

  @MainActor
  final class PlanCheckCancellationTests: XCTestCase {
    private func session(_ environment: MockInstallerEnvironment) async -> InstallerSession {
      environment.plan = SerialPreparationFixture.plan(128_000_000_000)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      return session
    }

    private func waitForDraft(_ bytes: UInt64, session: InstallerSession) async {
      let deadline = Date().addingTimeInterval(3)
      while session.draftAllocationBytes != bytes && Date() < deadline { await Task.yield() }
      XCTAssertEqual(session.draftAllocationBytes, bytes)
    }

    func testLatestDraftWinsWithoutConcurrentPreparationOrLateFailure() async {
      let environment = MockInstallerEnvironment()
      let session = await session(environment)
      let firstBytes: UInt64 = 160_000_000_000
      let lastBytes: UInt64 = 220_000_000_000
      let gate = OperationGate()
      let fixture = SerialPreparationFixture(first: firstBytes, gate: gate, failFirst: true)
      environment.prepareHandler = { bytes, progress in
        try await fixture.prepare(bytes, progress: progress)
      }
      let first = Task { await session.replan(omarchyBytes: firstBytes) }
      await gate.waitUntilEntered()
      XCTAssertTrue(session.canCancelPlanPreparation)
      let second = Task { await session.replan(omarchyBytes: 180_000_000_000) }
      await waitForDraft(180_000_000_000, session: session)
      let last = Task { await session.replan(omarchyBytes: lastBytes) }
      await waitForDraft(lastBytes, session: session)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)
      XCTAssertTrue(session.isBusy)
      await gate.release()
      await first.value
      await second.value
      await last.value
      let statistics = await fixture.statistics()
      XCTAssertEqual(statistics.requests, [firstBytes, lastBytes])
      XCTAssertEqual(statistics.maximumActive, 1)
      guard case .planReview(let plan, let acknowledged) = session.phase else {
        return XCTFail("A stale failure must not replace the latest successful plan")
      }
      XCTAssertEqual(plan.omarchyBytes, lastBytes)
      XCTAssertFalse(acknowledged)
      XCTAssertFalse(session.planNeedsCheck)
      XCTAssertFalse(session.isBusy)
      XCTAssertNil(session.draftAllocationBytes)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 1)
    }

    func testCancelledDraftCannotBeApprovedAndLateSuccessCannotRestoreIt() async {
      let environment = MockInstallerEnvironment()
      let session = await session(environment)
      let gate = OperationGate()
      let fixture = SerialPreparationFixture(first: 160_000_000_000, gate: gate)
      environment.prepareHandler = { bytes, progress in
        try await fixture.prepare(bytes, progress: progress)
      }
      let check = Task { await session.replan(omarchyBytes: 160_000_000_000) }
      await gate.waitUntilEntered()
      session.cancelPlanPreparation()
      XCTAssertFalse(session.isBusy)
      XCTAssertTrue(session.planNeedsCheck)
      XCTAssertEqual(session.draftAllocationBytes, 160_000_000_000)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)
      XCTAssertFalse(environment.hasApprovedPlan)
      await gate.release()
      await check.value
      XCTAssertTrue(session.planNeedsCheck)
      guard case .planReview(let plan, _) = session.phase else {
        return XCTFail("Keep the draft visible")
      }
      XCTAssertEqual(plan.omarchyBytes, 128_000_000_000)
      // Checking the same draft explicitly is necessary before approval.
      environment.prepareHandler = nil
      environment.plan = SerialPreparationFixture.plan(160_000_000_000)
      await session.checkDraftAllocation()
      XCTAssertFalse(session.planNeedsCheck)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 1)
    }

    func testEditingRemainsAvailableAndCancelsAnOlderCheck() async {
      let environment = MockInstallerEnvironment()
      let session = await session(environment)
      let gate = OperationGate()
      let fixture = SerialPreparationFixture(first: 160_000_000_000, gate: gate)
      environment.prepareHandler = { bytes, progress in
        try await fixture.prepare(bytes, progress: progress)
      }
      let check = Task { await session.replan(omarchyBytes: 160_000_000_000) }
      await gate.waitUntilEntered()
      session.setSizeEditing(true)
      XCTAssertTrue(session.isEditingSize)
      XCTAssertFalse(session.isBusy)
      XCTAssertTrue(session.planNeedsCheck)
      await gate.release()
      await check.value
      XCTAssertTrue(session.isEditingSize)
      XCTAssertTrue(session.planNeedsCheck)
      XCTAssertEqual(environment.executeCount, 0)
    }

    func testInitialPreparationCancellationIgnoresLateProgressAndOutcome() async {
      for fail in [false, true] {
        let environment = MockInstallerEnvironment()
        let session = InstallerSession(environment: environment)
        await session.inspect()
        let gate = OperationGate()
        let fixture = SerialPreparationFixture(first: nil, gate: gate, failFirst: fail)
        environment.prepareHandler = { bytes, progress in
          try await fixture.prepare(bytes, progress: progress)
        }
        let preparation = Task { await session.continueToPlan() }
        await gate.waitUntilEntered()
        session.cancelPlanPreparation()
        guard case .welcome = session.phase else { return XCTFail("Return to Welcome") }
        XCTAssertFalse(session.canInspect, "Wait for owned query cleanup before a new inspection")
        await gate.release()
        await preparation.value
        await Task.yield()
        guard case .welcome = session.phase else { return XCTFail("Ignore abandoned completion") }
        XCTAssertTrue(session.canInspect)
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(environment.hasApprovedPlan)
        XCTAssertEqual(environment.executeCount, 0)
      }
    }
  }

  private actor SerialPreparationFixture {
    let first: UInt64?
    let gate: OperationGate
    let failFirst: Bool
    private var requests: [UInt64?] = []
    private var active = 0
    private var maximumActive = 0

    init(first: UInt64?, gate: OperationGate, failFirst: Bool = false) {
      self.first = first
      self.gate = gate
      self.failFirst = failFirst
    }

    nonisolated static func plan(_ bytes: UInt64) -> PlanDisplay {
      PlanDisplay(
        diskTotalBytes: 512_000_000_000, omarchyBytes: bytes, bindingDigest: String(bytes),
        minimumBytes: 32_000_000_000, maximumBytes: 256_000_000_000)
    }

    func prepare(
      _ bytes: UInt64?, progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay {
      requests.append(bytes)
      active += 1
      maximumActive = max(maximumActive, active)
      defer { active -= 1 }
      if bytes == first {
        await gate.wait()
        // Intentionally ignore cancellation to exercise ownership guards.
        progress(AssetProgressUpdate(stage: .planning))
        if failFirst { throw CancellationFixtureError.oldFailure }
      }
      return .plan(Self.plan(bytes ?? 128_000_000_000))
    }

    func statistics() -> (requests: [UInt64?], maximumActive: Int) {
      (requests, maximumActive)
    }
  }

  private enum CancellationFixtureError: Error { case oldFailure }
#endif
