import AppKit
import XCTest

@testable import AuroraRecovery

/// Drives the real window controller through the preview build's simulated
/// flow. The window and its sheets stay fully transparent and ignore the mouse.
final class InstallerViewStateTests: XCTestCase {
  private static let checkSeconds = 0.6
  private var window: InstallerWindow?
  private var sheetObserver: NSObjectProtocol?

  override class func setUp() {
    super.setUp()
    // The model reads these when it is created, like the app's own launch.
    // `swift test` cannot pass app arguments, so add them here; Swift marks
    // this setter deprecated but still honours it.
    if !CommandLine.arguments.contains("--preview") {
      CommandLine.arguments += ["--preview", "--preview-check-seconds=\(checkSeconds)"]
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
  }

  override func setUp() {
    super.setUp()
    XCTAssertTrue(RecoveryActions.isPreview, "UI state tests need the preview build")
    PreviewSimulation.checkSeconds = Self.checkSeconds
    PreviewSimulation.firstCheck = .pass
    PreviewSimulation.recheck = .pass
    PreviewSimulation.tools = nil
  }

  override func tearDown() {
    if let window {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.orderOut(nil)
    }
    window = nil
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = nil
    super.tearDown()
  }

  private func show(_ model: InstallerModel) -> (InstallerWindow, InstallerView) {
    let window = InstallerWindow()
    let controller = InstallerView(model: model)
    window.contentViewController = controller
    window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 660), display: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    // Sheets need their window on screen; keep every sheet invisible too.
    sheetObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification, object: window, queue: nil
    ) { _ in
      for other in NSApp.windows where other !== window {
        other.alphaValue = 0
        other.ignoresMouseEvents = true
      }
    }
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    self.window = window
    return (window, controller)
  }

  private func spin(_ seconds: Double = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func wait(
    _ what: String, timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
    until condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { spin() }
    XCTAssertTrue(condition(), "timed out waiting for " + what, file: file, line: line)
  }

  private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    return root.subviews.flatMap { [$0 as? T].compactMap { $0 } + views(type, in: $0) }
  }

  private func primary(_ controller: InstallerView) throws -> RecoveryBusyAction {
    try XCTUnwrap(views(RecoveryBusyAction.self, in: controller.view).first)
  }

  private func frame(_ view: NSView) -> NSRect {
    view.window?.contentView?.layoutSubtreeIfNeeded()
    return view.convert(view.bounds, to: nil)
  }

  private func button(_ title: String, in root: NSView?) -> NSButton? {
    views(NSButton.self, in: root).first { $0.title == title }
  }

  private func labels(in root: NSView?) -> [String] {
    views(NSTextField.self, in: root).map(\.stringValue)
  }

  /// Launch check passed, Continue pressed, a password typed into the prompt.
  private func promptWithPassword(
    _ model: InstallerModel, _ window: NSWindow, _ controller: InstallerView
  ) throws -> (NSWindow, NSSecureTextField) {
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified && !model.checkingEnvironment }
    try primary(controller).button.performClick(nil)
    let prompt = try XCTUnwrap(window.attachedSheet, "the password prompt opens at once")
    let field = try XCTUnwrap(views(NSSecureTextField.self, in: prompt.contentView).first)
    field.stringValue = "first owner's password"
    return (prompt, field)
  }

  func testLaunchCheckSpinsLeftOfACentredDisabledContinue() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    XCTAssertEqual(action.button.title, "Continue")
    let idle = frame(action.button)
    XCTAssertEqual(idle.midX, window.frame.width / 2, accuracy: 0.5, "Continue is centred")
    XCTAssertTrue(action.button.isEnabled)
    XCTAssertTrue(action.spinner.isHidden)

    var announced: [String] = []
    action.spinner.announce = { announced.append($0) }
    model.checkEnrollmentEnvironment()
    XCTAssertTrue(model.checkingEnvironment)
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertFalse(action.spinner.isHidden)
    XCTAssertEqual(action.wait, .verifying)
    XCTAssertEqual(announced, [RecoveryWait.verifying.announcement])
    XCTAssertEqual(action.button.accessibilityHelp(), RecoveryWait.verifying.announcement)
    XCTAssertEqual(frame(action.button), idle, "the spinner must not move Continue")
    let spinner = frame(action.spinner)
    XCTAssertLessThan(spinner.maxX, idle.minX, "the spinner turns left of Continue")
    XCTAssertEqual(spinner.midY, idle.midY, accuracy: 0.5)

    wait("the launch check") { !model.checkingEnvironment }
    XCTAssertTrue(model.environmentVerified)
    XCTAssertTrue(action.button.isEnabled)
    XCTAssertTrue(action.spinner.isHidden)
    XCTAssertNil(action.button.accessibilityHelp())
    XCTAssertEqual(frame(action.button), idle)
    XCTAssertEqual(announced.count, 1, "one announcement per wait")
  }

  func testContinueAsksAtOnceAndInstallWaitsForTheRepeatedCheck() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified }

    action.button.performClick(nil)
    // The prompt opens without waiting; the same check runs again behind it.
    let sheet = try XCTUnwrap(window.attachedSheet, "the password prompt opens at once")
    XCTAssertTrue(model.checkingEnvironment, "Continue repeats the check")
    XCTAssertEqual(action.wait, .verifying)
    let field = try XCTUnwrap(views(NSSecureTextField.self, in: sheet.contentView).first)
    let install = try XCTUnwrap(button("Install", in: sheet.contentView))
    let sheetSpinner = try XCTUnwrap(
      views(RecoveryBusyIndicator.self, in: sheet.contentView).first)
    XCTAssertTrue(sheetSpinner.isHidden, "nothing waits until Install is pressed")
    XCTAssertTrue(install.isEnabled)
    let installFrame = frame(install)

    field.stringValue = "preview password"
    install.performClick(nil)
    XCTAssertEqual(model.stage, .welcome, "installation waits for the check")
    XCTAssertFalse(sheetSpinner.isHidden)
    XCTAssertEqual(sheetSpinner.wait, .verifying)
    XCTAssertFalse(install.isEnabled)
    XCTAssertFalse(field.isEnabled)
    XCTAssertEqual(frame(install), installFrame, "the spinner must not move Install")
    XCTAssertLessThan(frame(sheetSpinner).maxX, frame(install).minX)
    XCTAssertTrue(window.attachedSheet === sheet)

    wait("installation to start") { model.stage == .installing }
    XCTAssertNil(window.attachedSheet, "the prompt closes once the check passes")
    XCTAssertTrue(model.password.isEmpty, "the preview consumes the password")
    XCTAssertTrue(field.stringValue.isEmpty)
  }

  func testAStagedStage1OpensOnUpdateAndEnrollsOnlyIt() throws {
    let model = InstallerModel()
    model.stage1Update = Stage1Reenrollment(
      mode: .macho, stage1SHA256: "", stage2Path: AuraStage1Format.confinedStage2Path)
    let (window, controller) = show(model)
    XCTAssertTrue(labels(in: controller.view).contains("Update startup software"))
    let action = try primary(controller)
    XCTAssertEqual(action.button.title, "Update")
    // Restore's flag toggles stay out of an update.
    XCTAssertNil(button("Enable Debug", in: controller.view))

    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified && !model.checkingEnvironment }
    action.button.performClick(nil)
    let prompt = try XCTUnwrap(window.attachedSheet, "Update asks for the owner's password")
    XCTAssertTrue(labels(in: prompt.contentView).contains("Authorize update"))
    let update = try XCTUnwrap(button("Update", in: prompt.contentView))
    try XCTUnwrap(views(NSSecureTextField.self, in: prompt.contentView).first).stringValue = "pw"
    wait("the repeated check") { !model.checkingEnvironment }
    update.performClick(nil)
    XCTAssertEqual(model.steps.first, "Verifying the new startup software")
    wait("the simulated update", timeout: 10) { model.stage == .complete }
    XCTAssertTrue(model.stage1Updated)
    XCTAssertFalse(model.accountOptional, "an update offers no recovery account")
    XCTAssertTrue(labels(in: controller.view).contains("Update complete"))
    XCTAssertEqual(try primary(controller).button.title, "Restart")
  }

  func testCancelWhileWaitingKeepsThePromptClosed() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified }
    try primary(controller).button.performClick(nil)
    let sheet = try XCTUnwrap(window.attachedSheet)
    try XCTUnwrap(views(NSSecureTextField.self, in: sheet.contentView).first).stringValue = "x"
    try XCTUnwrap(button("Install", in: sheet.contentView)).performClick(nil)
    try XCTUnwrap(button("Cancel", in: sheet.contentView)).performClick(nil)
    XCTAssertNil(window.attachedSheet)
    wait("the repeated check") { !model.checkingEnvironment }
    spin(0.2)
    XCTAssertEqual(model.stage, .welcome, "a cancelled prompt never installs")
    XCTAssertNil(window.attachedSheet)
  }

  func testEveryPrimaryButtonWaitsInPlace() throws {
    let model = InstallerModel()
    let (_, controller) = show(model)
    model.stage = .account
    model.accountUsername = "aurora-owner"
    model.accountPassword = "secret"
    model.accountConfirmation = "secret"
    var action = try primary(controller)
    XCTAssertEqual(action.button.title, "Create Account")
    XCTAssertTrue(action.button.isEnabled)
    var idle = frame(action.button)
    XCTAssertEqual(idle.midX, 390, accuracy: 0.5)
    model.creatingAccount = true
    XCTAssertEqual(action.wait, .creatingAccount)
    XCTAssertEqual(action.button.title, "Create Account", "the title stays while it waits")
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertEqual(frame(action.button), idle)
    model.creatingAccount = false

    model.stage = .complete
    action = try primary(controller)
    XCTAssertEqual(action.button.title, "Restart")
    idle = frame(action.button)
    XCTAssertEqual(idle.midX, 390, accuracy: 0.5)
    model.restartingCompletedSetup = true
    XCTAssertEqual(action.wait, .restarting)
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertEqual(frame(action.button), idle)
    model.restartingCompletedSetup = false
    XCTAssertTrue(action.spinner.isHidden)
  }

  func testAccountFormExplainsADisabledCreateAccount() throws {
    let model = InstallerModel()
    let (_, controller) = show(model)
    model.stage = .account
    let action = try primary(controller)
    let hint = try XCTUnwrap(
      views(NSTextField.self, in: controller.view).first {
        $0.textColor == AuroraTheme.danger
      })
    XCTAssertTrue(hint.isHidden, "an empty form is not an error")
    model.accountUsername = "Aurora Owner"
    XCTAssertFalse(hint.isHidden)
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.usernameProblem)
    XCTAssertFalse(action.button.isEnabled)
    model.accountUsername = "aurora-owner"
    model.accountPassword = "secret"
    model.accountConfirmation = "secr"
    XCTAssertTrue(hint.isHidden, "a half-typed confirmation is not reported")
    model.accountConfirmation = "secrex"
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.mismatch)
    XCTAssertFalse(action.button.isEnabled)
    model.accountConfirmation = "secret"
    XCTAssertTrue(hint.isHidden)
    XCTAssertTrue(action.button.isEnabled)
    // Passwords over 4,096 bytes or with a null character are refused too.
    model.accountConfirmation = ""
    model.accountPassword = String(repeating: "a", count: 4097)
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.passwordProblem)
    XCTAssertTrue(hint.stringValue.contains("4,096 bytes"), hint.stringValue)
    model.accountPassword = "pass\u{0}word"
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.passwordProblem)
    XCTAssertTrue(hint.stringValue.contains("null characters"), hint.stringValue)
    XCTAssertFalse(action.button.isEnabled)
  }

  func testLaunchPreparesToolsOnlyAfterAPassingCheck() {
    PreviewSimulation.tools = .pass
    let passing = InstallerModel()
    passing.startLaunchCheck()
    wait("the launch check") { !passing.checkingEnvironment }
    XCTAssertTrue(passing.preparingTools, "a passing check prepares the tools")
    wait("the tools") { !passing.preparingTools }

    PreviewSimulation.firstCheck = .fail
    let failing = InstallerModel()
    failing.startLaunchCheck()
    wait("the launch check") { !failing.checkingEnvironment }
    XCTAssertEqual(failing.environmentIssue, .cannotVerify)
    spin(Self.checkSeconds + 0.2)
    XCTAssertFalse(failing.preparingTools, "a failed check prepares nothing")
  }

  func testContinueAfterAFailureChecksAgainBeforeAsking() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified }
    model.failure = "Something went wrong."
    XCTAssertFalse(model.environmentVerified, "a failure needs a fresh check")
    let issue = try XCTUnwrap(window.attachedSheet)
    try XCTUnwrap(button("OK", in: issue.contentView)).performClick(nil)
    wait("the issue to close") { window.attachedSheet == nil }

    action.button.performClick(nil)
    XCTAssertNil(window.attachedSheet, "no prompt before the check passes")
    XCTAssertEqual(action.wait, .verifying)
    wait("the prompt") { window.attachedSheet != nil }
    let prompt = try XCTUnwrap(window.attachedSheet)
    XCTAssertFalse(views(NSSecureTextField.self, in: prompt.contentView).isEmpty)
    XCTAssertEqual(model.stage, .welcome)
  }

  func testToolsFailureShowsBeforeSetupCanStart() throws {
    PreviewSimulation.tools = .fail
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    model.startLaunchCheck()
    wait("the launch check") { !model.checkingEnvironment }
    XCTAssertEqual(action.wait, .preparing, "Continue waits for the tools")
    XCTAssertFalse(action.button.isEnabled)
    // Try to get ahead of the failure: Continue, type, then Install.
    action.button.performClick(nil)
    if let prompt = window.attachedSheet,
      let field = views(NSSecureTextField.self, in: prompt.contentView).first
    {
      field.stringValue = "password"
      wait("the tools to fail") { model.failure != nil }
      button("Install", in: prompt.contentView)?.performClick(nil)
    }
    wait("the tools to fail") { model.failure != nil }
    spin(0.3)
    XCTAssertEqual(model.stage, .welcome, "setup never starts behind an error")
    XCTAssertTrue(model.operations.isEmpty)
    let sheet = try XCTUnwrap(window.attachedSheet)
    XCTAssertTrue(labels(in: sheet.contentView).contains("Setup could not finish"))
  }

  func testRepeatedCheckFindingAnotherOwnerAsksThatOwner() throws {
    PreviewSimulation.recheck = .ownerChanged
    let model = InstallerModel()
    let (window, controller) = show(model)
    let (first, field) = try promptWithPassword(model, window, controller)
    XCTAssertTrue(
      labels(in: first.contentView).contains { $0.hasPrefix("Enter password for \(NSUserName()).") }
    )
    try XCTUnwrap(button("Install", in: first.contentView)).performClick(nil)
    wait("a prompt for the new owner") { window.attachedSheet.map { $0 !== first } ?? false }
    let second = try XCTUnwrap(window.attachedSheet)
    let owner = PreviewSimulation.changedOwner.username
    XCTAssertTrue(
      labels(in: second.contentView).contains { $0.hasPrefix("Enter password for \(owner).") })
    XCTAssertTrue(field.stringValue.isEmpty, "the first owner's password is dropped")
    let secondField = try XCTUnwrap(views(NSSecureTextField.self, in: second.contentView).first)
    XCTAssertTrue(secondField.stringValue.isEmpty)
    XCTAssertTrue(secondField.isEnabled)
    XCTAssertEqual(model.authorizationOwner, PreviewSimulation.changedOwner)
    spin(0.3)
    XCTAssertEqual(model.stage, .welcome)
    XCTAssertTrue(model.operations.isEmpty)
    XCTAssertTrue(model.password.isEmpty)
  }

  func testRepeatedCheckFailureClosesThePromptWithoutInstalling() throws {
    PreviewSimulation.recheck = .fail
    let model = InstallerModel()
    let (window, controller) = show(model)
    let (prompt, field) = try promptWithPassword(model, window, controller)
    try XCTUnwrap(button("Install", in: prompt.contentView)).performClick(nil)
    wait("the issue") { window.attachedSheet.map { $0 !== prompt } ?? false }
    XCTAssertTrue(field.stringValue.isEmpty, "the password is cleared")
    let issue = try XCTUnwrap(window.attachedSheet)
    XCTAssertTrue(labels(in: issue.contentView).contains(EnrollmentGateIssue.cannotVerify.title))
    spin(0.3)
    XCTAssertEqual(model.stage, .welcome, "nothing is installed")
    XCTAssertTrue(model.operations.isEmpty)
    XCTAssertTrue(model.password.isEmpty)
    XCTAssertFalse(model.environmentVerified)
  }

  func testWindowMenuOpensTheInstallerLogBesideSheets() throws {
    // Keep the log window invisible, as every other test window is.
    InstallerLogWindowController.willShow = { window in
      window.alphaValue = 0
      window.ignoresMouseEvents = true
    }
    defer { InstallerLogWindowController.willShow = nil }
    let model = InstallerModel()
    let (window, controller) = show(model)
    defer { controller.logWindow?.close() }
    XCTAssertTrue(
      views(NSButton.self, in: controller.view).allSatisfy {
        !$0.title.localizedCaseInsensitiveContains("log")
      }, "the log is not a button in the window")
    let windows = NSMenu(title: "Window")
    let item = RecoveryLogMenu.addItem(
      to: windows, target: controller, action: #selector(InstallerView.toggleInstallerLog(_:)))
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowItem.submenu = windows
    let mainMenu = NSMenu()
    mainMenu.addItem(windowItem)
    let commandL = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "l",
        charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
    func validated() -> (NSControl.StateValue, Bool) {
      windows.update()
      return (item.state, item.isEnabled)
    }

    // The launch check logs, so the log has lines before anything else.
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified && !model.checkingEnvironment }
    XCTAssertTrue(validated() == (.off, true))
    XCTAssertTrue(mainMenu.performKeyEquivalent(with: commandL))
    let logs = try XCTUnwrap(controller.logWindow)
    XCTAssertTrue(logs.isShowing)
    XCTAssertNil(window.attachedSheet, "the log is a window, not a sheet")
    XCTAssertEqual(logs.window?.title, "Installer Log")
    XCTAssertEqual(
      logs.filterButton.itemTitles,
      ["Show Errors Only", "Show Errors and Progress", "Show All Logs"])
    XCTAssertTrue(validated() == (.on, true))
    wait("the check's lines") { !logs.viewer.displayedText.isEmpty }
    // The log must not be wider than it shows, or each line's start is cut off.
    spin(0.3)
    XCTAssertEqual(logs.viewer.textView.frame.width, logs.viewer.contentSize.width)
    XCTAssertEqual(logs.viewer.contentView.bounds.origin.x, 0)

    logs.apply(filter: .all, search: "")
    XCTAssertTrue(logs.viewer.displayedText.contains("Started #"), "commands at Show All Logs")
    logs.apply(filter: .errorsAndProgress, search: "")
    XCTAssertFalse(logs.viewer.displayedText.contains("Started #"))
    XCTAssertTrue(logs.viewer.displayedText.contains("Recovery environment verified"))
    logs.apply(filter: .all, search: "LISTUSERS")
    let found = logs.viewer.displayedText.split(separator: "\n")
    XCTAssertFalse(found.isEmpty)
    XCTAssertTrue(found.allSatisfy { $0.contains("listUsers") }, logs.viewer.displayedText)

    // Another sheet does not hide or block the log.
    model.previewNotice = ("Restart simulated", "This preview does not restart your Mac.")
    let notice = try XCTUnwrap(window.attachedSheet)
    XCTAssertTrue(validated() == (.on, true))
    XCTAssertTrue(mainMenu.performKeyEquivalent(with: commandL))
    XCTAssertFalse(logs.isShowing)
    XCTAssertTrue(window.attachedSheet === notice, "Command-L leaves the open sheet alone")
    XCTAssertTrue(validated() == (.off, true))

    // Closing the window itself keeps the menu in step.
    controller.toggleInstallerLog(item)
    XCTAssertTrue(logs.isShowing)
    logs.window?.performClose(nil)
    XCTAssertTrue(validated() == (.off, true))
  }

  func testAFailureOffersTheInstallerLog() throws {
    InstallerLogWindowController.willShow = { window in
      window.alphaValue = 0
      window.ignoresMouseEvents = true
    }
    defer { InstallerLogWindowController.willShow = nil }
    PreviewSimulation.firstCheck = .fail
    let model = InstallerModel()
    let (window, controller) = show(model)
    defer { controller.logWindow?.close() }
    model.checkEnrollmentEnvironment()
    wait("the failure") { window.attachedSheet != nil }
    let issue = try XCTUnwrap(window.attachedSheet)
    try XCTUnwrap(button("Show Log", in: issue.contentView)).performClick(nil)
    XCTAssertNil(window.attachedSheet)
    let logs = try XCTUnwrap(controller.logWindow)
    XCTAssertTrue(logs.isShowing)
    logs.apply(filter: .errorsOnly, search: "")
    wait("the error lines") { logs.viewer.displayedText.contains("Recovery preflight failed") }
  }

  func testSaveFallsBackBesideTheAttemptFileAndFullLogKeepsEveryAttempt() throws {
    InstallerLogWindowController.willShow = { window in
      window.alphaValue = 0
      window.ignoresMouseEvents = true
    }
    let present = InstallerLogWindowController.presentSavePanel
    // Where AppKit can show the panel, it says so, and nothing falls back.
    let (window, _) = show(InstallerModel())
    let panel = NSSavePanel()
    XCTAssertTrue(present(panel, window) { _ in })
    window.endSheet(panel)
    panel.orderOut(nil)
    XCTAssertNil(window.attachedSheet)
    self.window = nil
    window.orderOut(nil)
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = nil
    // As in a Recovery stub that can't show the panel.
    InstallerLogWindowController.presentSavePanel = { _, _, _ in false }
    defer {
      InstallerLogWindowController.willShow = nil
      InstallerLogWindowController.presentSavePanel = present
    }
    let log = InstallerLog.shared
    log.beginAttempt()
    log.append("an earlier attempt’s line")
    log.beginAttempt()
    log.append("Setup failed: before the attempt was saved", level: .error)
    let model = InstallerModel()
    let (_, controller) = show(model)
    defer { controller.logWindow?.close() }
    controller.showInstallerLog()
    let logs = try XCTUnwrap(controller.logWindow)
    wait("the lines") { logs.viewer.displayedText.contains("before the attempt was saved") }
    let directory = log.attemptDirectory
    func saved(_ prefix: String) -> [URL] {
      ((try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    for url in saved("Aurora Installer ") { try? FileManager.default.removeItem(at: url) }
    defer { for url in saved("Aurora Installer ") { try? FileManager.default.removeItem(at: url) } }

    logs.apply(filter: .errorsOnly, search: "")
    logs.saveButton.performClick(nil)
    let shown = try XCTUnwrap(saved("Aurora Installer Log ").first)
    let text = try String(contentsOf: shown, encoding: .utf8)
    XCTAssertTrue(text.contains("Setup failed: before the attempt was saved"))
    XCTAssertFalse(text.contains("an earlier attempt’s line"), "Save writes the lines shown")
    wait("where it went") { log.entries.contains { $0.message.contains(shown.lastPathComponent) } }

    try XCTUnwrap(button("Save Full Log…", in: logs.window?.contentView)).performClick(nil)
    let full = try XCTUnwrap(saved("Aurora Installer Full Log ").first)
    let session = try String(contentsOf: full, encoding: .utf8)
    XCTAssertTrue(session.contains("an earlier attempt’s line"))
    XCTAssertTrue(session.contains("Setup failed: before the attempt was saved"))
    XCTAssertTrue(session.contains("=== Attempt "))

    // Search marks the source column as well as the message.
    let marked = InstallerLogWindowController.text(
      [
        InstallerLogEntry(
          sequence: 1, time: Date(), level: .debug, source: "kmutil", message: "Started #1")
      ][...], search: "KMUTIL")
    var highlighted = false
    marked.enumerateAttribute(
      .backgroundColor, in: NSRange(location: 0, length: marked.length)
    ) { value, range, _ in
      if value != nil, (marked.string as NSString).substring(with: range) == "kmutil" {
        highlighted = true
      }
    }
    XCTAssertTrue(highlighted)
  }
}
