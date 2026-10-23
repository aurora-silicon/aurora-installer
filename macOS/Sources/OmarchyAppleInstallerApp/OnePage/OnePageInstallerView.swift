import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

/// Version 2 of the installer: one page. The wordmark on top, this Mac in a
/// line, then whatever the moment needs — a download bar, the disk split, an
/// install bar, the Recovery steps — and one primary action underneath.
/// The trust chain and the session are untouched; only the presentation is
/// flattened.
struct OnePageInstallerView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var session: InstallerSession
  @State private var showsShutdownConfirmation = false
  @State private var showsRecoveryRetryConfirmation = false
  @State private var showsStartOverConfirmation = false
  private let device: MacHeaderDisplay
  /// Which channel this Mac reads. Owned by the scene so the banner always
  /// names the channel the next preparation will actually fetch; `nil` when
  /// the bundle has no release descriptor to fetch from.
  let selection: AuroraInstallationSelection
  let startAtPlan: Bool
  let channel: ReleaseChannel?
  let onChannelAvailability: (Bool) -> Void
  let onSessionAvailable: (InstallerSession) -> Void
  let onRemoveLinux: () -> Void
  let onChooseSystem: (() -> Void)?

  init(
    environment: any InstallerEnvironment,
    channel: ReleaseChannel?,
    selection: AuroraInstallationSelection = AuroraInstallationSelection(),
    startAtPlan: Bool = false,
    onChannelAvailability: @escaping (Bool) -> Void = { _ in },
    onSessionAvailable: @escaping (InstallerSession) -> Void = { _ in },
    onRemoveLinux: @escaping () -> Void = {},
    onChooseSystem: (() -> Void)? = nil
  ) {
    _session = State(
      initialValue: InstallerSession(
        environment: environment,
        allowsEncryption: selection.distribution.supportsDesktop
          && InstallerBuildProfile.current.allowsEncryption
      ))
    self.device = MacHeaderDisplay.inspect(isSimulation: environment.isSimulation)
    self.selection = selection
    self.startAtPlan = startAtPlan
    self.channel = channel
    self.onChannelAvailability = onChannelAvailability
    self.onSessionAvailable = onSessionAvailable
    self.onRemoveLinux = onRemoveLinux
    self.onChooseSystem = onChooseSystem
  }

  var body: some View {
    Group {
      if let account = session.recoveryAccount, let target = account.target {
        RecoveryHandoffView(
          volumeName: target.volumeName, session: session, selection: selection, device: device,
          onReinstall: preservedReinstallAction)
      } else if case .awaitingRecovery = session.phase {
        RecoveryHandoffView(
          volumeName: "Aurora", session: session.isSimulation ? nil : session, selection: selection,
          device: device)
      } else {
        installerPage
      }
    }
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .onChange(of: session.canChangeChannel, initial: true) { _, available in
      onChannelAvailability(available)
    }
    .task {
      onSessionAvailable(session)
      await recheck()
    }
    .onChange(of: channel) { _, _ in
      // Switching channel discards anything already planned: the new channel
      // may name a different release entirely.
      Task { await recheck() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        session.refreshHelperStatus()
      }
    }
    .onChange(of: session.phase, initial: true) { _, phase in
      if startAtPlan, case .welcome = phase {
        Task { await session.continueToPlan() }
      }
      // One page has no "everything is ready" stop: go straight to the plan.
      if case .planPrepared = phase {
        session.continueToPlanReview()
      }
    }
    .sheet(isPresented: credentialSheetBinding) {
      if let context = session.credentialSheet.context {
        CredentialSheet(
          context: context,
          isSimulation: session.isSimulation,
          onCancel: { session.dismissCredentials() },
          onSubmit: { authorization in
            Task { await session.submit(authorization) }
          },
          onCheckHelper: { await session.checkWhetherHelperIsSwitchedOff() }
        )
      }
    }
    .sheet(isPresented: $showsShutdownConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.shutdownConfirmationTitle,
        message: PlainLanguage.shutdownConfirmationBody,
        action: PlainLanguage.shutdownConfirmationAction,
        onConfirm: {
          showsShutdownConfirmation = false
          session.shutDown()
        },
        onCancel: { showsShutdownConfirmation = false }
      )
    }
    .sheet(isPresented: $showsRecoveryRetryConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.recoveryRetryConfirmationTitle,
        message: PlainLanguage.recoveryRetryConfirmationBody,
        action: PlainLanguage.recoveryRetryConfirmationAction,
        onConfirm: {
          showsRecoveryRetryConfirmation = false
          session.presentRecoveryRetryCredentials()
        },
        onCancel: { showsRecoveryRetryConfirmation = false }
      )
    }
    .sheet(isPresented: $showsStartOverConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.startOverConfirmationTitle,
        message: PlainLanguage.startOverConfirmationBody,
        action: PlainLanguage.startOverConfirmationAction,
        onConfirm: {
          showsStartOverConfirmation = false
          Task {
            guard await session.startOver() else { return }
            if let onChooseSystem { onChooseSystem() } else { await recheck() }
          }
        },
        onCancel: { showsStartOverConfirmation = false }
      )
    }
  }

  private var preservedReinstallAction: (() -> Void)? {
    guard case .existingInstallRefused(let host) = session.phase,
      host.existingInstalls.count == 1
    else { return nil }
    return { session.showExistingInstallOptions() }
  }

  private var installerPage: some View {
    InstallerPageLayout(
      showsFooter: session.phase != .inspecting, contentAlignment: pageContentAlignment
    ) {
      header
    } content: {
      VStack(alignment: .leading, spacing: 16) { stage }
    } actions: {
      HStack(spacing: 16) { actions }
    }
  }

  private var pageContentAlignment: Alignment {
    switch session.phase {
    case .inspecting, .welcome, .preparingPlan, .planPrepared: .center
    case .done(let completion) where completion.nextAction == .verifyInstalledSystem: .center
    default: .top
    }
  }

  // MARK: Header — this Mac in one line

  /// Inspects the Mac, then re-reads what each channel offers it.
  private func recheck() async {
    await session.inspect()
    await session.refreshChannelAvailability()
  }

  private var header: some View {
    InstallerMasthead(distribution: selection.distribution, device: device)
  }

  // MARK: The middle of the page

  @ViewBuilder
  private var stage: some View {
    switch session.phase {
    case .inspecting:
      PreparationStatusPanel()

    case .unsupported(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: false
      )

    case .welcome:
      Text(PlainLanguage.checkSubheadline)
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)

    case .existingInstallRefused:
      existingInstallRefusedPanel()

    case .preparingPlan(let update), .planPrepared(_, let update):
      DownloadPanel(update: update)

    case .planReview(let plan, let acknowledged):
      DiskSplitPanel(
        plan: plan,
        editable: plan.isResizable,
        isBusy: session.isBusy,
        pendingAllocationBytes: session.draftAllocationBytes,
        onSizeChosen: { bytes in
          session.setAcknowledged(false)
          Task { await session.replan(omarchyBytes: bytes) }
        },
        onEditingChange: { session.setSizeEditing($0) }
      )
      .id(session.planRevision)
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: !session.isBusy && !session.isEditingSize,
          onChange: { session.setEncryptLinuxDisk($0) }
        )
      } else if selection.distribution.supportsDesktop {
        Text("Linux will be installed without disk encryption.")
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      if let notice = session.allocationNotice {
        Text(notice).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      acknowledgement(acknowledged, plan: plan)

    case .awaitingInstall(let plan, let helper, _):
      DiskSplitPanel(plan: plan, editable: false, isBusy: false, onSizeChosen: { _ in })
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: false,
          onChange: { _ in }
        )
      } else if selection.distribution.supportsDesktop {
        Text("Linux will be installed without disk encryption.")
          .font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
      if !helper.isReady {
        helperNote
      }

    case .installing(let progress):
      InstallPanel(progress: progress)

    case .awaitingRecovery(let handoff):
      recoveryPanel(handoff)

    case .done(let completion):
      donePanel(completion)

    case .failed(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: true,
        retryAvailable: failure.retryRecoveryAvailable
      )
    }
  }

  // MARK: The one row of buttons

  @ViewBuilder
  private var actions: some View {
    switch session.phase {
    case .inspecting, .planPrepared:
      EmptyView()

    case .preparingPlan:
      Button("Cancel", action: session.cancelPlanPreparation)
        .omarchySecondaryButton()
        .disabled(!session.canCancelPlanPreparation)

    case .unsupported:
      Button(PlainLanguage.checkAgain) { Task { await recheck() } }
        .omarchySecondaryButton()
        .disabled(session.isBusy)

    case .welcome:
      Button(PlainLanguage.checkContinue) { Task { await session.continueToPlan() } }
        .omarchyPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)

    case .existingInstallRefused(let host):
      if let onChooseSystem {
        Button("Choose system", action: onChooseSystem)
          .omarchySecondaryButton()
          .disabled(session.isBusy)
      }
      if host.existingInstalls.count == 1, !host.existingInstalls[0].partial {
        Button("Reset Linux") {
          Task { await session.reinstallPreservingStage1() }
        }
        .omarchyPrimaryButton()
        .disabled(!session.canPreparePreservedReinstall)
      }
      Button("Erase Linux", role: .destructive, action: onRemoveLinux)
        .omarchySecondaryButton()
        .disabled(session.isBusy)

    case .planReview(let plan, let acknowledged):
      if session.canCancelPlanPreparation {
        Button("Cancel check", action: session.cancelPlanPreparation).omarchySecondaryButton()
      } else if session.planNeedsCheck {
        Button(plan.preservesStage1 ? "Check again" : "Check size") {
          Task { await session.checkDraftAllocation() }
        }
        .omarchySecondaryButton()
        .disabled(session.isEditingSize)
      }
      Button(plan.preservesStage1 ? "Reset Linux" : PlainLanguage.planInstall) {
        // Approve the exact plan and go straight to the password. If the
        // helper is not ready the page stays here and says so.
        session.approve()
        if session.canStartInstallation {
          session.presentInstallCredentials()
        }
      }
      .omarchyPrimaryButton()
      .disabled(
        !acknowledged || session.isBusy || session.isEditingSize || session.planNeedsCheck
          || session.prefetchState != .verified
      )
      .keyboardShortcut(.defaultAction)

    case .awaitingInstall(let plan, _, _):
      Button(plan.preservesStage1 ? "Back to review" : "Change size") {
        session.editPlan()
      }
      .omarchySecondaryButton()
      .disabled(!session.canEditPlan)
      Button(plan.preservesStage1 ? "Reset Linux" : PlainLanguage.planInstall) {
        session.presentInstallCredentials()
      }
      .omarchyPrimaryButton()
      .disabled(!session.canStartInstallation)
      .keyboardShortcut(.defaultAction)

    case .installing:
      Text(PlainLanguage.installWarning)
        .font(OmarchyTheme.detail.weight(.medium))
        .foregroundStyle(OmarchyTheme.accent)

    case .awaitingRecovery:
      if !session.isSimulation {
        Button(PlainLanguage.recoveryShutDown) { showsShutdownConfirmation = true }
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }

    case .done(let completion):
      if completion.nextAction == .verifyInstalledSystem {
        Button("Restart") { session.restartInstalledSystem() }
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Close") { NSApplication.shared.terminate(nil) }
          .omarchySecondaryButton()
      }

    case .failed(let failure):
      if session.canInspect {
        Button("Check again") { Task { await recheck() } }
          .omarchySecondaryButton()
      }
      if session.canStartOver {
        Button(PlainLanguage.startOver) { showsStartOverConfirmation = true }
          .omarchySecondaryButton()
      }
      if failure.retryRecoveryAvailable {
        Button(PlainLanguage.retry) { showsRecoveryRetryConfirmation = true }
          .omarchyPrimaryButton()
          .disabled(!session.canRetryRecoveryAuthorization)
          .keyboardShortcut(.defaultAction)
      } else if failure.replanAvailable {
        Button(PlainLanguage.replanAction) {
          Task { await session.replanAfterEngineRefusal() }
        }
        .omarchyPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)
      } else if let url = failure.actionURL, let title = failure.actionTitle {
        Button(title) {
          if !session.isSimulation { NSWorkspace.shared.open(url) }
        }
        .disabled(session.isSimulation)
        .omarchyPrimaryButton()
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Pieces

  private func messagePanel(
    headline: String, detail: String, remedy: String?, technical: String?, isError: Bool,
    retryAvailable: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 8) {
        Text(headline)
          .font(OmarchyTheme.heading)
          .foregroundStyle(isError ? OmarchyTheme.danger : OmarchyTheme.text)
        Text(detail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let remedy {
          Text(remedy)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        if let technical {
          InstallerDetailsButton(title: "Technical details", text: technical).padding(.top, 4)
        }
        if session.hasExecutionStarted && !retryAvailable {
          Text(
            "This installation can’t be started again yet. Review the installation record below, and keep this Mac plugged in."
          )
          .font(OmarchyTheme.body)
          InstallerDetailsButton(
            title: "Last verified steps",
            text: ([headline, detail, technical ?? ""]
              + (session.journal.feed.isEmpty
                ? ["No completed disk step was confirmed. Disk changes may still have started."]
                : session.journal.feed.map(\.text)))
              .joined(separator: "\n"))
        }
        if let message = session.startOverMessage {
          Text(message)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func existingInstallRefusedPanel() -> some View {
    guard case .existingInstallRefused(let host) = session.phase else {
      return ExistingInstallationContent(partial: false)
    }
    return ExistingInstallationContent(
      partial: !host.existingInstalls.isEmpty && host.existingInstalls.allSatisfy(\.partial))
  }

  private func acknowledgement(_ acknowledged: Bool, plan: PlanDisplay) -> some View {
    Toggle(
      plan.preservesStage1
        ? PlainLanguage.planPreservedAcknowledgement
        : PlainLanguage.planAcknowledgement(
          resizesMacOS: plan.allocationSource != .freeExtent),
      isOn: Binding(get: { acknowledged }, set: { session.setAcknowledged($0) })
    )
    .toggleStyle(.checkbox)
    .controlSize(.regular)
    .font(OmarchyTheme.body)
    .tint(.blue)
    .disabled(session.isBusy || session.isEditingSize || session.planNeedsCheck)
  }

  private var helperNote: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield")
        .foregroundStyle(OmarchyTheme.caution)
      Text(PlainLanguage.helperNotInstalled)
        .omarchyHelpText()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }

  private func recoveryPanel(_ handoff: HandoffDisplay) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(handoff.headline)
        .font(OmarchyTheme.heading)
        .padding(.bottom, 4)
      if let warning = handoff.warning {
        Text(warning)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(handoff.steps) { step in
        RecoveryStepRow(step: step)
      }
      if let message = session.shutdownMessage {
        Text(message).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
    }
  }

  @ViewBuilder
  private func donePanel(_ completion: CompletionDisplay) -> some View {
    if completion.nextAction == .verifyInstalledSystem {
      VStack(spacing: 14) {
        AuroraMark().frame(width: 72, height: 72)
        Text(completion.headline)
          .font(.system(size: 24, weight: .semibold))
        Text("Restart to start Aurora.")
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
        if let message = session.restartMessage {
          Text(message).font(OmarchyTheme.detail).foregroundStyle(OmarchyTheme.caution)
        }
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text(completion.headline).font(OmarchyTheme.heading)
        Text(completion.subheadline)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Plumbing

  private var credentialSheetBinding: Binding<Bool> {
    Binding(
      get: { session.credentialSheet.context != nil },
      set: { presented in
        if !presented {
          session.dismissCredentials()
        }
      }
    )
  }

}

// MARK: - Prefetch strip and encryption

struct PrefetchStrip: View {
  let state: PayloadPrefetchState
  var onRetry: (() -> Void)?

  var body: some View {
    if showsStrip {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(PlainLanguage.prefetchTitle(for: state))
              .font(OmarchyTheme.heading)
            Spacer(minLength: 8)
            if let accessory {
              Text(accessory)
                .font(OmarchyTheme.detail)
                .foregroundStyle(OmarchyTheme.secondaryText)
            }
          }
          if case .failed(let reason) = state {
            Text(reason)
              .omarchyHelpText()
              .textSelection(.enabled)
            if let onRetry {
              Button(PlainLanguage.prefetchRetry, action: onRetry)
            }
          } else {
            ProgressTrack(fraction: fraction)
          }
        }
      }
      .padding(.vertical, 8)
    }
  }

  private var showsStrip: Bool {
    switch state {
    case .verified, .idle: false
    default: true
    }
  }

  private var fraction: Double? {
    switch state {
    case .downloading(let completed, let total), .paused(let completed, let total):
      total > 0 ? Double(completed) / Double(total) : nil
    case .verifying:
      1
    default:
      nil
    }
  }

  private var accessory: String? {
    switch state {
    case .downloading(let completed, let total), .paused(let completed, let total):
      total > 0 && completed < total
        ? "\(PlainLanguage.bytes(completed)) of \(PlainLanguage.bytes(total))" : nil
    default:
      nil
    }
  }
}

struct ExistingInstallationContent: View {
  var partial = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(partial ? PlainLanguage.partialInstallHeadline : PlainLanguage.existingInstallHeadline)
        .font(OmarchyTheme.heading)
      Text(
        partial
          ? PlainLanguage.partialInstallDetail
          : "Reset Linux in its current space while keeping Stage 1, or erase Linux and return its space to macOS."
      )
      .font(OmarchyTheme.body)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct EncryptDiskToggle: View {
  let isOn: Bool
  let enabled: Bool
  let onChange: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        PlainLanguage.encryptLinuxDiskTitle,
        isOn: Binding(
          get: { isOn },
          set: { value in onChange(value) }
        )
      )
      .toggleStyle(.checkbox)
      .controlSize(.regular)
      .font(OmarchyTheme.body)
      .tint(.blue)
      .disabled(!enabled)
      // One help paragraph: the password, and that nothing else unlocks the disk.
      Text(PlainLanguage.encryptLinuxDiskPassword + " " + PlainLanguage.encryptLinuxDiskNoRecovery)
        .omarchyHelpText()
        .padding(.leading, 20)
    }
  }
}

// MARK: - The download bar

/// One bar for the OS package download; later stages (engine checks,
/// planning) keep the last position instead of resetting.
struct DownloadPanel: View {
  let update: AssetProgressUpdate

  private var package: AssetProgressRow? { update.rows.first { $0.role == "payload" } }

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        Text("Preparing your installation").font(.system(size: 20, weight: .medium))
        Text(title).font(OmarchyTheme.body).foregroundStyle(.secondary)
      }
      VStack(spacing: 10) {
        ProgressTrack(fraction: fraction)
        HStack {
          if let package, update.stage == .downloading, package.totalBytes > 0 {
            Text(
              "\(PlainLanguage.bytes(package.bytesCompleted)) of \(PlainLanguage.bytes(package.totalBytes))"
            )
          }
          Spacer()
          if let fraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
        }
        .font(OmarchyTheme.detail).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity)
  }

  private var title: String {
    update.stage == .downloading
      ? PlainLanguage.downloadingPackagesTitle : PlainLanguage.preparingStageTitle(update.stage)
  }

  private var fraction: Double? {
    guard update.stage == .downloading, let package, package.totalBytes > 0 else { return nil }
    return min(1, Double(package.bytesCompleted) / Double(package.totalBytes))
  }
}

// MARK: - The disk split

/// The disk bar with the draggable divider. Letting go on a new whole-GB
/// size re-plans; the chosen size stays on screen until the new plan lands.
struct DiskSplitPanel: View {
  let plan: PlanDisplay
  let editable: Bool
  let isBusy: Bool
  var pendingAllocationBytes: UInt64? = nil
  let onSizeChosen: (UInt64) -> Void
  var onEditingChange: (Bool) -> Void = { _ in }
  #if DEBUG
    var opensSizePromptForPreview = false
  #endif

  @State private var exploredOmarchyGB: Double?
  @State private var sizeInput = DiskSizeInput()
  @State private var showsSizePrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(plan.preservesStage1 ? "Review your reset" : "Choose your space")
        .font(.system(size: 22, weight: .semibold))
      if plan.preservesStage1 {
        Text(
          "Stage 1, its startup name and icon, and partition sizes stay. EFI boot files, Linux Boot and Root are replaced, erasing Linux accounts and files."
        )
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.secondaryText)
      }
      HStack(alignment: .top) {
        capacity("macOS", bytes: plan.macOSBytes(for: displayedOmarchyBytes), highlighted: false)
        Spacer()
        capacity("Aurora", bytes: displayedOmarchyBytes, highlighted: true)
      }
      DiskBar(
        macOSBytes: plan.macOSBytes(for: displayedOmarchyBytes),
        omarchyBytes: displayedOmarchyBytes,
        unallocatedBytes: plan.unallocatedBytes(for: displayedOmarchyBytes),
        otherAllocatedBytes: plan.otherAllocatedBytes(for: displayedOmarchyBytes),
        macOSSpaceCaution: plan.macOSSpaceCaution(for: displayedOmarchyBytes),
        onAdjustOmarchyFraction: editable ? { adjust($0) } : nil,
        onCommitOmarchyFraction: editable ? { commit($0) } : nil,
        isFrozen: sizeInput.isEditing
      )
      .transaction { $0.animation = nil }
      if isBusy {
        Text("Checking available space…")
          .font(OmarchyTheme.detail).foregroundStyle(.secondary)
      }
      ForEach(plan.spaceCautions(for: displayedOmarchyBytes), id: \.self) { caution in
        Text(caution).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
    }
    .sheet(
      isPresented: $showsSizePrompt,
      onDismiss: {
        if sizeInput.isEditing { cancelSize() }
      }
    ) {
      DiskSizePrompt(
        input: $sizeInput, minimumBytes: plan.minimumBytes, maximumBytes: plan.maximumBytes,
        onApply: applySize, onCancel: cancelSize)
    }
    .onChange(of: plan.omarchyBytes) { _, _ in exploredOmarchyGB = nil }
    .onAppear {
      #if DEBUG
        if opensSizePromptForPreview { beginSizeEdit() }
      #endif
    }
  }

  private func capacity(_ title: String, bytes: UInt64, highlighted: Bool) -> some View {
    VStack(alignment: highlighted ? .trailing : .leading, spacing: 5) {
      Text(title).font(OmarchyTheme.detail).foregroundStyle(.secondary)
      HStack(alignment: .center, spacing: 9) {
        if highlighted && editable {
          Button(action: beginSizeEdit) {
            Image(systemName: "pencil").font(.system(size: 18, weight: .medium))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel("Edit Aurora size")
          .help("Edit Aurora size")
        }
        Text(PlainLanguage.bytes(bytes)).font(.system(size: 28, weight: .medium, design: .rounded))
          .monospacedDigit().foregroundStyle(highlighted ? OmarchyTheme.accent : OmarchyTheme.text)
      }
    }
  }

  private var displayedOmarchyBytes: UInt64 {
    guard let exploredOmarchyGB else { return pendingAllocationBytes ?? plan.omarchyBytes }
    return UInt64(exploredOmarchyGB * 1_000_000_000)
  }

  private func beginSizeEdit() {
    guard editable else { return }
    sizeInput.begin(
      bytes: displayedOmarchyBytes, minimum: plan.minimumBytes, maximum: plan.maximumBytes)
    onEditingChange(true)
    showsSizePrompt = true
  }

  private func applySize() {
    guard let chosen = sizeInput.apply() else { return }
    showsSizePrompt = false
    onEditingChange(false)
    if chosen != plan.omarchyBytes || pendingAllocationBytes != nil { onSizeChosen(chosen) }
  }

  private func cancelSize() {
    sizeInput.cancel()
    showsSizePrompt = false
    onEditingChange(false)
  }

  private func adjust(_ fraction: Double) {
    onEditingChange(true)
    let requested = Double(plan.diskTotalBytes) * min(1, max(0, fraction))
    let chosen = min(Double(plan.maximumBytes), max(Double(plan.minimumBytes), requested))
    exploredOmarchyGB = chosen / 1_000_000_000
  }

  private func commit(_ fraction: Double) {
    adjust(fraction)
    onEditingChange(false)
    let rounded = (Double(displayedOmarchyBytes) / 1_000_000_000).rounded() * 1_000_000_000
    let chosen = min(plan.maximumBytes, max(plan.minimumBytes, UInt64(rounded)))
    if chosen != plan.omarchyBytes || pendingAllocationBytes != nil {
      onSizeChosen(chosen)
    } else {
      exploredOmarchyGB = nil
    }
  }
}

struct DiskSizePrompt: View {
  @Binding var input: DiskSizeInput
  let minimumBytes: UInt64
  let maximumBytes: UInt64
  let onApply: () -> Void
  let onCancel: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Space for Aurora").font(.system(size: 18, weight: .semibold))
      HStack(spacing: 8) {
        TextField("Size", text: $input.text)
          .textFieldStyle(.roundedBorder).font(OmarchyTheme.control)
          .frame(width: 110).focused($focused).autocorrectionDisabled()
          .accessibilityLabel("Aurora size in gigabytes")
          .onSubmit { if input.requestedBytes != nil { onApply() } }
        Text("GB").font(OmarchyTheme.body).foregroundStyle(.secondary)
      }
      Text(
        input.validationMessage
          ?? "From \(PlainLanguage.bytes(minimumBytes)) to \(PlainLanguage.bytes(maximumBytes))"
      )
      .font(OmarchyTheme.detail)
      .foregroundStyle(
        input.validationMessage == nil ? OmarchyTheme.secondaryText : OmarchyTheme.danger
      )
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel", action: onCancel).omarchySecondaryButton(size: .large).keyboardShortcut(
          .cancelAction)
        Button("Apply", action: onApply).omarchyPrimaryButton(size: .large)
          .disabled(input.requestedBytes == nil).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 330)
    .foregroundStyle(OmarchyTheme.text).background(OmarchyTheme.window)
    .task { focused = true }
  }
}

// MARK: - The install bar

/// Stage count and verified activity describe progress without inventing a
/// percentage for operations whose duration is unknown.
struct InstallPanel: View {
  let progress: InstallProgressDisplay

  var body: some View {
    VStack {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Installing Aurora").font(.system(size: 24, weight: .semibold))
          Text(progress.phaseTitle).font(OmarchyTheme.body).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 18) {
          ForEach(Array(progress.stageLabels.enumerated()), id: \.offset) { index, label in
            HStack(spacing: 13) {
              stageMark(index).frame(width: 22, height: 22)
              Text(label).font(
                .system(size: 14, weight: index == progress.stageIndex ? .medium : .regular)
              )
              .foregroundStyle(
                index <= progress.stageIndex ? OmarchyTheme.text : OmarchyTheme.secondaryText)
            }
          }
        }
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
          HStack {
            Text(
              "Step \(min(progress.stageIndex + 1, progress.stageLabels.count)) of \(progress.stageLabels.count)"
            )
            Spacer()
            Text("\(elapsed(at: context.date)) elapsed").monospacedDigit()
          }
          .font(OmarchyTheme.detail).foregroundStyle(.secondary)
        }
        InstallerDetailsButton(
          title: "View activity",
          text: progress.feed.isEmpty
            ? "No activity recorded yet." : progress.feed.map(\.text).joined(separator: "\n"))
        if progress.degraded {
          Text(PlainLanguage.installDegraded).omarchyHelpText()
        }
      }
      .padding(.vertical, 12)
    }
  }

  private func verified(_ index: Int) -> Bool {
    progress.stageFractions.indices.contains(index) && progress.stageFractions[index] >= 1
  }

  @ViewBuilder private func stageMark(_ index: Int) -> some View {
    if verified(index) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
        .foregroundStyle(OmarchyTheme.success)
    } else if index == progress.stageIndex {
      NativeSpinner().controlSize(.small)
    } else {
      Image(systemName: "circle").font(.system(size: 20)).foregroundStyle(.tertiary)
    }
  }

  private func elapsed(at date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(progress.startedAt)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Quiet, keyboard-sized actions that share the editor's terminal palette.
private struct SizeEditButtonStyle: ButtonStyle {
  let tint: Color
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    SizeEditButtonBody(configuration: configuration, tint: tint, isEnabled: isEnabled)
  }

  private struct SizeEditButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .foregroundStyle(isEnabled ? tint : OmarchyTheme.secondaryText.opacity(0.4))
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(
              tint.opacity(
                isEnabled && configuration.isPressed ? 0.20 : isEnabled && isHovered ? 0.10 : 0))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
              isEnabled && isHovered ? tint.opacity(0.35) : OmarchyTheme.separator.opacity(0.5),
              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
  }
}
