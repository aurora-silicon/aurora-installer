#if os(macOS)
  import Foundation

  /// App-side failure before any execution request; never wraps transport errors.
  public struct InstallerPreSubmissionFailure: Error, Sendable {
    public let underlying: any Error

    public init(_ underlying: any Error) {
      self.underlying = underlying
    }
  }

  public struct InstallerExecutionCoordinator: Sendable {
    private let processAdapter = ClosedEngineProcessAdapter()

    public init() {}

    public func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      journalProgress: (@Sendable (Data) -> Void)? = nil,
      jobContext: InstallerJobExecutionContext? = nil
    ) async throws -> InstallerExecutionProgress {
      try await execute(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: handoffDirectory,
        machineOwnerAuthorization: machineOwnerAuthorization,
        operation: .install,
        journalProgress: journalProgress,
        jobContext: jobContext
      )
    }

    public func retryRecoveryAuthorization(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      journalProgress: (@Sendable (Data) -> Void)? = nil,
      jobContext: InstallerJobExecutionContext? = nil
    ) async throws -> InstallerExecutionProgress {
      try await execute(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: handoffDirectory,
        machineOwnerAuthorization: machineOwnerAuthorization,
        operation: .retryRecoveryAuthorization,
        journalProgress: journalProgress,
        jobContext: jobContext
      )
    }

    private func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      configuration: InstallerReleaseConfiguration,
      handoffDirectory: URL,
      machineOwnerAuthorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation,
      journalProgress: (@Sendable (Data) -> Void)?,
      jobContext: InstallerJobExecutionContext?
    ) async throws -> InstallerExecutionProgress {
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement:
          configuration.helperCodeSigningRequirement,
        journalProgress: journalProgress,
        jobContext: jobContext
      )
      // Nothing leaves the app until the helper has answered.
      try await submitter.ping()
      let recoveryTemplate =
        prepared.review.plan.candidateKind == "reinstall"
        ? nil
        : Bundle.main.bundleURL.appendingPathComponent(
          "Contents/Resources/RecoveryTemplate/"
            + InstallerProductIdentity.recoveryAppBundleName)
      let process = ClosedEngineHandoffProcess(
        assets: prepared.review.assets,
        handoffDirectory: handoffDirectory,
        submitter: submitter,
        authorization: machineOwnerAuthorization,
        operation: operation,
        recoveryTemplate: recoveryTemplate
      )
      return try await execute(
        prepared,
        approval: approval,
        process: process
      )
    }

    func execute(
      _ prepared: PreparedInstallerPlanExecution,
      approval: CandidateBoundPlanApproval,
      process: any EngineProcessExecuting
    ) async throws -> InstallerExecutionProgress {
      let transcript = try await processAdapter.execute(
        prepared.candidateRequest,
        approval: approval,
        authorization: CandidateBoundExecutionAuthorization(
          approval: approval
        ),
        process: process
      )
      return try InstallerExecutionProgress(
        review: prepared.review,
        transcript: transcript
      )
    }
  }

  private struct CandidateBoundExecutionAuthorization:
    EngineExecutionAuthorizing
  {
    let approval: CandidateBoundPlanApproval

    func decision(
      for invocation: ClosedEngineInvocation
    ) async -> EngineAuthorizationDecision {
      guard approval.identity == invocation.candidateIdentity,
        approval.approvedBindingDigest
          == invocation.candidateIdentity.bindingDigest
      else {
        return .cancelled
      }
      return .granted
    }
  }
#endif
