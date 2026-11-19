import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

struct AuroraRemovalSheet: View {
  let isSimulation: Bool
  let onBusyChanged: (Bool) -> Void
  let onClose: () -> Void
  let onRequiresReview: () -> Void
  let simulationScenario: String?
  /// Set when Erase was chosen for one row of the Partitions screen: the
  /// service plans to erase that row and leave its space unallocated, and
  /// only a ticket for exactly its partitions is shown.
  let eraseTarget: DiskLayoutDisplay.EraseTarget?

  @State private var ticket: AuroraRemovalTicket?
  @State private var phrase = ""
  @State private var username = NSUserName()
  @State private var password = ""
  @State private var busy = false
  @State private var submitted = false
  @State private var completed = false
  @State private var message = "Checking for an existing Aurora installation…"
  @State private var actionError: String?
  @State private var client: AuthenticatedEngineXPCSubmitter?
  /// No helper is installed yet: the account is asked for first, to set it
  /// up, and the same password then approves the removal.
  @State private var needsAccountFirst = false
  /// The person switched the helper off; the account first turns it back on.
  @State private var reenablingHelper = false
  @State private var showsApproval = false
  @State private var reviewHeight: CGFloat = 1
  @State private var footerHeight: CGFloat = 0
  @State private var measuredHeightCap: CGFloat?
  private var fixedHeightCap: CGFloat?
  private var preloaded = false
  private var onControlFrame: ((String, CGRect) -> Void)?
  #if DEBUG
    @State private var scenario = RemovalPreviewScenario.success
  #endif

  init(
    isSimulation: Bool, onBusyChanged: @escaping (Bool) -> Void,
    onClose: @escaping () -> Void, onRequiresReview: @escaping () -> Void,
    simulationScenario: String? = nil, eraseTarget: DiskLayoutDisplay.EraseTarget? = nil
  ) {
    self.isSimulation = isSimulation
    self.simulationScenario = simulationScenario
    self.eraseTarget = eraseTarget
    #if DEBUG
      if let simulationScenario, let selected = RemovalPreviewScenario(rawValue: simulationScenario)
      {
        _scenario = State(initialValue: selected)
      }
    #endif
    self.onBusyChanged = onBusyChanged
    self.onClose = onClose
    self.onRequiresReview = onRequiresReview
    _measuredHeightCap = State(
      initialValue: NSApp?.mainWindow.flatMap(RemovalSheetLayout.heightCap(for:)))
  }

  #if DEBUG
    init(
      previewScenario: RemovalPreviewScenario, heightCap: CGFloat?,
      showsAccountFields: Bool = false, showsApproval: Bool = false,
      onControlFrame: ((String, CGRect) -> Void)? = nil
    ) {
      self.init(
        isSimulation: !showsAccountFields, onBusyChanged: { _ in }, onClose: {},
        onRequiresReview: {})
      let (ticket, message) = previewScenario.previewTicket
      _scenario = State(initialValue: previewScenario)
      _ticket = State(initialValue: ticket)
      _message = State(initialValue: message)
      fixedHeightCap = heightCap
      preloaded = true
      self.onControlFrame = onControlFrame
      _showsApproval = State(initialValue: showsApproval)

    }
  #endif

  private var canRemove: Bool {
    ticket != nil && showsApproval && !busy && !submitted && phrase == ticket?.confirmation
      && (isSimulation || (!username.isEmpty && !password.isEmpty))
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        reviewContent
          .padding(.bottom, 18)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            reviewHeight = $0
          }
      }
      .frame(
        height: RemovalSheetLayout.bodyHeight(
          content: reviewHeight, footer: footerHeight, cap: heightCap))
      footer
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          footerHeight = $0
        }
    }
    .frame(width: 600)
    .coordinateSpace(.named(RemovalSheetLayout.coordinateSpace))
    .auroraTypography()
    .foregroundStyle(InstallerTheme.text)
    .background(InstallerTheme.window)
    .background {
      if fixedHeightCap == nil {
        RemovalSheetHeightCapReader { measuredHeightCap = $0 }
      }
    }
    .interactiveDismissDisabled(busy)
    .task { if !preloaded { await prepare() } }
    .onDisappear { password = "" }
    .onChange(of: busy) { _, value in onBusyChanged(value) }
    .onChange(of: simulationScenario) { _, value in
      #if DEBUG
        if !busy, let value, let selected = RemovalPreviewScenario(rawValue: value) {
          scenario = selected
          Task { await prepare() }
        }
      #endif
    }
  }

  private var heightCap: CGFloat {
    fixedHeightCap ?? measuredHeightCap ?? RemovalSheetLayout.fallbackHeightCap()
  }

  private var reviewContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(heading).font(InstallerTheme.sheetTitle)
      Text(ticket != nil && !submitted && !showsApproval ? reviewSummary : message)
        .font(InstallerTheme.body).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("removal-message")
      if let ticket, !submitted, !showsApproval {
        VStack(spacing: 8) {
          if ticket.kind == .eraseToFreeSpace {
            summaryRow(
              "Free space afterwards", value: PlainLanguage.bytes(ticket.freedBytes ?? 0))
            summaryRow("macOS", value: "Not resized")
          } else {
            summaryRow("Space returned to macOS", value: PlainLanguage.bytes(ticket.reclaimBytes))
            summaryRow("macOS after removal", value: PlainLanguage.bytes(ticket.macOSBytesAfter))
          }
        }
        if let step = ticket.startupDisk {
          VStack(alignment: .leading, spacing: 6) {
            Text(step.title).font(InstallerTheme.heading)
            Text(step.detail).font(InstallerTheme.body).fixedSize(horizontal: false, vertical: true)
          }.accessibilityIdentifier("removal-startup-disk")
        }
        if !ticket.deletions.isEmpty {
          planSection("Erased", items: ticket.deletions)
            .reportsFrame("removal-deletions", to: onControlFrame)
        }
        planSection("Kept", items: ticket.kept)
          .reportsFrame("removal-kept", to: onControlFrame)
        ForEach(Array(ticket.notes.enumerated()), id: \.offset) { _, note in
          Text(note).font(InstallerTheme.body).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding([.horizontal, .top], 26)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 18) {
      if needsAccountFirst && ticket == nil && !isSimulation {
        accountFields
      }
      if let ticket, !submitted, showsApproval {
        Text(
          ticket.kind == .freeSpace
            ? "Your macOS files stay as they are."
            : "Everything in the erased partitions is permanently lost. Files in the macOS you’re running stay as they are."
        )
        .font(InstallerTheme.body).fixedSize(horizontal: false, vertical: true)
        if let actionError {
          Text(actionError).font(InstallerTheme.body).foregroundStyle(InstallerTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("removal-action-error")
        }
        VStack(alignment: .leading, spacing: 7) {
          Text("Type this to confirm:")
            .foregroundStyle(InstallerTheme.secondaryText)
          Text(ticket.confirmation)
            .font(InstallerTheme.heading)
            .textSelection(.enabled)
          TextField(
            "Confirmation phrase",
            text: Binding(
              get: { phrase },
              set: {
                phrase = $0
                actionError = nil
              })
          )
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .accessibilityIdentifier("removal-confirmation")
          .reportsFrame("removal-confirmation", to: onControlFrame)
        }
        .font(InstallerTheme.body)
        if !isSimulation {
          accountFields
        }
      }
      if busy {
        HStack(spacing: 10) {
          NativeSpinner().controlSize(.small)
          Text(progressText)
            .font(InstallerTheme.detail)
        }
        .foregroundStyle(InstallerTheme.secondaryText)
      }
      HStack(spacing: 12) {
        Spacer()
        Button(submitted || ticket == nil ? "Close" : "Cancel") {
          password = ""
          onClose()
        }
        .auroraSecondaryButton(size: .large)
        .keyboardShortcut(.cancelAction)
        .focusEffectDisabled()
        .disabled(busy)
        if needsAccountFirst && ticket == nil && !isSimulation {
          if reenablingHelper {
            Button(PlainLanguage.openLoginItems) {
              NSWorkspace.shared.open(PlainLanguage.loginItemsSettingsURL)
            }
            .auroraSecondaryButton(size: .large)
            .focusEffectDisabled()
          }
          Button(continueTitle) { Task { await setUpHelperThenScan() } }
            .auroraPrimaryButton(size: .large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || username.isEmpty || password.isEmpty)
        }
        if ticket != nil, !submitted, !showsApproval {
          Button("Continue") { showsApproval = true }
            .auroraPrimaryButton(size: .large).disabled(busy).keyboardShortcut(.defaultAction)
            .reportsFrame("removal-continue", to: onControlFrame)
        }
        if let ticket, !submitted, showsApproval {
          Button("Back") {
            showsApproval = false
            phrase = ""
            password = ""
          }.auroraSecondaryButton(size: .large).disabled(busy)
          Button(ticket.kind == .freeSpace ? "Return Space" : "Erase Linux", role: .destructive) {
            Task { await remove() }
          }
          .auroraDangerButton(size: .large)
          .disabled(!canRemove)
          .accessibilityIdentifier("remove-aurora")
          .reportsFrame("remove-aurora", to: onControlFrame)
        }
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 26)
    .padding(.top, 18)
    .padding(.bottom, 26)
  }

  private var continueTitle: String {
    reenablingHelper ? PlainLanguage.removalTurnOnAndContinue : PlainLanguage.removalContinue
  }

  private var progressText: String {
    if submitted { return "Keep your Mac on until removal finishes." }
    return needsAccountFirst ? "Setting up the removal service…" : "Reading the disk layout…"
  }

  private var accountFields: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("macOS administrator account").foregroundStyle(InstallerTheme.secondaryText)
      TextField(
        "Account name",
        text: Binding(
          get: { username },
          set: {
            username = $0
            actionError = nil
          })
      )
      .textFieldStyle(.roundedBorder)
      .textContentType(.username)
      .autocorrectionDisabled()
      SecureField(
        "macOS password",
        text: Binding(
          get: { password },
          set: {
            password = $0
            actionError = nil
          })
      )
      .textFieldStyle(.roundedBorder)
      .textContentType(.password)
      .privacySensitive()
    }
    .font(InstallerTheme.body)
  }

  private var reviewSummary: String {
    switch ticket?.kind {
    case .freeSpace: "Return the unused space to macOS."
    case .eraseToFreeSpace:
      "Erase “\(eraseTarget?.name ?? "these partitions")” and leave its space free to install into."
    default: "Erase the Linux installation and return its space to macOS."
    }
  }

  private var heading: String {
    if showsApproval && !submitted {
      return ticket?.kind == .freeSpace ? "Approve space return" : "Approve erasure"
    }
    if ticket?.kind == .freeSpace { return completed ? "Space returned" : "Return free space" }
    if let eraseTarget { return completed ? "Erased" : "Erase \(eraseTarget.name)" }
    return completed ? "Linux removed" : "Erase Linux"
  }

  private func planSection(_ title: String, items: [AuroraRemovalItem]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundStyle(InstallerTheme.secondaryText)
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 1) {
            Text(item.title).fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Text(PlainLanguage.bytes(item.bytes)).fontWeight(.medium)
        }
      }
    }
    .font(InstallerTheme.body)
  }

  private func summaryRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(InstallerTheme.secondaryText)
      Spacer()
      Text(value).fontWeight(.medium)
    }.font(InstallerTheme.body)
  }

  /// - Parameter keepingAccount: true right after the helper was set up with
  ///   the typed account, which then also approves the removal.
  @MainActor private func prepare(keepingAccount: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    ticket = nil
    showsApproval = false
    phrase = ""
    if !keepingAccount { password = "" }
    submitted = false
    completed = false
    message =
      eraseTarget == nil
      ? "Checking for an existing Aurora installation…" : "Checking the partitions to erase…"
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .milliseconds(350))
        if let eraseTarget {
          (ticket, message) = RemovalPreviewScenario.eraseTicket(eraseTarget)
          return
        }
        if scenario == .none || scenario == .ambiguous || scenario == .helperUnavailable {
          message = scenario.message
        } else {
          (ticket, message) = scenario.previewTicket
        }
        return
      }
    #endif
    if !keepingAccount {
      // An unreadable model counts as blocked: nothing privileged is set up
      // without knowing the Mac is one the installer allows.
      let blocked = (try? AppleSiliconHostInspector().isBlockedModel()) ?? true
      switch RemovalHelperStart(
        helper: await InstallerHelperSetup.probeDisplay(), blockedModel: blocked)
      {
      case .blockedModel:
        message = PlainLanguage.removalBlockedModel
        return
      case .busy:
        message = PlainLanguage.removalServiceBusy
        return
      case .scan:
        break
      case .credentialsFirst:
        needsAccountFirst = true
        message = PlainLanguage.removalCredentialsFirst
        return
      case .switchedOff:
        needsAccountFirst = true
        reenablingHelper = true
        message = PlainLanguage.removalSwitchedOff
        return
      case .unavailable:
        message = PlainLanguage.removalServiceMissing
        return
      }
    }
    do {
      let submitter = try InstallerHelperSetup.submitter()
      client = submitter
      let reply = try await submitter.removal(erasing: eraseTarget?.anchorUUID)
      if let eraseTarget, let found = reply.ticket, !found.erases(exactly: eraseTarget.memberUUIDs)
      {
        // The scan would erase other partitions than the row shows, or can't
        // say which: never show a ticket for something the person didn't choose.
        ticket = nil
        message = PlainLanguage.removalTargetMismatch
      } else {
        ticket = reply.ticket
        message = reply.message
      }
    } catch {
      message =
        InstallerHelperSetup.canInstall
        ? PlainLanguage.removalServiceNotResponding : PlainLanguage.removalServiceMissing
    }
    // Nothing to confirm, so nothing for the typed password to approve.
    if ticket == nil {
      password = ""
    }
  }

  /// Sets the helper up with the typed account, then scans as usual.
  @MainActor private func setUpHelperThenScan() async {
    guard needsAccountFirst, !busy else { return }
    let authorization: MachineOwnerAuthorization
    do {
      authorization = try MachineOwnerAuthorization(
        username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      return
    }
    busy = true
    message = "Setting up the removal service…"
    do {
      try await InstallerHelperSetup.ensure(
        authorization, reenablingSwitchedOff: reenablingHelper)
    } catch {
      busy = false
      password = ""
      message = PlainLanguage.removalHelperSetupMessage(for: error)
      return
    }
    busy = false
    needsAccountFirst = false
    reenablingHelper = false
    await prepare(keepingAccount: true)
  }

  @MainActor private func remove() async {
    guard canRemove, let ticket else { return }
    actionError = nil
    let authorization: MachineOwnerAuthorization?
    do {
      authorization =
        isSimulation
        ? nil : try MachineOwnerAuthorization(username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      actionError = message
      return
    }
    password = ""
    busy = true
    submitted = true
    if ticket.kind == .eraseToFreeSpace {
      message =
        ticket.startupDisk == nil
        ? "Erasing the partitions…"
        : "Setting macOS as the startup disk, then erasing the partitions…"
    } else {
      message =
        ticket.startupDisk == nil
        ? "Removing Aurora, then returning its space to macOS…"
        : "Setting macOS as the startup disk, removing Aurora, then returning its space to macOS…"
    }
    defer { busy = false }
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .seconds(2))
        if scenario == .disconnected {
          connectionLost()
          return
        }
        if ticket.kind == .eraseToFreeSpace {
          completed = true
          message =
            "“\(eraseTarget?.name ?? "The partitions")” was erased. Its space is now free to install into."
          return
        }
        completed = [.success, .olderLinux, .freeSpace, .startupDisk].contains(scenario)
        if [.interrupted, .reclaimFailed, .disconnected].contains(scenario) { onRequiresReview() }
        message = scenario.message
        return
      }
    #endif
    guard let client else {
      submitted = false
      message = PlainLanguage.removalNotStarted
      actionError = message
      return
    }
    do {
      let reply = try await client.removal(
        ticket: ticket, confirmation: phrase, authorization: authorization,
        erasing: ticket.kind == .eraseToFreeSpace ? eraseTarget?.anchorUUID : nil)
      completed = reply.completed
      if reply.requiresReview { onRequiresReview() }
      message = reply.message
    } catch EngineXPCSubmissionError.notSubmitted {
      // Never sent, so nothing started and nothing needs review.
      submitted = false
      message = PlainLanguage.removalNotStarted
      actionError = message
    } catch {
      let outcome = RemovalConnectionLoss(
        helperRetired: await RemovalOutcomeProbe.helperRetired(),
        macOSContainerBytes: RemovalOutcomeProbe.macOSContainerBytes(),
        macOSBytesAfter: ticket.macOSBytesAfter, reclaimBytes: ticket.reclaimBytes)
      switch outcome {
      case .completed:
        completed = true
        message = PlainLanguage.removalCompletedWithoutReply(freeSpace: ticket.kind == .freeSpace)
      case .unknown:
        connectionLost()
      }
    }
  }

  private func connectionLost() {
    onRequiresReview()
    message =
      "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
  }
}

enum RemovalSheetLayout {
  static let coordinateSpace = "removal-sheet"
  static let screenMargin: CGFloat = 16
  static let minimumHeightCap: CGFloat = 360

  /// A sheet hangs from just below its parent window's title bar, so it can
  /// only grow down to the bottom of the parent screen's visible frame.
  static func heightCap(
    parentFrame: CGRect, titleBarHeight: CGFloat, visibleFrame: CGRect
  ) -> CGFloat {
    let available =
      min(parentFrame.maxY - titleBarHeight, visibleFrame.maxY) - visibleFrame.minY - screenMargin
    return min(max(available, minimumHeightCap), visibleFrame.height).rounded(.down)
  }

  static func bodyHeight(content: CGFloat, footer: CGFloat, cap: CGFloat) -> CGFloat {
    max(min(content, cap - footer), 0)
  }

  @MainActor static func fallbackHeightCap() -> CGFloat {
    guard let visibleFrame = NSScreen.main?.visibleFrame else { return .greatestFiniteMagnitude }
    return max(visibleFrame.height - screenMargin, minimumHeightCap)
  }

  @MainActor static func heightCap(for parent: NSWindow) -> CGFloat? {
    guard let screen = parent.screen ?? NSScreen.main else { return nil }
    return heightCap(
      parentFrame: parent.frame,
      titleBarHeight: parent.frame.height - parent.contentLayoutRect.height,
      visibleFrame: screen.visibleFrame)
  }
}

extension View {
  fileprivate func reportsFrame(_ id: String, to report: ((String, CGRect) -> Void)?) -> some View {
    onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(RemovalSheetLayout.coordinateSpace))
    } action: {
      report?(id, $0)
    }
  }
}

private struct RemovalSheetHeightCapReader: NSViewRepresentable {
  let onChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
  }

  final class ReaderView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastCap: CGFloat?

    // Selector observers are removed automatically when the view is freed.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self)
      guard window != nil else { return }
      for name in [
        NSWindow.didMoveNotification, NSWindow.didResizeNotification,
        NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
        NSApplication.didChangeScreenParametersNotification,
      ] {
        center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
      }
      DispatchQueue.main.async { [weak self] in self?.update() }
    }

    @objc private func changed(_ note: Notification) {
      guard let changed = note.object as? NSWindow else { return update() }
      if changed === window || changed === window?.sheetParent { update() }
    }

    private func update() {
      guard let parent = window?.sheetParent ?? NSApp?.mainWindow, parent !== window,
        let cap = RemovalSheetLayout.heightCap(for: parent), cap != lastCap
      else { return }
      lastCap = cap
      onChange?(cap)
    }
  }
}

#if DEBUG
  enum RemovalPreviewScenario: String, CaseIterable {
    case success = "Complete removal"
    case olderLinux = "Older Linux installation"
    case startupDisk = "Starts up from Aurora"
    case startupFailed = "Startup disk not changed"
    case freeSpace = "Free space only"
    case none = "No installation"
    case ambiguous = "Unfamiliar or partial layout"
    case helperUnavailable = "Helper unavailable"
    case credentials = "Incorrect password"
    case changed = "Disk changed since confirmation"
    case interrupted = "Deletion interrupted"
    case reclaimFailed = "macOS resize failed"
    case disconnected = "Connection lost"

    /// Each preview is one consistent disk: members sit between macOS and
    /// Recovery, so macOS after removal is macOS plus everything removed.
    /// `success` is the M1 Pro lab Mac's converged install (2026-09-28).
    var previewTicket: (AuroraRemovalTicket, String) {
      func kept(macOS: UInt64, after: UInt64, recovery: String) -> [AuroraRemovalItem] {
        [
          AuroraRemovalItem(
            title: "macOS “Macintosh HD”",
            detail: "disk0s2 · grows to \(String(format: "%.1f GB", Double(after) / 1e9))",
            bytes: macOS),
          AuroraRemovalItem(
            title: "Apple system container", detail: "disk0s1", bytes: 524_288_000),
          AuroraRemovalItem(title: "Apple Recovery", detail: recovery, bytes: 5_368_664_064),
        ]
      }
      func ticket(
        kind: AuroraRemovalKind = .installation, macOS: UInt64, deletions: [AuroraRemovalItem],
        free: UInt64 = 0, recovery: String, notes: [String] = [],
        startupDisk: AuroraRemovalItem? = nil
      ) -> AuroraRemovalTicket {
        let reclaim = deletions.reduce(free) { $0 + $1.bytes }
        return AuroraRemovalTicket(
          id: UUID(), kind: kind, reclaimBytes: reclaim, macOSBytesAfter: macOS + reclaim,
          deletions: deletions,
          kept: kept(macOS: macOS, after: macOS + reclaim, recovery: recovery),
          notes: notes, startupDisk: startupDisk)
      }
      switch self {
      case .freeSpace:
        return (
          ticket(
            kind: .freeSpace, macOS: 461_600_000_000, deletions: [], free: 32_800_505_856,
            recovery: "disk0s6",
            notes: [
              "macOS takes all the unallocated space directly after it, whatever put it there."
            ]),
          "No installation was found, but 32.8 GB directly after macOS is unallocated. macOS can take it back. Nothing will be deleted."
        )
      case .olderLinux:
        return (
          ticket(
            macOS: 461_600_000_000,
            deletions: [
              AuroraRemovalItem(
                title: "Startup container “Arch Linux ARM”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              AuroraRemovalItem(
                title: "EFI partition “EFI - ARCH”", detail: "disk0s4", bytes: 524_288_000),
              AuroraRemovalItem(
                title: "Linux partition", detail: "disk0s5", bytes: 29_776_412_672),
            ], recovery: "disk0s6"),
          "Found “Arch Linux ARM”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      default:
        let startsUpFromAurora = [.startupDisk, .startupFailed].contains(self)
        return (
          ticket(
            macOS: 678_662_672_384,
            deletions: [
              AuroraRemovalItem(
                title: "Startup container “Aurora”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              AuroraRemovalItem(
                title: "EFI partition “EFI - OMARC”", detail: "disk0s4", bytes: 524_288_000),
              AuroraRemovalItem(title: "Linux partition", detail: "disk0s5", bytes: 2_147_483_648),
              AuroraRemovalItem(
                title: "Linux partition", detail: "disk0s6", bytes: 310_828_335_104),
            ], recovery: "disk0s7",
            startupDisk: startsUpFromAurora
              ? AuroraRemovalItem(
                title: "Set macOS “Macintosh HD” as the startup disk",
                detail: "Your Mac starts up from “Aurora” now", bytes: 0) : nil),
          startsUpFromAurora
            ? "Found “Aurora”. Removal first sets macOS as the startup disk, then permanently deletes “Aurora” and everything stored in it and returns its space to macOS."
            : "Found “Aurora”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      }
    }

    var message: String {
      switch self {
      case .success:
        "“Aurora” and its data have been removed. The freed space is now part of macOS."
      case .olderLinux:
        "“Arch Linux ARM” and its data have been removed. The freed space is now part of macOS."
      case .freeSpace: "The free space is now part of macOS."
      case .startupDisk:
        "“Aurora” and its data have been removed. The freed space is now part of macOS."
      case .startupFailed:
        "macOS didn’t set “Macintosh HD” as the startup disk. It reported: “Failed to authenticate owner”. Nothing was deleted."
      case .none:
        "No Aurora installation, or other installation made with the same installer engine, was found, and there’s no unallocated space after macOS. Nothing was changed."
      case .ambiguous:
        "Found disk0s4 (EFI partition, “EFI - ARCH”, 524.3 MB); disk0s5 (Linux partition, 29.8 GB) without the startup container every installation made with the installer engine has. This looks like a partly removed installation, which needs a manual review. Nothing was changed."
      case .helperUnavailable:
        PlainLanguage.removalServiceNotResponding
      case .credentials:
        "The macOS account or password was not accepted. No disk changes were made."
      case .changed:
        "The disk layout changed since you reviewed it. No disk changes were made. Close this window and review removal again."
      case .interrupted:
        "Removal stopped, and some Aurora data may already be deleted. Don’t start removal again; the removal record was kept for recovery."
      case .reclaimFailed:
        "Aurora was removed, but the installer couldn’t confirm its space went back to macOS. The space may still be unallocated. Don’t start removal again; the removal record was kept for recovery."
      case .disconnected:
        "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
      }
    }
  }

  extension RemovalPreviewScenario {
    /// The simulation's erase review: exactly the row's partitions, left as
    /// free space, as the removal service would plan it.
    static func eraseTicket(_ target: DiskLayoutDisplay.EraseTarget) -> (
      AuroraRemovalTicket, String
    ) {
      let ticket = AuroraRemovalTicket(
        id: UUID(), kind: .eraseToFreeSpace, reclaimBytes: 0, macOSBytesAfter: 0,
        deletions: [
          AuroraRemovalItem(
            title: target.name,
            detail: target.memberUUIDs.count == 1
              ? "1 partition" : "\(target.memberUUIDs.count) partitions", bytes: target.bytes)
        ],
        notes: [
          "Its \(PlainLanguage.bytes(target.bytes)) is left as unallocated space. macOS isn’t resized."
        ], erasedPartitionUUIDs: target.memberUUIDs, freedBytes: target.freedBytes)
      return (
        ticket,
        "Erase permanently deletes “\(target.name)” and everything stored in it. Its space becomes \(PlainLanguage.bytes(target.freedBytes)) of unallocated free space that you can install into. macOS isn’t resized."
      )
    }
  }
#endif
