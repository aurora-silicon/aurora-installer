#if os(macOS)
  import Foundation
  import Observation
  import OmarchyAppleInstallerTrustCore
  import RecoveryAccountCore

  public enum InstallerSessionPhase: Equatable, Sendable {
    case inspecting
    case unsupported(FailureDisplay)
    case welcome(HostDisplay)
    /// Aurora is already on this Mac. The person may erase it or prepare a
    /// separate, fixed-size reinstall that keeps the enrolled startup setup.
    case existingInstallRefused(host: HostDisplay)
    case preparingPlan(AssetProgressUpdate)
    /// Everything is downloaded and verified; the plan waits for the person to
    /// continue instead of replacing the download screen on its own.
    case planPrepared(PlanDisplay, AssetProgressUpdate)
    case planReview(PlanDisplay, acknowledged: Bool)
    case awaitingInstall(
      PlanDisplay,
      helper: HelperDisplay,
      sheet: CredentialSheetState
    )
    case installing(InstallProgressDisplay)
    case awaitingRecovery(HandoffDisplay)
    case done(CompletionDisplay)
    case failed(FailureDisplay)
  }

  /// The whole installer flow as one guarded state machine.
  ///
  /// It replaces the eleven independent `@State` booleans of the previous view
  /// with a single phase plus the small number of latches that must survive a
  /// phase change (`hasExecutionStarted`, `recoveryRetryAvailable`). Every
  /// action is a guarded no-op unless the current phase allows it, so the
  /// fail-closed gates cannot be reached by an unexpected view event.
  @MainActor
  @Observable
  public final class InstallerSession {
    public private(set) var phase: InstallerSessionPhase = .inspecting
    public private(set) var recoveryAccount: RecoveryAccountReply?

    /// Live per-artifact download progress keyed by role, published from the
    /// stager's handler after a main-actor hop.
    public private(set) var stagingProgress = [String: ArtifactStagingProgress]()
    public private(set) var journal = LiveInstallJournalModel()
    public private(set) var isBusy = false
    private var isExecuting = false
    private var preservingStage1 = false
    private var operationID = UUID()
    public private(set) var planRevision = 0
    public private(set) var isEditingSize = false
    public private(set) var planNeedsCheck = false
    public private(set) var draftAllocationBytes: UInt64?
    private var preparationTask: Task<PlanPreparationDisplay, any Error>?
    private var preparationDrain: Task<Void, Never>?
    private var pendingPreparation: PreparationRequest?

    private struct PreparationRequest: Sendable {
      let id: UUID
      let host: HostDisplay?
      let bytes: UInt64?
      let hold: Bool
      let replanning: Bool
      let preservingStage1: Bool
    }

    public func setSizeEditing(_ editing: Bool) {
      guard !isExecuting, case .planReview = phase else { return }
      if editing && isBusy { cancelPlanPreparation() }
      isEditingSize = editing
    }
    public private(set) var allocationNotice: String?
    public private(set) var shutdownMessage: String?
    public private(set) var restartMessage: String?
    public private(set) var encryptLinuxDisk = true
    public let allowsEncryption: Bool
    public private(set) var prefetchState: PayloadPrefetchState = .verified

    /// What each channel offers this Mac, for the channel menu. Empty until
    /// the first check finishes; a channel missing here was not checked.
    public private(set) var channelAvailability = [ReleaseChannel: ReleaseChannelAvailability]()
    private var channelAvailabilityRequest = 0

    /// Re-reads every channel's signed catalog. Separate from `inspect()` so
    /// a slow or offline channel never holds up the page. Only the latest
    /// request's answer is kept, so a slow earlier one cannot overwrite it.
    public func refreshChannelAvailability() async {
      channelAvailabilityRequest += 1
      let request = channelAvailabilityRequest
      let availability = await environment.channelAvailability()
      guard request == channelAvailabilityRequest else { return }
      channelAvailability = availability
    }

    public var isSimulation: Bool { environment.isSimulation }
    public var canInspect: Bool {
      !isBusy && preparationDrain == nil && !isExecuting && !hasExecutionStarted
    }
    public var canChangeChannel: Bool {
      recoveryAccount == nil && canInspect && !isEditingSize && credentialSheet.context == nil
    }
    public var canEditPlan: Bool {
      guard case .awaitingInstall = phase else { return false }
      return canInspect && credentialSheet.context == nil
    }

    public func editPlan() {
      guard canEditPlan, case .awaitingInstall(let plan, _, _) = phase else { return }
      environment.discardApproval()
      phase = .planReview(plan, acknowledged: false)
    }

    /// One-shot latch: an approved plan may be submitted for execution once.
    /// Cleared only by the re-inspect / re-prepare reset cascades, plus the
    /// provable no-work cases: the helper rejected the credentials before it
    /// imported the package or started the engine, or the engine failed and
    /// the helper proved from its root-owned journal that no mutation began.
    public private(set) var hasExecutionStarted = false
    public private(set) var recoveryRetryAvailable = false
    private var restoredRecoveryRetry = false
    /// The helper reported that the failed installation may be set aside.
    /// Only the person's confirmed Start over acts on it.
    public private(set) var startOverAvailable = false
    public private(set) var startOverMessage: String?

    private let environment: any InstallerEnvironment
    private var retrySheet = CredentialSheetState.hidden
    private var installStartedAt = Date()
    /// The last successfully inspected host, kept so a re-plan that surfaces
    /// an existing install can still name the Mac it refused.
    private var lastHost: HostDisplay?
    private var lastOmarchyBytes: UInt64?
    private var lastPrepared: (plan: PlanDisplay, update: AssetProgressUpdate)?
    /// The approved plan the engine refused before changing the disk, kept so
    /// a re-plan can start from the size the person chose.
    private var refusedPlan: PlanDisplay?
    /// Identifies the running payload download watcher. A size change re-plans
    /// the same payload, so the download keeps going across it.
    private var prefetchID = UUID()
    private var isObservingPrefetch = false
    private var prefetchWatcher: Task<Void, Never>?

    public init(environment: any InstallerEnvironment, allowsEncryption: Bool = true) {
      self.allowsEncryption = allowsEncryption
      encryptLinuxDisk = allowsEncryption
      self.environment = environment
      prefetchState = environment.payloadPrefetchRequired ? .idle : .verified
      environment.setEncryptLinuxDisk(allowsEncryption)
    }

    // MARK: Derived state

    public var installationBlocked: Bool {
      if case .unsupported = phase {
        return true
      }
      return environment.installationBlocked
    }

    /// The header's word on this Mac model: false only for a refused model, so
    /// an existing install or too little space never reads as Not supported.
    /// Nil when the installer stopped before it could tell.
    public var modelSupported: Bool? {
      switch phase {
      case .inspecting:
        return nil
      case .existingInstallRefused(let host):
        return host.supported ? true : nil
      case .unsupported(let failure):
        if failure.isBlockedModel { return false }
        return failure.device?.supported == true ? true : nil
      default:
        return true
      }
    }

    public var credentialSheet: CredentialSheetState {
      if case .awaitingInstall(_, _, let sheet) = phase {
        return sheet
      }
      return retrySheet
    }

    /// Preserved verbatim from `canStartInstallation`: every conjunct still has
    /// to hold, even though the phase machine already makes some of them
    /// structurally impossible to violate.
    public var canStartInstallation: Bool {
      guard case .awaitingInstall(_, let helper, _) = phase else {
        return false
      }
      return !environment.installationBlocked
        && !isExecuting
        && !hasExecutionStarted
        && environment.engineSupported
        && environment.hasApprovedPlan
        && helper.isReady
        && prefetchState == .verified
    }

    /// Preserved verbatim from `canRetryRecoveryAuthorization`.
    public var canRetryRecoveryAuthorization: Bool {
      recoveryRetryAvailable
        && !environment.installationBlocked
        && !isExecuting
        && (restoredRecoveryRetry || (environment.engineSupported && environment.hasApprovedPlan))
        && environment.helperStatus.isReady
    }

    public var canStartOver: Bool {
      guard case .failed = phase else { return false }
      return startOverAvailable && hasExecutionStarted && !isBusy && !isExecuting
        && credentialSheet.context == nil
    }

    /// Sets the failed installation aside after the person confirmed Start
    /// over. The helper refuses a job that is still running or could not be
    /// confirmed stopped, and keeps the journal and evidence. Returns true
    /// once another system may be chosen.
    public func startOver() async -> Bool {
      guard canStartOver else { return false }
      isBusy = true
      defer { isBusy = false }
      startOverMessage = nil
      do {
        try await environment.startOverPendingInstallation()
      } catch {
        startOverMessage = PlainLanguage.startOverFailed
        await refreshPendingOptions()
        return false
      }
      restoredRecoveryRetry = false
      resetForInspection()
      phase = .inspecting
      return true
    }

    /// Asks the helper what the failed job allows. A job it can continue from
    /// its last verified step offers Try again, as it would after reopening.
    private func refreshPendingOptions(after error: (any Error)? = nil) async {
      startOverAvailable = false
      guard case .failed = phase, hasExecutionStarted else { return }
      let options = await environment.pendingInstallationOptions()
      startOverAvailable = options.startOver
      if options.retry, !recoveryRetryAvailable, let error {
        restoredRecoveryRetry = true
        recoveryRetryAvailable = true
        phase = .failed(PlainLanguage.failure(for: error, retryRecoveryAvailable: true))
      }
    }

    // MARK: Inspection

    public func inspect() async {
      guard canInspect else { return }
      operationID = UUID()
      resetForInspection()
      phase = .inspecting
      isBusy = true
      defer { isBusy = false }

      do {
        if try environment.hasPendingInstallation() {
          hasExecutionStarted = true
          isExecuting = true
          defer { isExecuting = false }
          installStartedAt = Date()
          phase = .installing(journal.display(startedAt: installStartedAt))
          let received = SessionJournalBuffer()
          let restoration = try await environment.resumeInstallation { [weak self] chunk in
            received.append(chunk)
            Task { @MainActor in self?.drainJournal(received) }
          }
          drainJournal(received)
          switch restoration {
          case .completed(let completion):
            await route(completion)
          case .failedBeforeDiskChanges(let failure):
            hasExecutionStarted = false
            phase = .failed(PlainLanguage.failure(for: failure))
          case .requiresRecoveryAuthorization:
            restoredRecoveryRetry = true
            recoveryRetryAvailable = true
            phase = .failed(
              PlainLanguage.failure(
                for: EngineXPCSubmissionError.recoveryAuthorizationFailed,
                retryRecoveryAvailable: true))
            await refreshPendingOptions()
          }
          return
        }
        let host = try await environment.inspect()
        recoveryAccount = nil
        // Completed journal identities are authoritative even when the legacy
        // inventory does not recognize the distribution's stub volume name.
        // Resume before checking whether another fresh installation could fit.
        if host.supported, !environment.installationBlocked {
          recoveryAccount = try await environment.inspectRecoveryAccount()
        }
        if recoveryAccount?.target != nil || !host.existingInstalls.isEmpty {
          // Refuse before anything is fetched: no catalog, no download.
          lastHost = host
          phase = .existingInstallRefused(host: host)
        } else if host.supported, !environment.installationBlocked,
          let shortfall = host.spaceShortfall
        {
          // Refuse before anything is fetched: the release could not fit.
          phase = .unsupported(PlainLanguage.failure(for: shortfall).on(host))
        } else if host.supported, !environment.installationBlocked {
          lastHost = host
          phase = .welcome(host)
        } else if let model = host.unsupportedModel {
          phase = .unsupported(PlainLanguage.unsupportedModel(model).on(host))
        } else {
          let blockedModel = environment.installationBlocked
          phase = .unsupported(
            FailureDisplay(
              headline: blockedModel
                ? PlainLanguage.blockedHeadline : PlainLanguage.notReadyHeadline,
              plainDetail: blockedModel
                ? PlainLanguage.blockedSubheadline
                : (host.blockingReason ?? PlainLanguage.notReadyDetail),
              technicalDetail: blockedModel ? nil : host.blockingReason,
              remedy: blockedModel ? PlainLanguage.blockedExplainer : nil,
              isBlockedModel: blockedModel,
              device: host
            )
          )
        }
      } catch {
        if error as? EngineXPCSubmissionError == .machineOwnerCredentialsRejected {
          hasExecutionStarted = false
        }
        if hasExecutionStarted {
          phase = .failed(PlainLanguage.failure(for: error))
          await refreshPendingOptions(after: error)
        } else {
          phase = .unsupported(PlainLanguage.failure(for: error))
        }
      }
    }

    // MARK: Plan preparation

    public func continueToPlan() async {
      guard case .welcome(let host) = phase else {
        return
      }
      preservingStage1 = false
      await preparePlan(host: host)
    }

    public var canPreparePreservedReinstall: Bool {
      guard case .existingInstallRefused(let host) = phase else { return false }
      return host.existingInstalls.count == 1 && !host.existingInstalls[0].partial
        && host.supported
        && !isBusy && !isExecuting && !hasExecutionStarted
        && !environment.installationBlocked && environment.engineSupported
    }

    public func reinstallPreservingStage1() async {
      guard canPreparePreservedReinstall,
        case .existingInstallRefused(let host) = phase
      else { return }
      preservingStage1 = true
      recoveryAccount = nil
      await preparePlan(host: host)
    }

    public func showExistingInstallOptions() {
      guard case .existingInstallRefused(let host) = phase,
        !host.existingInstalls.isEmpty
      else { return }
      recoveryAccount = nil
    }

    /// Every returned plan is reviewed anew, even when the engine clamps to
    /// the old allocation. A revision clears any tentative view value.
    public func replan(omarchyBytes: UInt64) async {
      guard !isExecuting, !hasExecutionStarted, case .planReview = phase else { return }
      await preparePlan(host: lastHost, omarchyBytes: omarchyBytes, hold: false)
    }

    /// After the engine refused the approved plan because the available space
    /// or disk layout moved, and proved no disk change began, prepare a new
    /// plan from the refused size. The normal size check clamps it to what is
    /// available now, and the new plan needs a fresh review and approval.
    public func replanAfterEngineRefusal() async {
      guard !isBusy, !isExecuting, !hasExecutionStarted,
        case .failed(let failure) = phase, failure.replanAvailable,
        let plan = refusedPlan
      else { return }
      refusedPlan = nil
      phase = .planReview(plan, acknowledged: false)
      await replan(omarchyBytes: plan.omarchyBytes)
    }

    public var canCancelPlanPreparation: Bool {
      guard isBusy, !isExecuting, !hasExecutionStarted else { return false }
      switch phase {
      case .preparingPlan, .planReview: return true
      default: return false
      }
    }

    public func cancelPlanPreparation() {
      guard canCancelPlanPreparation else { return }
      operationID = UUID()
      pendingPreparation = nil
      preparationTask?.cancel()
      environment.cancelPlanPreparation()
      isBusy = false
      if case .preparingPlan = phase {
        stopPrefetch()
        if let host = lastHost {
          phase = preservingStage1 ? .existingInstallRefused(host: host) : .welcome(host)
        }
      } else if case .planReview(let plan, _) = phase {
        planNeedsCheck = true
        phase = .planReview(plan, acknowledged: false)
      }
    }

    public func checkDraftAllocation() async {
      guard !isBusy, !isEditingSize, planNeedsCheck, case .planReview(let plan, _) = phase else {
        return
      }
      await replan(omarchyBytes: draftAllocationBytes ?? plan.omarchyBytes)
    }

    private func preparePlan(
      host: HostDisplay?,
      omarchyBytes: UInt64? = nil,
      hold: Bool = true
    ) async {
      guard !isExecuting && !hasExecutionStarted else { return }
      let replanning: Bool
      if case .planReview = phase { replanning = true } else { replanning = false }
      guard !isBusy || replanning else { return }
      operationID = UUID()
      let request = PreparationRequest(
        id: operationID, host: host, bytes: omarchyBytes, hold: hold, replanning: replanning,
        preservingStage1: preservingStage1)
      // Invalidate before cancelling: even a worker that ignores cancellation
      // cannot publish authority or send a late result into this generation.
      environment.cancelPlanPreparation()
      preparationTask?.cancel()
      pendingPreparation = request
      resetForPlanPreparation(keepingPrefetch: replanning)
      planNeedsCheck = replanning
      draftAllocationBytes = omarchyBytes
      lastOmarchyBytes = omarchyBytes
      if replanning, case .planReview(let plan, _) = phase {
        phase = .planReview(plan, acknowledged: false)
      } else {
        phase = .preparingPlan(AssetProgressUpdate(stage: .fetchingCatalog))
      }
      isBusy = true
      if preparationDrain == nil {
        preparationDrain = Task { [weak self] in
          guard let self else { return }
          await self.drainPreparations()
        }
      }
      await preparationDrain?.value
    }

    private func drainPreparations() async {
      defer {
        preparationDrain = nil
        if pendingPreparation == nil { isBusy = false }
      }
      while let request = pendingPreparation {
        pendingPreparation = nil
        let task = Task { [environment, session = self] in
          let progress: @Sendable (AssetProgressUpdate) -> Void = { update in
            Task { @MainActor in
              guard session.operationID == request.id else { return }
              session.applyPreparation(update)
            }
          }
          if request.preservingStage1 {
            return try await environment.preparePreservedReinstallPlan(progress: progress)
          }
          return try await environment.preparePlan(
            omarchyBytes: request.bytes, progress: progress)
        }
        preparationTask = task
        do {
          let outcome = try await task.value
          preparationTask = nil
          guard operationID == request.id else { continue }
          switch outcome {
          case .plan(let plan):
            planNeedsCheck = false
            draftAllocationBytes = nil
            planRevision += 1
            allocationNotice = request.bytes.flatMap {
              PlainLanguage.allocationNotice(requestedBytes: $0, actualBytes: plan.omarchyBytes)
            }
            let lastUpdate: AssetProgressUpdate =
              if case .preparingPlan(let update) = phase {
                update
              } else {
                lastPrepared?.update ?? AssetProgressUpdate(stage: .planning)
              }
            lastPrepared = (plan, lastUpdate)
            phase =
              request.hold
              ? .planPrepared(plan, lastUpdate) : .planReview(plan, acknowledged: false)
            if request.replanning {
              // The re-plan may have replaced or restarted the download. Watch it
              // afresh so no result from the old watcher counts for this plan.
              forgetPrefetchWatcher()
              if environment.payloadPrefetchRequired {
                prefetchState = environment.payloadPrefetchState
              }
            }
            startPrefetchIfNeeded()
          case .existingInstallChoice(let options):
            // Never replace, never install alongside: say what was found and
            // stop. The only way forward is to remove the existing copy first.
            stopPrefetch()
            guard let host = request.host, !options.isEmpty else {
              // A choice without the host context (or without options) has no
              // safe way forward; require a fresh inspection.
              phase = .failed(
                FailureDisplay(
                  headline: PlainLanguage.planChangedBeforeApproval,
                  plainDetail: PlainLanguage.inspectionRequired
                )
              )
              return
            }
            phase = .existingInstallRefused(host: host)
          }
        } catch {
          preparationTask = nil
          guard operationID == request.id else { continue }
          if error is CancellationError {
            environment.cancelPlanPreparation()
            if request.replanning, case .planReview(let plan, _) = phase {
              planNeedsCheck = true
              phase = .planReview(plan, acknowledged: false)
            } else if let host = request.host {
              stopPrefetch()
              phase = .welcome(host)
            }
          } else {
            stopPrefetch()
            phase = .failed(PlainLanguage.failure(for: error))
          }
        }
        if operationID == request.id { isBusy = false }
      }
    }

    private func applyPreparation(_ update: AssetProgressUpdate) {
      guard case .preparingPlan = phase else {
        return
      }
      for row in update.rows {
        if let existing = stagingProgress[row.role],
          existing.phase == .verified,
          row.phase != .verified
        {
          continue
        }
        stagingProgress[row.role] = ArtifactStagingProgress(
          role: row.role,
          fileName: row.fileName,
          phase: row.phase,
          partIndex: row.partIndex,
          partCount: row.partCount,
          bytesCompleted: row.bytesCompleted,
          totalBytes: row.totalBytes
        )
      }
      phase = .preparingPlan(
        AssetProgressUpdate(
          stage: update.stage,
          rows: AssetProgressRow.rows(from: stagingProgress)
        )
      )
    }

    // MARK: Review and approval

    /// Leave the finished download screen for the plan review. Only valid once
    /// preparation has completed; a no-op in every other phase.
    public func continueToPlanReview() {
      guard case .planPrepared(let plan, _) = phase else {
        return
      }
      phase = .planReview(plan, acknowledged: false)
    }

    public func setAcknowledged(_ value: Bool) {
      guard !isBusy, !planNeedsCheck, case .planReview(let plan, _) = phase else {
        return
      }
      phase = .planReview(plan, acknowledged: value)
    }

    public func setEncryptLinuxDisk(_ value: Bool) {
      guard allowsEncryption || !value else { return }
      guard !isBusy && !isExecuting else { return }
      switch phase {
      case .planReview, .awaitingInstall:
        encryptLinuxDisk = value
        environment.setEncryptLinuxDisk(value)
      default:
        break
      }
    }

    public func approve() {
      guard !isBusy && !isExecuting && !isEditingSize && !planNeedsCheck,
        case .planReview(let plan, let acknowledged) = phase,
        acknowledged
      else {
        return
      }
      do {
        try environment.approve()
        phase = .awaitingInstall(
          plan,
          helper: environment.refreshHelperStatus(),
          sheet: .hidden
        )
      } catch {
        phase = .failed(
          FailureDisplay(
            headline: PlainLanguage.planChangedBeforeApproval,
            plainDetail:
              "The plan needs a new disk check. Nothing was authorized.",
            technicalDetail: String(describing: error)
          )
        )
      }
    }

    // MARK: Helper

    public func refreshHelperStatus() {
      guard case .awaitingInstall(let plan, _, let sheet) = phase else {
        return
      }
      phase = .awaitingInstall(
        plan,
        helper: environment.refreshHelperStatus(),
        sheet: sheet
      )
    }

    // MARK: Credential sheet

    /// Called only after the start-installation confirmation dialog.
    public func presentInstallCredentials() {
      guard case .awaitingInstall(let plan, let helper, _) = phase,
        canStartInstallation
      else {
        return
      }
      phase = .awaitingInstall(
        plan,
        helper: helper,
        sheet: .presented(
          CredentialSheetContext(
            kind: .install,
            bindingDigest: plan.bindingDigest,
            mentionsBackgroundItem: helper.willInstall
          )
        )
      )
    }

    /// Called only after the recovery-retry confirmation dialog.
    public func presentRecoveryRetryCredentials() {
      guard case .failed(let failure) = phase,
        failure.retryRecoveryAvailable,
        canRetryRecoveryAuthorization
      else {
        return
      }
      retrySheet = .presented(
        CredentialSheetContext(
          kind: .retryRecoveryAuthorization,
          bindingDigest: "",
          mentionsBackgroundItem: environment.helperStatus.willInstall
        )
      )
    }

    /// Run by the credential sheet as it appears: asks the helper itself and,
    /// when the person switched it off in Login Items, tells the sheet so it
    /// can offer to turn it back on before the password is typed.
    public func checkWhetherHelperIsSwitchedOff() async {
      guard let context = credentialSheet.context, !context.helperSwitchedOff else {
        return
      }
      let helper = await environment.probeHelperStatus()
      guard helper.canTurnBackOn, let current = credentialSheet.context, current == context,
        !current.isVerifying
      else {
        return
      }
      let marked = current.withHelperSwitchedOff()
      if case .awaitingInstall(let plan, let shown, .presented) = phase {
        phase = .awaitingInstall(plan, helper: shown, sheet: .presented(marked))
      } else if case .presented = retrySheet {
        retrySheet = .presented(marked)
      }
    }

    public func dismissCredentials() {
      guard !isExecuting else { return }
      retrySheet = .hidden
      guard case .awaitingInstall(let plan, let helper, _) = phase else {
        return
      }
      phase = .awaitingInstall(plan, helper: helper, sheet: .hidden)
    }

    // MARK: Execution

    public func submit(_ authorization: MachineOwnerAuthorization) async {
      guard !isExecuting, let context = credentialSheet.context else {
        return
      }
      switch context.kind {
      case .install:
        guard canStartInstallation else {
          dismissCredentials()
          phase = .failed(
            FailureDisplay(
              headline: PlainLanguage.approvalUnavailable,
              plainDetail:
                "Check this Mac and review the plan again. Nothing was authorized."
            )
          )
          return
        }
        hasExecutionStarted = true
      case .retryRecoveryAuthorization:
        guard canRetryRecoveryAuthorization else {
          dismissCredentials()
          phase = .failed(
            FailureDisplay(
              headline: PlainLanguage.retryCheckpointUnavailable,
              plainDetail:
                "Authorization wasn’t granted. Installation remains stopped."
            )
          )
          return
        }
      }

      operationID = UUID()
      let currentOperation = operationID
      let receivedJournal = SessionJournalBuffer()
      let plan = approvedPlan
      let helper = environment.helperStatus
      // The sheet stays up, locked, while the helper checks the credentials.
      // The Install screen only appears once execution really starts (first
      // journal chunk) or the run ends without one.
      if context.kind == .install, let plan {
        phase = .awaitingInstall(plan, helper: helper, sheet: .presented(context.verifying()))
      } else {
        retrySheet = .presented(context.verifying())
      }
      journal.reset()
      installStartedAt = Date()
      isExecuting = true
      defer { isExecuting = false }

      do {
        // Helper setup comes first: it checks the credentials in the app and
        // installs or replaces the helper, before anything is submitted.
        try await environment.ensureHelper(
          authorization, reenablingSwitchedOff: context.helperSwitchedOff)
        // Recovery retry revalidates the original helper-owned package. A
        // reopened app has no download to wait for and must not start one.
        if context.kind != .retryRecoveryAuthorization, prefetchState != .verified {
          try await environment.waitUntilPayloadVerified()
          prefetchState = .verified
        }
        let completion = try await environment.execute(
          operation: context.kind,
          authorization: authorization,
          encryptLinuxDisk: encryptLinuxDisk,
          journal: { [weak self] chunk in
            receivedJournal.append(chunk)
            Task { @MainActor in
              guard let self, self.operationID == currentOperation else { return }
              self.drainJournal(receivedJournal)
            }
          }
        )
        guard operationID == currentOperation else { return }
        drainJournal(receivedJournal)
        operationID = UUID()
        recoveryRetryAvailable = false
        beginInstallingIfNeeded()
        await route(completion)
      } catch {
        drainJournal(receivedJournal)
        operationID = UUID()
        handleExecutionFailure(error, context: context, plan: plan, helper: helper)
        await refreshPendingOptions(after: error)
      }
    }

    /// Leaves the credential sheet behind and shows the Install screen. Safe
    /// to call more than once.
    private func beginInstallingIfNeeded() {
      if case .installing = phase {
        return
      }
      retrySheet = .hidden
      phase = .installing(journal.display(startedAt: installStartedAt))
    }

    private func handleExecutionFailure(
      _ error: any Error,
      context: CredentialSheetContext,
      plan: PlanDisplay?,
      helper: HelperDisplay
    ) {
      if error is InstallerPreSubmissionFailure {
        if context.kind == .install {
          hasExecutionStarted = false
          environment.discardApproval()
          recoveryRetryAvailable = false
        }
        retrySheet = .hidden
        phase = .failed(
          PlainLanguage.failure(for: error, retryRecoveryAvailable: recoveryRetryAvailable))
        return
      }

      if let submission = error as? EngineXPCSubmissionError,
        submission == .machineOwnerCredentialsRejected
      {
        // The helper validates the machine-owner credentials before it imports
        // the package or starts the engine, so no execution began: this is the
        // only case that releases the one-shot latch, and it reopens the sheet
        // instead of failing the run.
        if context.kind == .install {
          hasExecutionStarted = false
        }
        let rejected = context.failed(.credentialsRejected)
        if context.kind == .install, let plan {
          phase = .awaitingInstall(
            plan,
            helper: helper,
            sheet: .presented(rejected)
          )
        } else {
          retrySheet = .presented(rejected)
          phase = .failed(
            PlainLanguage.failure(
              for: error,
              retryRecoveryAvailable: recoveryRetryAvailable
            )
          )
        }
        return
      }

      if let setup = error as? InstallerHelperSetupError {
        // Helper setup runs before anything is submitted, so no execution
        // began. Like rejected credentials, this releases the latch and
        // reopens the sheet so the person can try again.
        if context.kind == .install {
          hasExecutionStarted = false
        }
        let sheetError: CredentialSheetError =
          switch setup {
          case .cancelled: .helperSetupCancelled
          case .switchedOff: .helperSwitchedOff
          case .busy: .helperBusy
          case .notAdministrator: .notAdministrator
          case .unavailable, .failed: .helperSetupFailed
          }
        let reopened = context.failed(sheetError)
        if context.kind == .install, let plan {
          phase = .awaitingInstall(plan, helper: helper, sheet: .presented(reopened))
        } else {
          retrySheet = .presented(reopened)
        }
        return
      }

      if context.kind == .install,
        case .engineFailed(let notice) = error as? EngineXPCSubmissionError,
        notice.diskUnchanged
      {
        // The helper derived this from the run's root-owned journal, not from
        // engine output: no event, checkpoint or completion was recorded, so
        // no disk mutation began. The latch may be released, as for rejected
        // credentials; any new attempt still needs a new reviewed plan.
        hasExecutionStarted = false
        refusedPlan = plan
      }
      if restoredRecoveryRetry, error as? EngineXPCSubmissionError == .notSubmitted {
        recoveryRetryAvailable = true
        phase = .failed(
          PlainLanguage.failure(
            for: EngineXPCSubmissionError.recoveryAuthorizationFailed, retryRecoveryAvailable: true)
        )
        return
      }
      beginInstallingIfNeeded()
      recoveryRetryAvailable = RecoveryAuthorizationRetryPolicy.isEligible(
        after: error
      )
      phase = .failed(
        PlainLanguage.failure(
          for: error,
          retryRecoveryAvailable: recoveryRetryAvailable
        )
      )
    }

    /// Retain the handoff even when another app rejects shutdown. A successful
    /// Apple Event dispatch is not proof that macOS has shut down.
    @discardableResult
    public func shutDown() -> Bool {
      guard case .awaitingRecovery = phase else { return false }
      let accepted = environment.requestShutdown()
      shutdownMessage =
        isSimulation
        ? (accepted
          ? "Simulation complete: shutdown would begin now. Your Mac stays on."
          : "Simulated shutdown failed. You can still use the setup steps below.")
        : (accepted
          ? "Shutdown requested. If another app stops it, save your work and choose Apple menu → Shut Down."
          : "Your Mac couldn’t shut down. Save your work, then choose Apple menu → Shut Down. Keep the setup steps handy.")
      return accepted
    }

    /// The native completion is emitted only after startup selection and its
    /// readback succeed. Do not offer a restart for a Recovery handoff.
    @discardableResult
    public func restartInstalledSystem() -> Bool {
      guard case .done(let completion) = phase,
        completion.nextAction == .verifyInstalledSystem
      else { return false }
      let accepted = environment.requestRestart()
      restartMessage =
        isSimulation
        ? "Simulation complete: restart would begin now. Your Mac stays on."
        : (accepted
          ? "Restart requested. If another app stops it, save your work and choose Apple menu → Restart."
          : "Your Mac couldn’t restart. Save your work, then choose Apple menu → Restart.")
      return accepted
    }

    public func prepareRecoveryAccount(username: String, password: Data) async throws {
      guard !isBusy, let ticket = recoveryAccount?.ticket else { return }
      isBusy = true
      defer { isBusy = false }
      recoveryAccount = try await environment.prepareRecoveryAccount(
        ticket: ticket, username: username, password: password)
    }

    public func finalizeRecoveryAccount(password: Data) async throws {
      guard !isBusy, let ticket = recoveryAccount?.ticket else { return }
      isBusy = true
      defer { isBusy = false }
      recoveryAccount = try await environment.finalizeRecoveryAccount(
        ticket: ticket, password: password)
    }

    public func openStartupDisk() -> Bool { environment.openStartupDisk() }

    public var powerButtonGuide: MacPowerButtonGuide { lastHost?.powerButtonGuide ?? .generic }

    public func prepareRecoveryHandoffAndShutdown() async throws -> Bool {
      guard !isBusy else { return false }
      isBusy = true
      defer { isBusy = false }
      let originalTarget = recoveryAccount?.target
      guard let refreshed = try await environment.inspectRecoveryAccount(),
        let target = refreshed.target, let ticket = refreshed.ticket
      else {
        throw AccountSetupFailure(
          "No completed installation is present on disk. Run the installation again before shutting down."
        )
      }
      if let originalTarget, originalTarget != target {
        throw AccountSetupFailure("The Recovery target changed. Inspect the installation again.")
      }
      let reply = try await environment.prepareRecoveryHandoff(ticket: ticket)
      guard reply.target == target, reply.ticket == ticket else {
        throw AccountSetupFailure("The Recovery target changed. Inspect the installation again.")
      }
      recoveryAccount = reply
      return environment.requestShutdown()
    }

    private func route(_ completion: CompletionDisplay) async {
      switch completion.nextAction {
      case .enterRecovery, .attachInstallationMedia:
        if let handoff = completion.handoff {
          if isSimulation {
            phase = .awaitingRecovery(handoff)
            return
          }
          do {
            guard let found = try await environment.inspectRecoveryAccount(),
              found.target != nil, found.ticket != nil
            else {
              throw AccountSetupFailure(
                "The completion record does not match an installation on disk. It may belong to a removed installation. Run the installation again."
              )
            }
            recoveryAccount = found
            phase = .awaitingRecovery(handoff)
          } catch {
            recoveryAccount = nil
            phase = .failed(
              FailureDisplay(
                headline: "Installation could not be verified",
                plainDetail: error.localizedDescription,
                remedy: "Check the disk again before continuing."))
          }
        } else {
          phase = .done(completion)
        }
      case .verifyInstalledSystem, .continueInstallation:
        phase = .done(completion)
      case .manualRecovery:
        phase = .failed(
          FailureDisplay(
            headline: "The installer encountered an error",
            plainDetail: PlainLanguage.nextActionMessage(.manualRecovery),
            remedy: "Check the last verified installation step before continuing."
          )
        )
      }
    }

    private func drainJournal(_ buffer: SessionJournalBuffer) {
      for chunk in buffer.takeAll() { consumeJournal(chunk) }
    }

    private func consumeJournal(_ chunk: Data) {
      if credentialSheet.context?.isVerifying == true {
        // The helper accepted the credentials and the engine has started.
        beginInstallingIfNeeded()
      }
      guard case .installing = phase else {
        return
      }
      journal.consume(chunk)
      phase = .installing(journal.display(startedAt: installStartedAt))
    }

    private var approvedPlan: PlanDisplay? {
      guard case .awaitingInstall(let plan, _, _) = phase else {
        return nil
      }
      return plan
    }

    public func cancelPrefetchOnQuit() {
      if !hasExecutionStarted && !isExecuting {
        operationID = UUID()
        pendingPreparation = nil
        preparationTask?.cancel()
        environment.cancelPlanPreparation()
      }
      environment.cancelPayloadPrefetchOnQuit()
      if prefetchState != .verified {
        prefetchState = .cancelled
      }
    }

    private func startPrefetchIfNeeded() {
      guard environment.payloadPrefetchRequired else {
        prefetchState = .verified
        return
      }
      if case .verified = prefetchState {
        return
      }
      guard !isObservingPrefetch else { return }
      isObservingPrefetch = true
      let currentPrefetch = UUID()
      prefetchID = currentPrefetch
      prefetchWatcher = Task { @MainActor in
        defer {
          if self.prefetchID == currentPrefetch { self.isObservingPrefetch = false }
        }
        do {
          try await environment.prefetchPayload { [weak self] state in
            Task { @MainActor in
              // A progress hop queued behind completion must not undo it.
              guard let self, self.prefetchID == currentPrefetch, self.isObservingPrefetch
              else { return }
              self.prefetchState = state
            }
          }
          guard self.prefetchID == currentPrefetch else { return }
          prefetchState = .verified
        } catch {
          guard self.prefetchID == currentPrefetch else { return }
          prefetchState = .failed(PayloadPrefetchFailure.reason(for: error))
        }
      }
    }

    /// Whether the failed strip offers Try again: only on the plan screens,
    /// before anything has run.
    public var canRetryPrefetch: Bool {
      guard case .failed = prefetchState, !isBusy, !isExecuting, !hasExecutionStarted
      else { return false }
      switch phase {
      case .planReview, .awaitingInstall:
        return true
      default:
        return false
      }
    }

    /// Restarts a failed payload download for the same plan. The payload does
    /// not depend on the plan's size, so the approval stays valid.
    public func retryPrefetch() {
      guard canRetryPrefetch else { return }
      environment.restartPayloadPrefetch()
      forgetPrefetchWatcher()
      startPrefetchIfNeeded()
    }

    private func forgetPrefetchWatcher() {
      prefetchWatcher?.cancel()
      prefetchWatcher = nil
      prefetchID = UUID()
      isObservingPrefetch = false
      prefetchState = environment.payloadPrefetchRequired ? .idle : .verified
    }

    private func stopPrefetch() {
      forgetPrefetchWatcher()
      environment.cancelPayloadPrefetch()
    }

    // MARK: Reset cascades

    /// Mirrors the field resets of `inspectThisMac()`: no approval, plan,
    /// progress, latch, or credential state may survive a re-inspection.
    private func resetForInspection() {
      environment.cancelPlanPreparation()
      planNeedsCheck = false
      draftAllocationBytes = nil
      isEditingSize = false
      shutdownMessage = nil
      restartMessage = nil
      allocationNotice = nil
      stagingProgress = [:]
      journal.reset()
      retrySheet = .hidden
      hasExecutionStarted = false
      recoveryRetryAvailable = false
      startOverAvailable = false
      startOverMessage = nil
      isExecuting = false
      lastHost = nil
      preservingStage1 = false
      refusedPlan = nil
      encryptLinuxDisk = allowsEncryption
      environment.setEncryptLinuxDisk(allowsEncryption)
      stopPrefetch()
    }

    /// Mirrors the field resets of `prepareSignedPlan()`. A size change keeps
    /// the payload download: the payload does not depend on the size, and the
    /// environment reuses an in-flight download of the same digest.
    private func resetForPlanPreparation(keepingPrefetch: Bool) {
      isEditingSize = false
      environment.discardApproval()
      stagingProgress = [:]
      journal.reset()
      retrySheet = .hidden
      hasExecutionStarted = false
      recoveryRetryAvailable = false
      startOverAvailable = false
      startOverMessage = nil
      isExecuting = false
      refusedPlan = nil
      if !keepingPrefetch {
        stopPrefetch()
      }
    }
  }
  /// Receipt is synchronous even when UI delivery needs a main-actor hop.
  /// Draining at completion preserves the final checkpoint before the reply.
  private final class SessionJournalBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    func append(_ chunk: Data) { lock.withLock { chunks.append(chunk) } }
    func takeAll() -> [Data] {
      lock.withLock {
        defer { chunks.removeAll(keepingCapacity: true) }
        return chunks
      }
    }
  }
#endif
