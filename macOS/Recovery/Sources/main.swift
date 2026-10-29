import AppKit
import CoreServices

// Explicit macOS previews simulate the flow; enrollment requires paired 1TR.
// Credentials stay in memory and never enter command arguments or logs.
enum Stage: Int, CaseIterable {
  case welcome, installing, account, complete
}

final class InstallerModel {
  var onChange: (() -> Void)?
  private func changed() { onChange?() }
  let recoveryInterface =
    CommandLine.arguments.contains("--recovery-preview")
    || (!RecoveryActions.isPreview && RecoveryActions.recovering)
  var stage: Stage = .welcome { didSet { changed() } }
  var password = "" { didSet { changed() } }
  var authorizationOwner: RecoveryOwner? { didSet { changed() } }
  var authorizationUsesSourceOwner = false { didSet { changed() } }
  var progress = 0.0 { didSet { changed() } }
  var currentOperation = "Preparing installation" { didSet { changed() } }
  var operations: [String] = [] { didSet { changed() } }
  var failure: String? { didSet { changed() } }
  var environmentIssue: EnrollmentGateIssue? { didSet { changed() } }
  var checkingEnvironment = false { didSet { changed() } }
  var debugEnabled = false { didSet { changed() } }
  var proxyEnabled = false { didSet { changed() } }
  var accountUsername = "" { didSet { changed() } }
  var accountPassword = "" { didSet { changed() } }
  var accountConfirmation = "" { didSet { changed() } }
  var accountAlreadyStarted = false { didSet { changed() } }
  var creatingAccount = false { didSet { changed() } }
  var restartingWithoutAccount = false { didSet { changed() } }
  var restartingCompletedSetup = false { didSet { changed() } }
  var accountNeedsAuthorization = false { didSet { changed() } }
  /// A separate recovery account can be created but nothing of it exists
  /// yet. It stays out of the way: Restart defers it, and holding Shift on
  /// Restart or Utilities → Create Recovery Account… opens its setup.
  var accountOptional = false { didSet { changed() } }
  var previewNotice: (title: String, message: String)? { didSet { changed() } }
  private var checkingAccount = false
  private var awaitingStartupDiskReturn = false

  var canCreateAccount: Bool {
    !creatingAccount && !restartingWithoutAccount
      && RecoveryAccountInstaller.validName(accountUsername)
      && !accountPassword.isEmpty && accountPassword == accountConfirmation
      && (try? RecoveryAccountInstaller.validatePassword(Data(accountPassword.utf8))) != nil
  }

  private func showAccountStep(_ record: RecoveryAccountRecord?, required: Bool = true) {
    accountUsername = record?.username ?? ""
    accountAlreadyStarted = record != nil
    accountPassword = ""
    accountConfirmation = ""
    // Not started yet: finish without it unless the person asks for it. An
    // account that was started resumes directly.
    accountOptional = required && record == nil
    accountNeedsAuthorization = required && record != nil && record?.phase != "finalized"
    stage = accountNeedsAuthorization ? .account : .complete
  }

  /// Opens the optional recovery account setup from the completion screen.
  func showRecoveryAccountSetup() {
    guard accountOptional, stage == .complete, !restartingWithoutAccount,
      !restartingCompletedSetup
    else { return }
    stage = .account
  }

  func resumeAccountSetup() {
    guard RecoveryActions.inRecovery, RecoveryActions.recovering,
      !creatingAccount, !restartingWithoutAccount, !checkingAccount
    else { return }
    checkingAccount = true
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let required = try RecoveryActions.accountCreationRequired()
        let record = required ? try RecoveryActions.recoveryAccount() : nil
        DispatchQueue.main.async {
          self.checkingAccount = false
          if required { self.showAccountStep(record) }
        }
      } catch {
        DispatchQueue.main.async {
          self.checkingAccount = false
          self.failure = error.localizedDescription
        }
      }
    }
  }

  func returnedFromStartupDisk() {
    guard awaitingStartupDiskReturn else { return }
    awaitingStartupDiskReturn = false
    resumeAccountSetup()
  }

  func createRecoveryAccount() {
    guard canCreateAccount else { return }
    let name = accountUsername
    let secret = Data(accountPassword.utf8)
    accountPassword = ""
    accountConfirmation = ""
    creatingAccount = true
    if RecoveryActions.isPreview {
      creatingAccount = false
      accountAlreadyStarted = true
      accountOptional = false
      accountNeedsAuthorization = true
      stage = .complete
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let record = try RecoveryActions.createRecoveryAccount(username: name, password: secret)
        InstallerLog.shared.append(
          record.phase == "finalized"
            ? "Recovery account ownership and metadata verified."
            : "Recovery account prepared. Startup Disk authorization is still required.")
        DispatchQueue.main.async {
          self.creatingAccount = false
          self.accountAlreadyStarted = true
          self.accountOptional = false
          self.accountNeedsAuthorization = record.phase != "finalized"
          self.stage = .complete
        }
      } catch {
        InstallerLog.shared.append("Recovery account setup failed: " + error.localizedDescription)
        DispatchQueue.main.async {
          self.creatingAccount = false
          self.failure = error.localizedDescription
        }
      }
    }
  }

  func skipRecoveryAccountAndRestart() {
    guard stage == .account || (stage == .complete && accountOptional), !creatingAccount,
      !restartingWithoutAccount, !checkingAccount
    else {
      return
    }
    accountPassword = ""
    accountConfirmation = ""
    if RecoveryActions.isPreview {
      previewNotice = (
        "Restart simulated",
        "Recovery account setup is deferred. This preview does not restart your Mac."
      )
      return
    }
    restartingWithoutAccount = true
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try RecoveryActions.skipRecoveryAccountAndRestart()
      } catch {
        InstallerLog.shared.append("Restart failed: " + error.localizedDescription)
        DispatchQueue.main.async {
          self.restartingWithoutAccount = false
          self.failure = error.localizedDescription
        }
      }
    }
  }

  func toggleBootFlag(_ name: String) {
    let enabled = !(name == "debug" ? debugEnabled : proxyEnabled)
    if !RecoveryActions.isPreview {
      do { try RecoveryActions.cli([name, enabled ? "on" : "off"]) } catch {
        failure = error.localizedDescription
        return
      }
    }
    if name == "debug" { debugEnabled = enabled } else { proxyEnabled = enabled }
  }

  func refreshBootFlags() {
    guard RecoveryActions.inRecovery else { return }
    do {
      let arguments = try RecoveryActions.readBootArguments().split(whereSeparator: {
        $0.isWhitespace
      })
      debugEnabled = arguments.contains("aura-debug")
      proxyEnabled = arguments.contains("aura-proxy")
    } catch { failure = error.localizedDescription }
  }
  func checkEnrollmentEnvironment(ready: @escaping () -> Void = {}) {
    if RecoveryActions.isPreview {
      ready()
      return
    }
    guard !checkingEnvironment else { return }
    checkingEnvironment = true
    InstallerLog.shared.beginAttempt()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try RecoveryActions.requireEnrollmentEnvironment()
        InstallerLog.shared.append(
          "Recovery environment verified. Resolving the installation owner.")
        let owner = try RecoveryActions.resolveOwner()
        let sourceOwner =
          (try RecoveryActions.configuration.get()).bootstrap?.ownerUUIDs.contains(
            owner.uuid.uuidString) == true
        DispatchQueue.main.async {
          self.checkingEnvironment = false
          self.authorizationOwner = owner
          self.authorizationUsesSourceOwner = sourceOwner
          ready()
        }
      } catch {
        InstallerLog.shared.append("Recovery preflight failed: " + error.localizedDescription)
        DispatchQueue.main.async {
          self.checkingEnvironment = false
          self.password.removeAll(keepingCapacity: false)
          if let issue = error as? EnrollmentGateIssue {
            self.environmentIssue = issue
          } else {
            self.failure = error.localizedDescription
          }
        }
      }
    }
  }

  func repairRecoveryBoot(password: String? = nil, needsPassword: @escaping () -> Void) {
    guard !checkingEnvironment else { return }
    checkingEnvironment = true
    let previousOwner = authorizationOwner
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let complete = try RecoveryActions.repairRecoveryBoot(
          password: password, owner: previousOwner)
        let owner = complete ? nil : try RecoveryActions.resolveOwner()
        DispatchQueue.main.async {
          self.checkingEnvironment = false
          if !complete {
            self.authorizationOwner = owner
            needsPassword()
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.checkingEnvironment = false
          self.failure = error.localizedDescription
        }
      }
    }
  }

  private var installationTask: Task<Void, Never>?
  var bootSelection: BootSelection { BootSelection() }

  var steps: [String] {
    recoveryInterface
      ? [
        "Verifying the recovery files", "Checking the startup partition",
        "Restoring the startup software", "Verifying the restored files",
      ]
      : [
        "Verifying the installation files", "Checking the selected startup volume",
        "Authorizing the boot environment", "Installing the startup software",
        "Selecting the startup volume", "Finishing installation",
      ]
  }

  func restore() {
    if RecoveryActions.isPreview {
      startDemo()
      return
    }
    guard RecoveryActions.inRecovery else {
      environmentIssue = .notRecovery
      return
    }
    InstallerLog.shared.beginAttempt()
    stage = .installing
    currentOperation = "Restoring the startup software"
    progress = 0.2
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try RecoveryActions.cli(["recover"])
        let required = try RecoveryActions.accountCreationRequired()
        let account = required ? try RecoveryActions.recoveryAccount() : nil
        DispatchQueue.main.async {
          self.progress = 1
          self.operations = ["Startup software restored and verified"]
          self.showAccountStep(account, required: required)
        }
      } catch {
        DispatchQueue.main.async {
          self.failure = error.localizedDescription
          self.stage = .welcome
        }
      }
    }
  }

  func startDemo() {
    guard RecoveryActions.isPreview || RecoveryActions.inRecovery else {
      password.removeAll(keepingCapacity: false)
      environmentIssue = .notRecovery
      return
    }
    if RecoveryActions.inRecovery {
      guard let owner = authorizationOwner else {
        password.removeAll(keepingCapacity: false)
        failure = RecoveryOwnerError.noOwner.localizedDescription
        return
      }
      let credential = password
      password.removeAll(keepingCapacity: false)
      let selection = bootSelection
      stage = .installing
      operations = []
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try RecoveryActions.install(selection: selection, owner: owner, password: credential) {
            amount, operation in
            DispatchQueue.main.async {
              self.progress = amount
              self.currentOperation = operation
              self.operations.append(operation)
            }
          }
          let account = try RecoveryActions.recoveryAccount()
          DispatchQueue.main.async { self.showAccountStep(account) }
        } catch {
          InstallerLog.shared.append("Setup failed: " + error.localizedDescription)
          DispatchQueue.main.async {
            if let issue = error as? EnrollmentGateIssue {
              self.environmentIssue = issue
            } else {
              self.failure = error.localizedDescription
            }
            self.stage = .welcome
          }
        }
      }
      return
    }
    password.removeAll(keepingCapacity: false)
    operations = [
      "Selected Aura \(bootSelection.mode == .raw ? "raw" : "Mach-O") boot mode — simulated"
    ]
    stage = .installing
    installationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for (index, step) in self.steps.enumerated() {
        if Task.isCancelled { return }
        self.currentOperation = step
        for tick in 0..<12 {
          try? await Task.sleep(nanoseconds: 80_000_000)
          if Task.isCancelled { return }
          self.progress = (Double(index) + Double(tick + 1) / 12) / Double(self.steps.count)
        }
        self.operations.append("\(step) — simulated")
      }
      if !self.recoveryInterface { self.accountOptional = true }
      self.stage = .complete
    }
  }

  func finishSetup() {
    // Restart without the optional account defers it, as "Skip, Restart Now" does.
    if accountOptional {
      skipRecoveryAccountAndRestart()
      return
    }
    if !accountNeedsAuthorization {
      if RecoveryActions.isPreview {
        previewNotice = ("Restart simulated", "This preview does not restart your Mac.")
        return
      }
      guard !restartingCompletedSetup else { return }
      restartingCompletedSetup = true
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          // Another default volume is not an error: let the person choose
          // this installation in Startup Disk, which restarts from there.
          guard try RecoveryActions.targetIsDefaultBoot() else {
            InstallerLog.shared.append(
              "This installation is not the startup disk. Opening Startup Disk.")
            DispatchQueue.main.async {
              self.restartingCompletedSetup = false
              self.openStartupDisk()
            }
            return
          }
          try RecoveryActions.restartCompletedSetup()
        } catch {
          InstallerLog.shared.append("Restart failed: " + error.localizedDescription)
          DispatchQueue.main.async {
            self.restartingCompletedSetup = false
            self.failure = error.localizedDescription
          }
        }
      }
      return
    }
    if RecoveryActions.isPreview {
      previewNotice = (
        "Choose your startup disk",
        "In Recovery, this opens Startup Disk. Select \(DestinationVolume.name), click Restart, and authorize your recovery account when asked."
      )
      return
    }
    openStartupDisk()
  }

  private func openStartupDisk() {
    guard RecoveryActions.inRecovery else {
      environmentIssue = .notRecovery
      return
    }
    do {
      let application = try RecoveryActions.prepareStartupDiskHandoff()
      awaitingStartupDiskReturn = true
      NSWorkspace.shared.openApplication(at: application, configuration: .init()) { _, error in
        if let error {
          DispatchQueue.main.async {
            self.awaitingStartupDiskReturn = false
            self.failure = error.localizedDescription
          }
        }
      }
    } catch { failure = error.localizedDescription }
  }

  func reset() {
    installationTask?.cancel()
    password.removeAll(keepingCapacity: false)
    accountPassword.removeAll(keepingCapacity: false)
    accountConfirmation.removeAll(keepingCapacity: false)
    progress = 0
    operations = []
    stage = .welcome
  }
}

enum RecoveryBrand {
  static let logo: NSImage = {
    guard let url = Bundle.main.url(forResource: "AuroraLogo", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    else { preconditionFailure("The Aurora branding asset is missing.") }
    image.isTemplate = false
    return image
  }()
}

enum DestinationVolume {
  static let url = RecoveryActions.volume
  private static let previewDistribution: String? = {
    guard RecoveryActions.isPreview,
      let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--preview-distro=") })
    else { return nil }
    let name = String(argument.dropFirst("--preview-distro=".count))
    return ["fedora", "arch", "nixos"].contains(name) ? name : nil
  }()
  static let name =
    previewDistribution.flatMap {
      ["fedora": "Fedora Aurora Remix", "arch": "Aurora ALARM", "nixos": "Aurora NixOS"][$0]
    } ?? RecoveryActions.volumeName
  static let icon: NSImage = {
    if let distribution = previewDistribution,
      let url = Bundle.main.url(forResource: distribution, withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      return image
    }
    // Read the actual custom volume icon without synchronously asking
    // LaunchServices/IconServices while Recovery is launching this app.
    if let image = NSImage(contentsOf: url.appendingPathComponent(".VolumeIcon.icns")) {
      return image
    }
    return NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Startup volume")
      ?? NSImage(size: NSSize(width: 96, height: 96))
  }()
}

// AppKit owns the window and sheets, including their titlebar and background.
final class InstallerWindow: NSWindow {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
    // Views are built in code, so let AppKit derive Tab order from layout.
    autorecalculatesKeyViewLoop = true
    isMovableByWindowBackground = true
    // Full-size content occupies the titlebar too. Preserve the original outer
    // dimensions instead of adding AppKit's titlebar height to the layout.
    setFrame(NSRect(x: 0, y: 0, width: 780, height: 660), display: false)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var controller: InstallerView?
  private lazy var model = InstallerModel()

  func applicationDidBecomeActive(_ notification: Notification) {
    model.returnedFromStartupDisk()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchTrace.mark("delegate.didFinishLaunching")
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let window = InstallerWindow()
    window.title = "Aurora Installer"
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    NSApp.applicationIconImage = RecoveryBrand.logo
    LaunchTrace.mark("window.creatingContent")
    let controller = InstallerView(model: model)
    window.contentViewController = controller
    self.controller = controller
    window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 660), display: false)
    LaunchTrace.mark("window.contentCreated")
    window.center()
    window.makeKeyAndOrderFront(nil)
    LaunchTrace.mark("window.orderedFront")
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    installMenus()
    LaunchTrace.mark("menus.installed")
    if renderPreviewIfRequested(window) { return }
    if model.recoveryInterface && RecoveryActions.inRecovery {
      // Restoring an already enrolled stage 2 does not change boot policy.
      model.refreshBootFlags()
      model.resumeAccountSetup()
      do { try RecoveryActions.installCommand() } catch {
        model.failure = error.localizedDescription
      }
    } else {
      model.checkEnrollmentEnvironment {
        self.model.refreshBootFlags()
        do { try RecoveryActions.installCommand() } catch {
          self.model.failure = error.localizedDescription
        }
      }
    }
  }

  private func installMenus() {
    let menu = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let result = NSMenu(title: title)
      item.submenu = result
      menu.addItem(item)
      return result
    }
    let application = submenu("Aurora Installer")
    application.addItem(
      withTitle: "About Aurora Installer",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    application.addItem(.separator())
    application.addItem(
      withTitle: "Hide Aurora Installer", action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    let hideOthers = application.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    application.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    application.addItem(.separator())
    application.addItem(
      withTitle: "Quit Aurora Installer", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")

    let edit = submenu("Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let utilities = submenu("Utilities")
    let terminal = utilities.addItem(
      withTitle: "Terminal", action: #selector(openTerminal(_:)), keyEquivalent: "t")
    terminal.keyEquivalentModifierMask = [.command, .option]
    terminal.target = self
    let account = utilities.addItem(
      withTitle: "Create Recovery Account…", action: #selector(createRecoveryAccount(_:)),
      keyEquivalent: "")
    account.target = self

    let windows = submenu("Window")
    windows.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: "")
    NSApp.windowsMenu = windows
    let help = submenu("Help")
    let previewHelp = help.addItem(
      withTitle: "About Aurora Recovery", action: #selector(showPreviewHelp(_:)), keyEquivalent: ""
    )
    previewHelp.target = self
    NSApp.helpMenu = help
    NSApp.mainMenu = menu
  }

  /// This rendering path exists only in the non-mutating preview build.
  private func renderPreviewIfRequested(_ window: NSWindow) -> Bool {
    guard RecoveryActions.isPreview,
      let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") })
    else { return false }
    precondition(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    let screen =
      CommandLine.arguments.first(where: { $0.hasPrefix("--preview-stage=") })
      .map { String($0.dropFirst("--preview-stage=".count)) } ?? "welcome"
    switch screen {
    case "installing":
      model.stage = .installing
      model.progress = 0.58
      model.currentOperation = "Preparing startup software"
      model.operations = ["Checking the selected volume", "Preparing startup software"]
    case "account": model.stage = .account
    case "complete": model.stage = .complete
    case "error": model.stage = .welcome
    default: model.stage = .welcome
    }
    let output = URL(fileURLWithPath: String(argument.dropFirst("--snapshot=".count)))
    // AppKit alert loops may suspend main-queue callbacks. A run-loop timer
    // also observes the native alert surface without interacting with it.
    let capture = Timer(timeInterval: 1, repeats: false) { _ in
      let surface =
        screen == "error" ? (window.attachedSheet ?? NSApp.modalWindow ?? window) : window
      surface.contentView?.layoutSubtreeIfNeeded()
      if let view = surface.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
          guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
          }
          try bytes.write(to: output)
        } catch {
          FileHandle.standardError.write(Data("Recovery preview capture failed: \(error)\n".utf8))
        }
      }
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      if let modal = NSApp.modalWindow {
        NSApp.abortModal()
        modal.orderOut(nil)
      }
      NSApp.terminate(nil)
    }
    RunLoop.main.add(capture, forMode: .common)
    RunLoop.main.add(capture, forMode: .modalPanel)
    if screen == "error" {
      DispatchQueue.main.async { self.model.environmentIssue = .wrongPair }
    }
    return true
  }

  @objc private func createRecoveryAccount(_ sender: Any?) { model.showRecoveryAccountSetup() }

  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.action == #selector(createRecoveryAccount(_:)) else { return true }
    return model.accountOptional && model.stage == .complete
  }

  @objc private func openTerminal(_ sender: Any?) {
    let paths = [
      "/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app",
      "/Applications/Terminal.app",
    ]
    guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
      let alert = NSAlert()
      alert.messageText = "Terminal is unavailable"
      alert.informativeText =
        "The Terminal application could not be found in this macOS environment."
      alert.runModal()
      return
    }
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) {
      _, error in
      if let error {
        DispatchQueue.main.async {
          let alert = NSAlert(error: error)
          alert.runModal()
        }
      }
    }
  }

  @objc private func showPreviewHelp(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Aurora Installer"
    alert.informativeText =
      RecoveryActions.inRecovery
      ? "Install or restore Aurora startup software. The aura command is available in Recovery Terminal after opening this app."
      : "This preview demonstrates the Recovery installation flow. Enter any text in the preview password field. No startup software, boot policy, or disk content is changed. Restart previews the Startup Disk handoff. Utilities → Terminal opens the real Terminal app."
    alert.runModal()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.dropFirst().first == "--build-mode" {
  #if AURORA_STEP2_RECOVERY
    print("recovery")
  #elseif AURORA_STEP2_PREVIEW
    print("preview")
  #else
    print("disabled")
  #endif
  exit(0)
}

if CommandLine.arguments.dropFirst().first == "--aura-command" {
  do {
    try RecoveryActions.cli(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
  } catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
  }
}

LaunchTrace.mark("entry.beforeNSApplication")
let app = NSApplication.shared
LaunchTrace.mark("entry.NSApplicationCreated")
LaunchTrace.mark("entry.beforeDelegate")
let delegate = AppDelegate()
LaunchTrace.mark("entry.delegateCreated")
app.delegate = delegate
LaunchTrace.mark("entry.beforeActivationPolicy")
app.setActivationPolicy(.regular)
LaunchTrace.mark("entry.activationPolicySet")
LaunchTrace.mark("entry.beforeRun")
app.run()
