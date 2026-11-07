import AppKit

/// The complete Recovery interface uses only AppKit. The model owns installation
/// work; this controller renders its state and keeps credentials in native fields.
final class InstallerView: NSViewController, NSTextFieldDelegate, NSMenuItemValidation {
  private let model: InstallerModel
  private let log = InstallerLog.shared
  private let titleLabel = NSTextField(labelWithString: "")
  private var titleWidthConstraint: NSLayoutConstraint?
  private let content = NSView()
  private let footer = NSView()
  private var renderedStage: Stage?
  /// Continue or Restore, Create Account, or Restart, with its spinner slot.
  private var primaryAction: RecoveryBusyAction?
  private var shiftHeld = false
  private var modifierMonitor: Any?
  private var debugButton: NSButton?
  private var proxyButton: NSButton?
  private var progressIndicator: NSProgressIndicator?
  private var operationLabel: NSTextField?
  private var accountUsernameField: NSTextField?
  private var accountPasswordField: NSSecureTextField?
  private var accountConfirmationField: NSSecureTextField?
  private var accountHint: NSTextField?
  private var skipButton: NSButton?
  private var issueShowing = false
  private var issueRepair = false
  private var authorizationRepair = false
  private let sheets = SheetPresenter()
  private var authorizationField: NSSecureTextField?
  private var authorizationProceed: NSButton?
  private var authorizationSpinner: RecoveryBusyIndicator?
  /// Install was pressed while this Mac was still being checked again; the
  /// password waits in its field and installation starts once the check passes.
  private var authorizationSubmitPending = false
  /// Window → Installer Log; made the first time it is opened.
  private(set) var logWindow: InstallerLogWindowController?

  init(model: InstallerModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
    model.onChange = { [weak self] in self?.refresh() }
    log.onChange = { [weak self] in self?.refresh() }
    sheets.onDismiss = { [weak self] in
      self?.authorizationField = nil
      self?.authorizationProceed = nil
      self?.authorizationSpinner = nil
      self?.authorizationSubmitPending = false
      self?.refresh()
    }
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  deinit {
    model.onChange = nil
    log.onChange = nil
    if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
  }

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 660))
    root.wantsLayer = true
    root.layer?.backgroundColor = AuroraTheme.darkCGColor(AuroraTheme.window)
    root.appearance = NSAppearance(named: .darkAqua)
    view = root

    let wordmark = AuroraWordmark(frame: .zero)
    wordmark.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(wordmark)

    titleLabel.font = AuroraTheme.title
    titleLabel.textColor = AuroraTheme.text
    titleLabel.alignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(titleLabel)

    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)

    footer.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(footer)

    let titleWidth = titleLabel.widthAnchor.constraint(equalToConstant: 600)
    titleWidthConstraint = titleWidth
    NSLayoutConstraint.activate([
      wordmark.topAnchor.constraint(equalTo: root.topAnchor, constant: 62),
      wordmark.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      wordmark.widthAnchor.constraint(equalToConstant: 400),
      wordmark.heightAnchor.constraint(equalToConstant: 84),
      titleLabel.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 24),
      titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      titleWidth,
      content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
      content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      content.widthAnchor.constraint(equalToConstant: 510),
      content.heightAnchor.constraint(equalToConstant: 292),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      footer.heightAnchor.constraint(equalToConstant: 80),
    ])
    modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      let held = event.modifierFlags.contains(.shift)
      if let self, self.shiftHeld != held {
        self.shiftHeld = held
        self.refresh()
      }
      return event
    }
    refresh()
  }

  private func refresh() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.refresh() }
      return
    }
    guard isViewLoaded else { return }
    if renderedStage != model.stage {
      renderedStage = model.stage
      buildStage()
    }
    titleLabel.stringValue = stageTitle
    titleLabel.alignment = model.stage == .account ? .left : .center
    titleWidthConstraint?.constant = model.stage == .account ? 380 : 600
    if let action = RecoveryPrimaryAction.resolve(primaryInputs) { primaryAction?.apply(action) }
    progressIndicator?.doubleValue = model.progress * 100
    operationLabel?.stringValue = model.currentOperation + "…"
    debugButton?.title = model.debugEnabled ? "Disable Debug" : "Enable Debug"
    proxyButton?.title = model.proxyEnabled ? "Disable Proxy" : "Enable Proxy"
    // The toggles start from the firmware's current flags, read after launch.
    debugButton?.isEnabled = !model.preparingTools
    proxyButton?.isEnabled = !model.preparingTools
    skipButton?.title = model.restartingWithoutAccount ? "Restarting…" : "Skip, Restart Now"
    skipButton?.isEnabled = !model.creatingAccount && !model.restartingWithoutAccount
    if let field = accountUsernameField {
      field.isEnabled =
        !model.accountAlreadyStarted && !model.creatingAccount && !model.restartingWithoutAccount
      if field.currentEditor() == nil && field.stringValue != model.accountUsername {
        field.stringValue = model.accountUsername
      }
    }
    let problem = model.accountFormProblem
    accountHint?.stringValue = problem ?? ""
    accountHint?.isHidden = problem == nil
    accountPasswordField?.isEnabled = !model.creatingAccount && !model.restartingWithoutAccount
    accountConfirmationField?.isEnabled = !model.creatingAccount && !model.restartingWithoutAccount
    // The model drops typed passwords on Skip and failures; keep the native fields in step.
    for (field, value) in [
      (accountPasswordField, model.accountPassword),
      (accountConfirmationField, model.accountConfirmation),
    ] where value.isEmpty && field?.stringValue.isEmpty == false {
      field?.stringValue = ""
    }
    let holdingPassword = authorizationSubmitPending && model.checkingEnvironment
    authorizationSpinner?.show(holdingPassword ? .verifying : nil)
    authorizationProceed?.isEnabled = !holdingPassword
    authorizationField?.isEnabled = !holdingPassword
    if logWindow?.isShowing == true { logWindow?.reload() }
    if (model.environmentIssue != nil || model.failure != nil) && !issueShowing
      && sheets.active == nil
    {
      presentIssue()
    } else if let notice = model.previewNotice, sheets.active == nil {
      let done = RecoveryPrimaryButton(
        title: "Done", target: self, action: #selector(donePanelPressed))
      done.keyEquivalent = "\r"
      present(
        RecoverySheet(
          title: notice.title, message: notice.message,
          width: 430, height: 210, body: NSView(), bodyHeight: 0, buttons: [done]))
    }
  }

  private var stageTitle: String {
    switch model.stage {
    case .welcome where updating: return "Update startup software"
    case .welcome: return model.recoveryInterface ? "Repair startup" : "Finish setup"
    case .installing where updating: return "Updating startup software"
    case .installing:
      return model.recoveryInterface ? "Restoring startup software" : "Setting up Aurora Linux"
    case .account:
      return model.accountAlreadyStarted ? "Resume recovery setup" : "Create a recovery account"
    case .complete:
      if model.accountNeedsAuthorization { return "Authorize recovery account" }
      if updating { return "Update complete" }
      return model.recoveryInterface ? "Recovery complete" : "Installation complete"
    }
  }

  /// A staged Stage 1 replaces Restore: setup's checks, then only enrollment.
  private var updating: Bool { model.stage1Update != nil }

  private var primaryInputs: RecoveryPrimaryAction.Inputs {
    RecoveryPrimaryAction.Inputs(
      stage: model.stage, recoveryInterface: model.recoveryInterface && !updating,
      updatingStage1: updating,
      checkingEnvironment: model.checkingEnvironment, preparingTools: model.preparingTools,
      creatingAccount: model.creatingAccount,
      restartingWithoutAccount: model.restartingWithoutAccount,
      restartingCompletedSetup: model.restartingCompletedSetup,
      accountAlreadyStarted: model.accountAlreadyStarted,
      accountFormValid: model.canCreateAccount, offersAccount: offersAccount)
  }

  private func buildStage() {
    for child in content.subviews { child.removeFromSuperview() }
    for child in footer.subviews { child.removeFromSuperview() }
    primaryAction = nil
    debugButton = nil
    proxyButton = nil
    progressIndicator = nil
    operationLabel = nil
    accountUsernameField = nil
    accountPasswordField = nil
    accountConfirmationField = nil
    accountHint = nil
    skipButton = nil

    switch model.stage {
    case .welcome: buildWelcome()
    case .installing: buildInstalling()
    case .account: buildAccount()
    case .complete: buildComplete()
    }
    buildFooter()
  }

  private func buildWelcome() {
    let stack = vertical(spacing: 9)
    let (heading, detail) =
      updating
      ? (
        "Update the startup software for your Mac.",
        "This installs the startup software the Aurora installer\nprepared. Linux and its files stay as they are."
      )
      : model.recoveryInterface
        ? (
          "Restore the startup software for your Mac.",
          "Use the saved recovery files to repair your\nstartup software."
        )
        : (
          "Finish setting up Aurora Linux on your Mac.",
          "The final step installs the startup software for your\nselected Aurora volume."
        )
    stack.addArrangedSubview(label(heading, size: 15))
    stack.addArrangedSubview(label(detail, size: 13))
    let icon = volumeIcon()
    stack.setCustomSpacing(44, after: stack.arrangedSubviews[1])
    stack.addArrangedSubview(icon)
    stack.setCustomSpacing(24, after: icon)
    // Every Aurora startup volume carries the Aurora mark the window already
    // shows, so its icon and name are left out; a blank line keeps the layout.
    stack.addArrangedSubview(label(" ", size: 14))
    place(stack)
  }

  private func buildInstalling() {
    let stack = vertical(spacing: 15)
    stack.addArrangedSubview(
      label(
        (updating ? "Updating " : model.recoveryInterface ? "Restoring " : "Setting up ")
          + DestinationVolume.name,
        size: 14))
    let progress = NSProgressIndicator()
    progress.isIndeterminate = false
    progress.minValue = 0
    progress.maxValue = 100
    progress.controlSize = .regular
    progress.style = .bar
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.widthAnchor.constraint(equalToConstant: 380).isActive = true
    stack.addArrangedSubview(progress)
    progressIndicator = progress
    let operation = label("", size: 12)
    stack.addArrangedSubview(operation)
    operationLabel = operation
    place(stack)
  }

  private func buildAccount() {
    let stack = vertical(spacing: 11)
    stack.alignment = .leading
    let message =
      model.accountAlreadyStarted
      ? "Verify your recovery account’s password to resume authorization.\n\nYour Linux login is separate."
      : "Create a separate recovery account for your Linux volume. Next, authorize it as a volume owner to manage Linux boot settings independently of your macOS account.\n\nYour Linux login is separate."
    let explanation = label(message, size: 12, alignment: .left)
    explanation.maximumNumberOfLines = 0
    explanation.preferredMaxLayoutWidth = 380
    explanation.widthAnchor.constraint(equalToConstant: 380).isActive = true
    stack.addArrangedSubview(explanation)

    let username = NSTextField()
    username.stringValue = model.accountUsername
    username.placeholderString = "aurora-owner"
    username.delegate = self
    username.identifier = NSUserInterfaceItemIdentifier("accountUsername")
    stack.addArrangedSubview(fieldRow("Username", field: username))
    accountUsernameField = username

    let password = NSSecureTextField()
    password.placeholderString = "Password"
    password.delegate = self
    password.identifier = NSUserInterfaceItemIdentifier("accountPassword")
    stack.addArrangedSubview(fieldRow("Password", field: password))
    accountPasswordField = password

    let confirmation = NSSecureTextField()
    confirmation.placeholderString = "Retype password"
    confirmation.delegate = self
    confirmation.identifier = NSUserInterfaceItemIdentifier("accountConfirmation")
    stack.addArrangedSubview(fieldRow("Retype password", field: confirmation))
    accountConfirmationField = confirmation

    // Explains a disabled Create Account. It is last in a top-anchored
    // stack, so showing it moves nothing above it.
    let hint = label("", size: 12, alignment: .left)
    hint.textColor = AuroraTheme.danger
    hint.preferredMaxLayoutWidth = 380
    hint.widthAnchor.constraint(equalToConstant: 380).isActive = true
    hint.isHidden = true
    stack.addArrangedSubview(hint)
    accountHint = hint
    place(stack, top: 0)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.view.window?.makeFirstResponder(
        self.model.accountAlreadyStarted ? self.accountPasswordField : self.accountUsernameField)
    }
  }

  private func buildComplete() {
    let stack = vertical(spacing: 13)
    let subject = "Aurora Linux"
    stack.addArrangedSubview(
      label(
        model.accountNeedsAuthorization
          ? subject + " is ready for authorization."
          : subject + " is ready to start.", size: 15))
    stack.setCustomSpacing(39, after: stack.arrangedSubviews[0])
    let icon = volumeIcon()
    stack.addArrangedSubview(icon)
    stack.setCustomSpacing(28, after: icon)
    if model.accountNeedsAuthorization {
      stack.addArrangedSubview(
        label(
          "Select “" + DestinationVolume.name + "”, click “Restart…”, then “Authorize Users…”.",
          size: 12))
      stack.addArrangedSubview(
        label(
          "Enter the credentials for your macOS account and the recovery account you just created.",
          size: 12))
    } else {
      stack.addArrangedSubview(label("Restart to start using Aurora Linux.", size: 12))
    }
    place(stack)
  }

  /// The space the volume's icon used, left blank: the window already shows
  /// the Aurora mark every Aurora startup volume carries.
  private func volumeIcon() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 96).isActive = true
    view.heightAnchor.constraint(equalToConstant: 96).isActive = true
    return view
  }

  private func buildFooter() {
    let center = NSStackView()
    center.orientation = model.stage == .account ? .vertical : .horizontal
    center.spacing = model.stage == .account ? 6 : 12
    center.alignment = model.stage == .account ? .centerX : .centerY
    center.translatesAutoresizingMaskIntoConstraints = false

    // Each step's primary button keeps a spinner slot to its left. A lone
    // button mirrors the slot on its right, so it stays centred in the window.
    switch model.stage {
    case .welcome:
      let restoring = model.recoveryInterface && !updating
      let start = RecoveryPrimaryButton(
        title: updating ? "Update" : restoring ? "Restore" : "Continue",
        target: self, action: #selector(startPressed))
      let action = RecoveryBusyAction(button: start, balanced: !restoring)
      center.addArrangedSubview(action)
      primaryAction = action
      if restoring {
        let debug = RecoverySecondaryButton(
          title: "Enable Debug", target: self, action: #selector(debugPressed))
        let proxy = RecoverySecondaryButton(
          title: "Enable Proxy", target: self, action: #selector(proxyPressed))
        center.addArrangedSubview(debug)
        center.addArrangedSubview(proxy)
        debugButton = debug
        proxyButton = proxy
        // Balance the spinner slot after the whole row, so it stays centred.
        center.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: RecoveryBusyAction.slot)
      }
    case .installing: break
    case .account:
      let account = RecoveryPrimaryButton(
        title: "Create Account", target: self, action: #selector(accountPressed))
      let action = RecoveryBusyAction(button: account)
      center.addArrangedSubview(action)
      primaryAction = action
      let skip = RecoveryTextButton(
        title: "Skip, Restart Now", target: self, action: #selector(skipPressed))
      center.addArrangedSubview(skip)
      skipButton = skip
    case .complete:
      let restart = RecoveryPrimaryButton(
        title: "Restart", target: self, action: #selector(restartPressed))
      let action = RecoveryBusyAction(button: restart)
      center.addArrangedSubview(action)
      primaryAction = action
    }
    footer.addSubview(center)
    NSLayoutConstraint.activate([
      center.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
      center.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])
  }

  private func fieldRow(_ title: String, field: NSTextField) -> NSStackView {
    let row = vertical(spacing: 4)
    row.alignment = .leading
    row.addArrangedSubview(label(title, size: 12, alignment: .left))
    field.font = AuroraTheme.body
    field.textColor = AuroraTheme.text
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.focusRingType = .exterior
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 380).isActive = true
    field.heightAnchor.constraint(equalToConstant: 28).isActive = true
    row.addArrangedSubview(field)
    return row
  }

  private func vertical(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  private func label(
    _ text: String, size: CGFloat, alignment: NSTextAlignment = .center
  ) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = AuroraTheme.font(size)
    field.textColor = AuroraTheme.secondaryText
    field.alignment = alignment
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    return field
  }

  private func place(_ stack: NSStackView, top: CGFloat = 8) {
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: top),
      stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
    ])
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    switch field.identifier?.rawValue {
    case "accountUsername": model.accountUsername = field.stringValue
    case "accountPassword": model.accountPassword = field.stringValue
    case "accountConfirmation": model.accountConfirmation = field.stringValue
    default: break
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    // Tab and Shift-Tab step through the account fields in order.
    let fields = [accountUsernameField, accountPasswordField, accountConfirmationField]
      .compactMap { $0 }.filter(\.isEnabled)
    if selector == #selector(NSResponder.insertTab(_:))
      || selector == #selector(NSResponder.insertBacktab(_:)),
      let index = fields.firstIndex(where: { $0 === control })
    {
      let step = selector == #selector(NSResponder.insertTab(_:)) ? 1 : fields.count - 1
      view.window?.makeFirstResponder(fields[(index + step) % fields.count])
      return true
    }
    // Return moves to the next account field and creates the account from the last.
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    if control === accountUsernameField {
      view.window?.makeFirstResponder(accountPasswordField)
    } else if control === accountPasswordField {
      view.window?.makeFirstResponder(accountConfirmationField)
    } else if control === accountConfirmationField {
      if model.canCreateAccount { accountPressed() }
    } else {
      return false
    }
    return true
  }

  @objc private func startPressed() {
    LaunchTrace.mark("ui.continue.pressed")
    if model.recoveryInterface && !updating {
      model.restore()
      return
    }
    guard model.environmentVerified else {
      model.checkEnrollmentEnvironment { [weak self] passed in
        guard passed else { return }
        LaunchTrace.mark("ui.continue.ready")
        self?.showAuthorization(repair: false)
      }
      return
    }
    // The launch check already verified this Mac and found its owner, so ask
    // for the password now and repeat the same check while it is typed.
    // Install waits for that check, and installation checks again before any
    // write.
    let owner = model.authorizationOwner
    let sourceOwner = model.authorizationUsesSourceOwner
    showAuthorization(repair: false)
    LaunchTrace.mark("ui.continue.ready")
    model.checkEnrollmentEnvironment { [weak self] passed in
      if passed {
        self?.authorizationRecheckPassed(owner: owner, sourceOwner: sourceOwner)
      } else {
        self?.authorizationRecheckFailed()
      }
    }
  }

  private var authorizationOpen: Bool { authorizationField != nil && !authorizationRepair }

  private func authorizationRecheckPassed(owner: RecoveryOwner?, sourceOwner: Bool) {
    guard authorizationOpen else { return }
    guard model.authorizationOwner == owner, model.authorizationUsesSourceOwner == sourceOwner
    else {
      // The prompt named someone else: ask again for the owner just found.
      LaunchTrace.mark("ui.authorization.ownerChanged")
      authorizationField?.stringValue = ""
      closePanel()
      showAuthorization(repair: false)
      return
    }
    if authorizationSubmitPending { submitAuthorization() }
  }

  private func authorizationRecheckFailed() {
    guard authorizationOpen else { return }
    // Closing the prompt lets the failure that stopped it be shown.
    authorizationField?.stringValue = ""
    closePanel()
  }

  @objc private func debugPressed() { model.toggleBootFlag("debug") }
  @objc private func proxyPressed() { model.toggleBootFlag("proxy") }
  @objc private func accountPressed() {
    model.createRecoveryAccount()
    accountPasswordField?.stringValue = ""
    accountConfirmationField?.stringValue = ""
  }
  @objc private func skipPressed() {
    model.skipRecoveryAccountAndRestart()
    accountPasswordField?.stringValue = ""
    accountConfirmationField?.stringValue = ""
  }
  @objc private func restartPressed() {
    if offersAccount {
      model.showRecoveryAccountSetup()
    } else {
      model.finishSetup()
    }
  }

  /// Holding Shift on the completion screen offers the optional recovery account.
  private var offersAccount: Bool {
    shiftHeld && model.accountOptional && model.stage == .complete
  }

  @discardableResult private func present(_ panel: RecoverySheet, focus: NSView? = nil) -> Bool {
    guard sheets.present(panel, on: view.window) else { return false }
    if let focus { panel.makeFirstResponder(focus) }
    return true
  }

  private func closePanel() { sheets.close() }

  private func showAuthorization(repair: Bool) {
    guard view.window != nil else {
      LaunchTrace.mark("ui.authorization.noWindow")
      return
    }
    LaunchTrace.mark("ui.authorization.open")
    authorizationRepair = repair
    let owner =
      model.authorizationOwner?.username
      ?? (RecoveryActions.inRecovery ? "the volume owner" : NSUserName())
    var explanation = "Enter password for " + owner + "."
    if !repair && updating {
      explanation +=
        " Use the owner’s password to install the new startup software. The security of your macOS installations is unaffected."
    } else if !repair {
      explanation +=
        model.authorizationUsesSourceOwner
        ? " Use your existing macOS owner’s password to set up Aurora. Your macOS security settings are unaffected."
        : " Use your Aurora installation’s credentials to adjust its security settings. The security of your macOS installations is unaffected."
    }
    let field = NSSecureTextField()
    field.placeholderString = "Password"
    field.font = AuroraTheme.body
    field.textColor = AuroraTheme.text
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.focusRingType = .exterior
    field.translatesAutoresizingMaskIntoConstraints = false
    // As wide as the message above it: the sheet's 28 pt margins, no more.
    field.widthAnchor.constraint(equalToConstant: 430 - 56).isActive = true
    field.heightAnchor.constraint(equalToConstant: 28).isActive = true
    authorizationField = field
    let cancel = RecoverySecondaryButton(
      title: "Cancel", target: self, action: #selector(cancelPanelPressed))
    cancel.keyEquivalent = "\u{1b}"
    let proceed = RecoveryPrimaryButton(
      title: repair ? "Shut Down" : updating ? "Update" : "Install", target: self,
      action: #selector(authorizePanelPressed))
    proceed.keyEquivalent = "\r"
    authorizationProceed = proceed
    // Turns left of the buttons while Install waits for this Mac's check.
    let spinner = RecoveryBusyIndicator()
    authorizationSpinner = spinner
    let panel = RecoverySheet(
      title: repair
        ? "Authorize startup disk" : updating ? "Authorize update" : "Authorize installation",
      message: explanation, width: 430, height: 230, body: field, bodyHeight: 28,
      buttons: [cancel, proceed], accessory: spinner)
    present(panel, focus: field)
  }

  @objc private func authorizePanelPressed() {
    let credential = authorizationField?.stringValue ?? ""
    // An empty password keeps the sheet open. Refocus the field instead of
    // beeping: NSSound.beep() needs the Swift AppKit overlay, which older
    // Recovery lacks.
    guard !credential.isEmpty else {
      authorizationField?.window?.makeFirstResponder(authorizationField)
      return
    }
    if !authorizationRepair && model.checkingEnvironment {
      // This Mac is still being checked again: keep the password in its
      // field and install as soon as the check passes. End editing first so
      // disabling the field keeps what was typed.
      authorizationField?.window?.makeFirstResponder(nil)
      authorizationSubmitPending = true
      refresh()
      return
    }
    submitAuthorization()
  }

  private func submitAuthorization() {
    let credential = authorizationField?.stringValue ?? ""
    authorizationSubmitPending = false
    guard !credential.isEmpty else { return }
    authorizationField?.stringValue = ""
    closePanel()
    if authorizationRepair {
      model.repairRecoveryBoot(password: credential) { [weak self] in
        self?.showAuthorization(repair: true)
      }
    } else {
      model.password = credential
      model.startDemo()
    }
  }

  @objc private func cancelPanelPressed() {
    authorizationField?.stringValue = ""
    authorizationSubmitPending = false
    model.password.removeAll(keepingCapacity: false)
    closePanel()
  }

  /// Window → Installer Log: opens the log beside the installer, or closes it.
  @objc func toggleInstallerLog(_ sender: Any?) {
    if logWindow?.isShowing == true {
      logWindow?.close()
    } else {
      showInstallerLog()
    }
  }

  func showInstallerLog() {
    let controller = logWindow ?? InstallerLogWindowController(log: log)
    logWindow = controller
    controller.show()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(toggleInstallerLog(_:)) else { return true }
    return RecoveryLogMenu.validate(item, showing: logWindow?.isShowing == true)
  }

  @objc private func donePanelPressed() {
    model.previewNotice = nil
    closePanel()
  }

  private func presentIssue() {
    let issue = model.environmentIssue
    issueRepair = issue?.canRepairStartupSelection == true
    let primary = RecoveryPrimaryButton(
      title: issueRepair ? "Set Startup Disk and Shut Down" : "Show Log",
      target: self, action: #selector(issuePrimaryPressed))
    let cancel = RecoverySecondaryButton(
      title: issueRepair ? "Cancel" : "OK", target: self,
      action: #selector(issueCancelPressed))
    cancel.keyEquivalent = "\u{1b}"
    let panel = RecoverySheet(
      title: issue?.title ?? "Setup could not finish",
      message: issue?.message ?? model.failure ?? "",
      width: 490, height: 270, body: NSView(), bodyHeight: 0,
      buttons: [cancel, primary])
    // A sheet that could not be shown must not block every later failure.
    issueShowing = present(panel)
  }

  @objc private func issuePrimaryPressed() {
    let repair = issueRepair
    issueShowing = false
    model.environmentIssue = nil
    model.failure = nil
    closePanel()
    if repair {
      model.repairRecoveryBoot { [weak self] in self?.showAuthorization(repair: true) }
    } else {
      showInstallerLog()
    }
  }

  @objc private func issueCancelPressed() {
    issueShowing = false
    model.environmentIssue = nil
    model.failure = nil
    closePanel()
  }

}
