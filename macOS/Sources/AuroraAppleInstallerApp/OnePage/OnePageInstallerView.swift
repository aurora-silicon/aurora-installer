import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
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
  /// The option chosen under Add a new installation.
  @State private var selectedPartitionOption: String?
  /// The row whose Erase or Reset sheet is open.
  @State private var erasingRow: DiskLayoutDisplay.Row?
  @State private var resettingRow: DiskLayoutDisplay.Row?
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
  /// Erase one installation: the removal service's review, which must find
  /// the startup container with this partition UUID.
  let onEraseInstallation: (DiskLayoutDisplay.EraseTarget) -> Void
  let onChooseSystem: (() -> Void)?
  /// Rendering an already driven session: no inspection on appear and no
  /// sheets, which the renderer draws on their own.
  private var rendersExistingSession = false

  init(
    environment: any InstallerEnvironment,
    channel: ReleaseChannel?,
    selection: AuroraInstallationSelection = AuroraInstallationSelection(),
    startAtPlan: Bool = false,
    onChannelAvailability: @escaping (Bool) -> Void = { _ in },
    onSessionAvailable: @escaping (InstallerSession) -> Void = { _ in },
    onRemoveLinux: @escaping () -> Void = {},
    onEraseInstallation: @escaping (DiskLayoutDisplay.EraseTarget) -> Void = { _ in },
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
    self.onEraseInstallation = onEraseInstallation
    self.onChooseSystem = onChooseSystem
  }

  #if DEBUG
    /// The flow renderer's page for a session it drives itself.
    init(
      renderingSession session: InstallerSession, selection: AuroraInstallationSelection,
      selectedPartitionOption: String? = nil
    ) {
      _session = State(initialValue: session)
      _selectedPartitionOption = State(initialValue: selectedPartitionOption)
      device = .simulation
      self.selection = selection
      startAtPlan = false
      channel = .testing
      onChannelAvailability = { _ in }
      onSessionAvailable = { _ in }
      onRemoveLinux = {}
      onEraseInstallation = { _ in }
      onChooseSystem = {}
      rendersExistingSession = true
    }
  #endif

  var body: some View {
    Group {
      if let account = session.recoveryAccount, let target = account.target {
        RecoveryHandoffView(
          volumeName: target.volumeName, session: session, selection: selection, device: device,
          onReinstall: preservedReinstallAction)
      } else if case .awaitingRecovery = session.phase, !session.updatingBootLoader {
        RecoveryHandoffView(
          volumeName: "Aurora", session: session.isSimulation ? nil : session, selection: selection,
          device: device)
      } else {
        installerPage
      }
    }
    .foregroundStyle(InstallerTheme.text)
    .background(InstallerTheme.window)
    .onChange(of: session.canChangeChannel, initial: true) { _, available in
      onChannelAvailability(available)
    }
    .task {
      guard !rendersExistingSession else { return }
      onSessionAvailable(session)
      await recheck()
    }
    .onChange(of: channel) { previous, current in
      // Settling this launch's default fills in the channel a preparation
      // already waited for, so it restarts nothing.
      guard previous != nil, current != nil else { return }
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
        message: session.updatingBootLoader
          ? PlainLanguage.bootLoaderShutdownBody : PlainLanguage.shutdownConfirmationBody,
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
    .sheet(item: $erasingRow) { row in
      if case .partitions(_, let layout) = session.phase {
        EraseInstallationSheet(
          layout: layout, row: row, onCancel: { erasingRow = nil },
          onErase: {
            erasingRow = nil
            if let target = row.eraseTarget { onEraseInstallation(target) }
          })
      }
    }
    .sheet(item: $resettingRow) { row in
      ResetInstallationSheet(
        row: row, selection: selection, onCancel: { resettingRow = nil },
        onReset: {
          resettingRow = nil
          Task { await session.reset(row.id) }
        })
    }
    .onChange(of: session.phase) { _, phase in
      if case .partitions(_, let layout) = phase,
        let selected = selectedPartitionOption,
        !layout.options.contains(where: { $0.id == selected })
      {
        selectedPartitionOption = nil
      }
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
      showsFooter: session.phase != .inspecting, contentAlignment: pageContentAlignment,
      footerAlignment: footerAlignment, scrollsContent: isPartitions
    ) {
      header
    } content: {
      VStack(alignment: .leading, spacing: Space.l) { stage }
    } actions: {
      HStack(spacing: Space.l) { actions }
    }
  }

  private var isPartitions: Bool {
    if case .partitions = session.phase { true } else { false }
  }

  /// Buttons end at the column's right edge; the install screen's warning
  /// reads from its left.
  private var footerAlignment: Alignment {
    if case .installing = session.phase { .leading } else { .trailing }
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
    // A Reset or boot loader update shows the installation's own channel.
    InstallerMasthead(
      distribution: selection.distribution, device: device,
      channel: session.existingInstallationChannel ?? channel,
      existingInstallation: session.existingInstallationChannel != nil)
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
        .font(InstallerTheme.body)
        .foregroundStyle(InstallerTheme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xs)

    case .existingInstallRefused:
      existingInstallRefusedPanel()

    case .partitions(_, let layout):
      PartitionsPanel(
        layout: layout, selectedOption: $selectedPartitionOption,
        enabled: session.canChoosePartitionAction,
        onShrink: { target in Task { await session.install(into: target) } },
        onErase: { erasingRow = $0 },
        onReset: { resettingRow = $0 },
        onUpdateBootLoader: { row in Task { await session.updateBootLoader(row.id) } },
        onOpenStartupDisk: { _ = session.openStartupDisk() })

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
          Task { await session.replan(auroraBytes: bytes) }
        },
        onEditingChange: { session.setSizeEditing($0) }
      )
      .id(session.planRevision)
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if plan.updatesBootLoader {
        EmptyView()
      } else if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: !session.isBusy && !session.isEditingSize,
          onChange: { session.setEncryptLinuxDisk($0) }
        )
      } else if selection.distribution.supportsDesktop {
        CautionCallout(text: "The Aurora disk won’t be encrypted.")
      }
      if let notice = session.allocationNotice {
        CautionCallout(text: notice)
      }
      if let stubNote = plan.stubOverrideNote {
        CautionCallout(text: stubNote)
      }
      if ExperimentalMac.thisMac, !plan.preservesStage1 {
        experimentalNote
      }
      acknowledgement(acknowledged, plan: plan)

    case .awaitingInstall(let plan, let helper, _):
      DiskSplitPanel(plan: plan, editable: false, isBusy: false, onSizeChosen: { _ in })
      PrefetchStrip(
        state: session.prefetchState,
        onRetry: session.canRetryPrefetch ? { session.retryPrefetch() } : nil
      )
      if plan.updatesBootLoader {
        EmptyView()
      } else if session.allowsEncryption {
        EncryptDiskToggle(
          isOn: session.encryptLinuxDisk,
          enabled: false,
          onChange: { _ in }
        )
      } else if selection.distribution.supportsDesktop {
        CautionCallout(text: "The Aurora disk won’t be encrypted.")
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
        .auroraSecondaryButton()
        .disabled(!session.canCancelPlanPreparation)

    case .unsupported:
      Button(PlainLanguage.checkAgain) { Task { await recheck() } }
        .auroraSecondaryButton()
        .disabled(session.isBusy)

    case .welcome:
      Button(PlainLanguage.checkContinue) { Task { await session.continueToPlan() } }
        .auroraPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)

    case .existingInstallRefused(let host):
      // The erase sits first, away from the default button, and never takes Return.
      Button("Erase Linux…", role: .destructive, action: onRemoveLinux)
        .auroraDangerButton()
        .disabled(session.isBusy)
      if let onChooseSystem {
        Button("Choose a system", action: onChooseSystem)
          .auroraSecondaryButton()
          .disabled(session.isBusy)
      }
      if host.existingInstalls.count == 1, !host.existingInstalls[0].partial {
        // Reset opens a plan to review; nothing changes until it is approved.
        Button("Reset Linux…") {
          Task { await session.reinstallPreservingStage1() }
        }
        .auroraPrimaryButton()
        .disabled(!session.canPreparePreservedReinstall)
        .keyboardShortcut(.defaultAction)
      }

    case .partitions(_, let layout):
      if let onChooseSystem {
        Button("Choose a system", action: onChooseSystem)
          .auroraSecondaryButton()
          .disabled(session.isBusy)
      }
      Button(PlainLanguage.checkContinue) {
        guard let option = layout.options.first(where: { $0.id == selectedPartitionOption })
        else { return }
        Task { await session.install(into: option.target) }
      }
      .auroraPrimaryButton()
      .disabled(
        !session.canChoosePartitionAction
          || !layout.options.contains(where: { $0.id == selectedPartitionOption })
      )
      .keyboardShortcut(.defaultAction)

    case .planReview(let plan, let acknowledged):
      if session.canReturnToPartitions {
        Button("Back", action: session.returnToPartitions).auroraSecondaryButton()
      }
      if session.canCancelPlanPreparation {
        Button("Stop checking", action: session.cancelPlanPreparation).auroraSecondaryButton()
      } else if session.planNeedsCheck {
        Button(plan.preservesStage1 ? "Check again" : "Check size") {
          Task { await session.checkDraftAllocation() }
        }
        .auroraSecondaryButton()
        .disabled(session.isEditingSize)
      }
      Button(planAction(plan)) {
        // Approve the exact plan and go straight to the password. If the
        // helper is not ready the page stays here and says so.
        session.approve()
        if session.canStartInstallation {
          session.presentInstallCredentials()
        }
      }
      .auroraPrimaryButton()
      .disabled(
        !acknowledged || session.isBusy || session.isEditingSize || session.planNeedsCheck
          || session.prefetchState != .verified
      )
      .keyboardShortcut(.defaultAction)

    case .awaitingInstall(let plan, _, _):
      if session.canReturnToPartitions {
        Button("Back", action: session.returnToPartitions).auroraSecondaryButton()
      }
      Button(planAction(plan)) {
        session.presentInstallCredentials()
      }
      .auroraPrimaryButton()
      .disabled(!session.canStartInstallation)
      .keyboardShortcut(.defaultAction)

    case .installing:
      Text(PlainLanguage.installWarning)
        .font(InstallerTheme.detail.weight(.medium))
        .foregroundStyle(InstallerTheme.secondaryText)

    case .awaitingRecovery:
      if !session.isSimulation {
        Button(PlainLanguage.recoveryShutDown) { showsShutdownConfirmation = true }
          .auroraPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }

    case .done(let completion):
      if completion.nextAction == .verifyInstalledSystem {
        Button("Restart") { session.restartInstalledSystem() }
          .auroraPrimaryButton()
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .auroraPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }

    case .failed(let failure):
      if session.canInspect {
        Button("Check again") { Task { await recheck() } }
          .auroraSecondaryButton()
      }
      if session.canStartOver {
        Button(PlainLanguage.startOver) { showsStartOverConfirmation = true }
          .auroraSecondaryButton()
      }
      if failure.retryRecoveryAvailable {
        Button(PlainLanguage.retry) { showsRecoveryRetryConfirmation = true }
          .auroraPrimaryButton()
          .disabled(!session.canRetryRecoveryAuthorization)
          .keyboardShortcut(.defaultAction)
      } else if failure.replanAvailable {
        Button(PlainLanguage.replanAction) {
          Task { await session.replanAfterEngineRefusal() }
        }
        .auroraPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)
      } else if let url = failure.actionURL, let title = failure.actionTitle {
        Button(title) {
          if !session.isSimulation { NSWorkspace.shared.open(url) }
        }
        .disabled(session.isSimulation)
        .auroraPrimaryButton()
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Pieces

  private func messagePanel(
    headline: String, detail: String, remedy: String?, technical: String?, isError: Bool,
    retryAvailable: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: Space.s) {
      VStack(alignment: .leading, spacing: Space.s) {
        Text(headline)
          .font(InstallerTheme.heading)
          .foregroundStyle(isError ? InstallerTheme.danger : InstallerTheme.text)
        Text(detail)
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let remedy {
          Text(remedy)
            .font(InstallerTheme.body)
            .foregroundStyle(InstallerTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xxs)
        }
        if let technical {
          InstallerDetailsButton(title: "Details", text: technical).padding(
            .top, Space.xs)
        }
        if session.hasExecutionStarted && !retryAvailable {
          Text(
            "You can’t restart this installation yet. Keep this Mac plugged in, and check Completed steps."
          )
          .font(InstallerTheme.body)
          InstallerDetailsButton(
            title: "Completed steps",
            text: ([headline, detail, technical ?? ""]
              + (session.journal.feed.isEmpty
                ? ["No disk step was confirmed as finished. Disk changes may have started."]
                : session.journal.feed.map(\.text)))
              .joined(separator: "\n"))
        }
        if let message = session.startOverMessage {
          Text(message)
            .font(InstallerTheme.body)
            .foregroundStyle(InstallerTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, Space.xxs)
    }
  }

  private func existingInstallRefusedPanel() -> some View {
    guard case .existingInstallRefused(let host) = session.phase else {
      return ExistingInstallationContent(partial: false)
    }
    return ExistingInstallationContent(
      partial: !host.existingInstalls.isEmpty && host.existingInstalls.allSatisfy(\.partial))
  }

  /// The review's primary button for this plan.
  private func planAction(_ plan: PlanDisplay) -> String {
    if plan.updatesBootLoader { return PlainLanguage.bootLoaderUpdateAction }
    return plan.preservesStage1 ? "Reset Linux" : PlainLanguage.planInstall
  }

  private func acknowledgement(_ acknowledged: Bool, plan: PlanDisplay) -> some View {
    let experimental =
      ExperimentalMac.thisMac && !plan.updatesBootLoader && !plan.preservesStage1
    return Toggle(
      isOn: Binding(get: { acknowledged }, set: { session.setAcknowledged($0) })
    ) {
      VStack(alignment: .leading, spacing: Space.xxs) {
        Text(
          plan.updatesBootLoader
            ? PlainLanguage.bootLoaderUpdateAcknowledgement
            : plan.preservesStage1
              ? PlainLanguage.planPreservedAcknowledgement
              : PlainLanguage.planAcknowledgement(
                resizesMacOS: plan.allocationSource != .freeExtent))
        if experimental {
          Text(PlainLanguage.planExperimentalAcknowledgement)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .toggleStyle(.checkbox)
    .controlSize(.regular)
    .font(InstallerTheme.body)
    .disabled(session.isBusy || session.isEditingSize || session.planNeedsCheck)
  }

  /// The one generic line every experimental Mac shows on the plan.
  private var experimentalNote: some View {
    VStack(alignment: .leading, spacing: Space.xxs) {
      Label(PlainLanguage.experimentalTitle, systemImage: "exclamationmark.triangle.fill")
        .font(InstallerTheme.body.weight(.semibold))
        .labelStyle(CautionLabelStyle())
      Text(PlainLanguage.experimentalNote)
        .font(InstallerTheme.detail)
        .fixedSize(horizontal: false, vertical: true)
      Link(PlainLanguage.experimentalIssuesLink, destination: PlainLanguage.experimentalIssuesURL)
        .font(InstallerTheme.detail)
        .disabled(session.isSimulation)
    }
    .accessibilityElement(children: .contain)
  }

  private var helperNote: some View {
    HStack(spacing: Space.s) {
      Image(systemName: "lock.shield")
        .foregroundStyle(InstallerTheme.caution)
        .accessibilityHidden(true)
      Text(PlainLanguage.helperNotInstalled)
        .auroraHelpText()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Space.xs)
  }

  private func recoveryPanel(_ handoff: HandoffDisplay) -> some View {
    VStack(alignment: .leading, spacing: Space.s) {
      Text(handoff.headline)
        .font(InstallerTheme.heading)
        .padding(.bottom, Space.xs)
      if let warning = handoff.warning {
        CautionCallout(text: warning)
      }
      ForEach(handoff.steps) { step in
        RecoveryStepRow(step: step)
      }
      if let message = session.shutdownMessage {
        CautionCallout(text: message)
      }
    }
  }

  @ViewBuilder
  private func donePanel(_ completion: CompletionDisplay) -> some View {
    if completion.nextAction == .verifyInstalledSystem {
      VStack(spacing: Space.m) {
        AuroraMark().frame(width: 72, height: 72)
        Text(completion.headline)
          .font(InstallerTheme.title)
        Text("Restart your Mac to start Aurora.")
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
        if let message = session.restartMessage {
          CautionCallout(text: message)
        }
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
    } else {
      VStack(alignment: .leading, spacing: Space.s) {
        Text(completion.headline).font(InstallerTheme.heading)
        Text(completion.subheadline)
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Plumbing

  private var credentialSheetBinding: Binding<Bool> {
    Binding(
      get: { !rendersExistingSession && session.credentialSheet.context != nil },
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
      VStack(alignment: .leading, spacing: Space.s) {
        VStack(alignment: .leading, spacing: Space.s) {
          HStack {
            Text(PlainLanguage.prefetchTitle(for: state))
              .font(InstallerTheme.heading)
            Spacer(minLength: 8)
            if let accessory {
              Text(accessory)
                .font(InstallerTheme.detail)
                .foregroundStyle(InstallerTheme.secondaryText)
            }
          }
          if case .failed(let reason) = state {
            Text(reason)
              .auroraHelpText()
              .textSelection(.enabled)
            if let onRetry {
              Button(PlainLanguage.prefetchRetry, action: onRetry)
            }
          } else {
            ProgressTrack(fraction: fraction)
          }
        }
      }
      .padding(.vertical, Space.s)
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
    VStack(alignment: .leading, spacing: Space.m) {
      Text(partial ? PlainLanguage.partialInstallHeadline : PlainLanguage.existingInstallHeadline)
        .font(InstallerTheme.heading)
      Text(
        partial
          ? PlainLanguage.partialInstallDetail
          : "Reset Linux in place and keep Stage 1. Or erase Linux and give its space back to macOS."
      )
      .font(InstallerTheme.body)
      .foregroundStyle(InstallerTheme.secondaryText)
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
    VStack(alignment: .leading, spacing: Space.xs) {
      Toggle(
        PlainLanguage.encryptLinuxDiskTitle,
        isOn: Binding(
          get: { isOn },
          set: { value in onChange(value) }
        )
      )
      .toggleStyle(.checkbox)
      .controlSize(.regular)
      .font(InstallerTheme.body)
      .disabled(!enabled)
      // One help paragraph: the password, and that nothing else unlocks the disk.
      Text(PlainLanguage.encryptLinuxDiskPassword + " " + PlainLanguage.encryptLinuxDiskNoRecovery)
        .auroraHelpText()
        .padding(.leading, Space.l)
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
    VStack(spacing: Space.xl) {
      VStack(spacing: Space.s) {
        Text("Preparing to install").font(InstallerTheme.title)
        Text(title).font(InstallerTheme.body).foregroundStyle(.secondary)
      }
      VStack(spacing: Space.s) {
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
        .font(InstallerTheme.detail).foregroundStyle(.secondary)
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

  @State private var exploredAuroraGB: Double?
  @State private var sizeInput = DiskSizeInput()
  @State private var showsSizePrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: Space.l) {
      Text(
        plan.updatesBootLoader
          ? PlainLanguage.bootLoaderUpdateReviewTitle
          : plan.preservesStage1 ? "Review the reset" : "Choose space for Aurora"
      )
      .font(InstallerTheme.title)
      if plan.updatesBootLoader {
        Text(PlainLanguage.bootLoaderUpdateReviewDetail)
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      } else if plan.preservesStage1 {
        Text(
          "Kept: Stage 1, the startup name and icon, and partition sizes. Replaced: the EFI boot files, Linux Boot and Root. All Linux accounts and files are erased."
        )
        .font(InstallerTheme.body)
        .foregroundStyle(InstallerTheme.secondaryText)
      } else if [.freeExtent, .otherContainerResize].contains(plan.allocationSource) {
        // Where the space comes from, when it isn't the running macOS.
        Text(plan.targetDescription)
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
        // A free extent is fixed: the breakdown, with nothing to adjust.
        if let summary = plan.fixedExtentSummary {
          Text(summary)
            .font(InstallerTheme.body)
            .foregroundStyle(InstallerTheme.secondaryText)
            .accessibilityIdentifier("plan-fixed-extent")
        }
      }
      HStack(alignment: .top) {
        capacity("macOS", bytes: plan.macOSBytes(for: displayedAuroraBytes), highlighted: false)
        Spacer()
        capacity("Aurora", bytes: displayedAuroraBytes, highlighted: true)
      }
      DiskBar(
        macOSBytes: plan.macOSBytes(for: displayedAuroraBytes),
        auroraBytes: displayedAuroraBytes,
        unallocatedBytes: plan.unallocatedBytes(for: displayedAuroraBytes),
        otherAllocatedBytes: plan.otherAllocatedBytes(for: displayedAuroraBytes),
        macOSSpaceCaution: plan.macOSSpaceCaution(for: displayedAuroraBytes),
        onAdjustAuroraFraction: editable ? { adjust($0) } : nil,
        onCommitAuroraFraction: editable ? { commit($0) } : nil,
        isFrozen: sizeInput.isEditing
      )
      .transaction { $0.animation = nil }
      // Always laid out so the controls below never move while sizes are checked.
      Text("Checking available space…")
        .font(InstallerTheme.detail).foregroundStyle(.secondary)
        .opacity(isBusy ? 1 : 0)
        .accessibilityHidden(!isBusy)
      ForEach(plan.spaceCautions(for: displayedAuroraBytes), id: \.self) { caution in
        CautionCallout(text: caution)
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
    .onChange(of: plan.auroraBytes) { _, _ in exploredAuroraGB = nil }
    .onAppear {
      #if DEBUG
        if opensSizePromptForPreview { beginSizeEdit() }
      #endif
    }
  }

  private func capacity(_ title: String, bytes: UInt64, highlighted: Bool) -> some View {
    VStack(alignment: highlighted ? .trailing : .leading, spacing: Space.xs) {
      Text(title).font(InstallerTheme.detail).foregroundStyle(.secondary)
      HStack(alignment: .center, spacing: Space.s) {
        if highlighted && editable {
          Button(action: beginSizeEdit) {
            Image(systemName: "pencil").font(.system(size: 18, weight: .medium))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityLabel("Change Aurora size")
          .help("Change Aurora size")
        }
        Text(PlainLanguage.bytes(bytes)).font(InstallerTheme.display)
          .monospacedDigit().foregroundStyle(
            highlighted ? InstallerTheme.accent : InstallerTheme.text)
      }
    }
  }

  private var displayedAuroraBytes: UInt64 {
    guard let exploredAuroraGB else { return pendingAllocationBytes ?? plan.auroraBytes }
    return UInt64(exploredAuroraGB * 1_000_000_000)
  }

  private func beginSizeEdit() {
    guard editable else { return }
    sizeInput.begin(
      bytes: displayedAuroraBytes, minimum: plan.minimumBytes, maximum: plan.maximumBytes)
    onEditingChange(true)
    showsSizePrompt = true
  }

  private func applySize() {
    guard let chosen = sizeInput.apply() else { return }
    showsSizePrompt = false
    onEditingChange(false)
    if chosen != plan.auroraBytes || pendingAllocationBytes != nil { onSizeChosen(chosen) }
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
    exploredAuroraGB = chosen / 1_000_000_000
  }

  private func commit(_ fraction: Double) {
    adjust(fraction)
    onEditingChange(false)
    let rounded = (Double(displayedAuroraBytes) / 1_000_000_000).rounded() * 1_000_000_000
    let chosen = min(plan.maximumBytes, max(plan.minimumBytes, UInt64(rounded)))
    if chosen != plan.auroraBytes || pendingAllocationBytes != nil {
      onSizeChosen(chosen)
    } else {
      exploredAuroraGB = nil
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
    VStack(alignment: .leading, spacing: Space.l) {
      Text("Space for Aurora").font(InstallerTheme.sheetTitle)
      HStack(spacing: Space.s) {
        TextField("Size", text: $input.text)
          .textFieldStyle(.roundedBorder).font(InstallerTheme.control)
          .frame(width: 110).focused($focused).autocorrectionDisabled()
          .accessibilityLabel("Aurora size in gigabytes")
          .onSubmit { if input.requestedBytes != nil { onApply() } }
        Text("GB").font(InstallerTheme.body).foregroundStyle(.secondary)
      }
      Text(
        input.validationMessage
          ?? "Between \(PlainLanguage.bytes(minimumBytes)) and \(PlainLanguage.bytes(maximumBytes))"
      )
      .font(InstallerTheme.detail)
      .foregroundStyle(
        input.validationMessage == nil ? InstallerTheme.secondaryText : InstallerTheme.danger
      )
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Space.m) {
        Spacer()
        Button("Cancel", action: onCancel).auroraSecondaryButton(size: .large).keyboardShortcut(
          .cancelAction)
        Button("Set size", action: onApply).auroraPrimaryButton(size: .large)
          .disabled(input.requestedBytes == nil).keyboardShortcut(.defaultAction)
      }
    }
    .padding(Space.xl).frame(width: 330)
    .foregroundStyle(InstallerTheme.text).background(InstallerTheme.window)
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
      VStack(alignment: .leading, spacing: Space.xl) {
        VStack(alignment: .leading, spacing: Space.s) {
          Text("Installing Aurora").font(InstallerTheme.title)
            .accessibilityAddTraits(.isHeader)
          Text(stepCount).font(InstallerTheme.body).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: Space.s + Space.xxs) {
          ForEach(Array(progress.stepLabels.enumerated()), id: \.offset) { index, label in
            HStack(spacing: Space.m) {
              stepMark(index).frame(width: 18, height: 18).accessibilityHidden(true)
              Text(label).font(
                InstallerTheme.body.weight(index == progress.stepIndex ? .medium : .regular)
              )
              .foregroundStyle(
                index <= progress.stepIndex ? InstallerTheme.text : InstallerTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(stepState(index))
          }
        }
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
          Text("\(elapsed(at: context.date)) elapsed").monospacedDigit()
            .font(InstallerTheme.detail).foregroundStyle(.secondary)
        }
        // The activity log is for when something is wrong.
        if progress.degraded {
          Text(PlainLanguage.installDegraded).auroraHelpText()
          InstallerDetailsButton(
            title: "Show activity",
            text: progress.feed.isEmpty
              ? "No activity yet." : progress.feed.map(\.text).joined(separator: "\n"))
        }
      }
      .padding(.vertical, Space.m)
    }
  }

  private var stepCount: String {
    let count = progress.stepLabels.count
    return "Step \(min(progress.stepIndex + 1, count)) of \(count)"
  }

  /// What VoiceOver says about a step, since the marks are only pictures.
  private func stepState(_ index: Int) -> String {
    if done(index) { return "Done" }
    return index == progress.stepIndex ? "In progress" : "Not started"
  }

  private func done(_ index: Int) -> Bool {
    progress.stepFractions.indices.contains(index) && progress.stepFractions[index] >= 1
  }

  /// Done, under way, or still to come.
  @ViewBuilder private func stepMark(_ index: Int) -> some View {
    if done(index) {
      Image(systemName: "checkmark.circle.fill").imageScale(.large)
        .foregroundStyle(InstallerTheme.success)
    } else if index == progress.stepIndex {
      NativeSpinner().controlSize(.small)
    } else {
      Image(systemName: "circle").imageScale(.large).foregroundStyle(.tertiary)
    }
  }

  private func elapsed(at date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(progress.startedAt)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
