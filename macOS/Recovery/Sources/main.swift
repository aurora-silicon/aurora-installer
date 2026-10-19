import AppKit
import CoreServices
import SwiftUI

// Explicit macOS previews simulate the flow; enrollment requires paired 1TR.
// Credentials stay in memory and never enter command arguments or logs.
enum Stage: Int, CaseIterable {
  case welcome, installing, account, complete
}

final class InstallerModel: ObservableObject {
  let recoveryInterface =
    CommandLine.arguments.contains("--recovery-preview")
    || (!RecoveryActions.isPreview && RecoveryActions.recovering)
  @Published var stage: Stage = .welcome
  @Published var password = ""
  @Published var authorizationOwner: RecoveryOwner?
  @Published var authorizationUsesSourceOwner = false
  @Published var progress = 0.0
  @Published var currentOperation = "Preparing installation"
  @Published var machoBootMode = false {
    didSet {
      if !machoBootMode { nestedVirtualization = false }
    }
  }
  @Published var nestedVirtualization = false
  @Published var operations: [String] = []
  @Published var failure: String?
  @Published var environmentIssue: EnrollmentGateIssue?
  @Published var checkingEnvironment = false
  @Published var debugEnabled = false
  @Published var proxyEnabled = false
  @Published var accountUsername = ""
  @Published var accountPassword = ""
  @Published var accountConfirmation = ""
  @Published var accountAlreadyStarted = false
  @Published var creatingAccount = false
  @Published var restartingWithoutAccount = false
  @Published var accountNeedsAuthorization = false
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
    accountNeedsAuthorization = required && record?.phase != "finalized"
    accountPassword = ""
    accountConfirmation = ""
    stage =
      !required
        || record?.phase == "finalized"
      ? .complete : .account
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
    guard stage == .account, !creatingAccount, !restartingWithoutAccount, !checkingAccount else {
      return
    }
    accountPassword = ""
    accountConfirmation = ""
    if RecoveryActions.isPreview {
      let alert = NSAlert()
      alert.messageText = "Restart simulated"
      alert.informativeText =
        "Recovery account setup is deferred. This preview does not restart your Mac."
      alert.runModal()
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
  var bootSelection: BootSelection {
    BootSelection(machoEnabled: machoBootMode, nestedVirtualization: nestedVirtualization)
  }

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
      self.stage = self.recoveryInterface ? .complete : .account
    }
  }

  func openStartupDisk() {
    if RecoveryActions.isPreview {
      let alert = NSAlert()
      alert.messageText = "Choose your startup disk"
      alert.informativeText =
        "In Recovery, this opens Startup Disk. Select \(DestinationVolume.name), click Restart, and authorize your recovery account when asked."
      alert.runModal()
      return
    }
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

enum InstallerSheet: String, Identifiable {
  case authorization, advanced, details
  var id: String { rawValue }
}

struct NestedVirtualizationInfo: View {
  @State private var isPresented = false
  private let explanation =
    "Enables KVM support and recursive nested virtualization. Normal OS operations may incur up to a 20% performance hit."

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Image(systemName: "info.circle")
        .font(RecoveryAppearance.font(13))
        .foregroundColor(RecoveryAppearance.secondaryText)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      if hovering { isPresented = true }
    }
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      Text(explanation)
        .font(RecoveryAppearance.font(12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 280)
    }
    .accessibilityLabel("About nested virtualization")
    .accessibilityHint(explanation)
  }
}

struct InstallerView: View {
  @ObservedObject var model: InstallerModel
  @ObservedObject private var log = InstallerLog.shared
  @FocusState private var passwordFocused: Bool
  @FocusState private var accountField: AccountField?
  private enum AccountField: Hashable { case username, password, confirmation }
  @State private var activeSheet: InstallerSheet?
  @State private var authorizingRecoveryRepair = false
  @State private var copyingLog = false

  private var title: String {
    switch model.stage {
    case .welcome: return model.recoveryInterface ? "Repair startup" : "Finish setup"
    case .installing:
      return model.recoveryInterface ? "Restoring startup software" : "Setting up Aurora"
    case .account:
      return model.accountAlreadyStarted ? "Resume recovery setup" : "Create a recovery account"
    case .complete:
      if model.accountNeedsAuthorization { return "Authorize recovery account" }
      return model.recoveryInterface ? "Recovery complete" : "Installation complete"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Image("AuroraLogo", bundle: .main)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: 80, height: 80)
        .padding(.top, 32)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
      Text("Aurora Installer")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
      Text(title)
        .font(RecoveryAppearance.title)
        .foregroundColor(RecoveryAppearance.text)
        .frame(width: model.stage == .account ? 380 : nil, alignment: .leading)
        .padding(.bottom, 24)
        .accessibilityAddTraits(.isHeader)

      Group {
        switch model.stage {
        case .welcome: welcome
        case .installing: installing
        case .account: account
        case .complete: complete
        }
      }
      .frame(maxWidth: 510)
      .frame(height: model.stage == .account ? 288 : 244, alignment: .top)
      Spacer(minLength: 12)

      ZStack {
        navigation
        HStack {
          Spacer()
          if model.stage == .welcome && !model.recoveryInterface {
            Button {
              activeSheet = .advanced
            } label: {
              Image(systemName: "slider.horizontal.3")
                .font(RecoveryAppearance.font(17))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(RecoveryAppearance.secondaryText)
            .help("Advanced Options")
            .accessibilityLabel("Advanced Options")
          }
          if model.stage != .welcome || !log.text.isEmpty {
            Button("Show details") { activeSheet = .details }
              .buttonStyle(.plain)
              .font(RecoveryAppearance.font(12))
              .foregroundColor(RecoveryAppearance.secondaryText)
          }
        }
      }
      .padding(.horizontal, 32)
      .frame(height: 72)
      .padding(.bottom, 10)
    }
    .frame(width: 780, height: 660)
    .background(RecoveryAppearance.window)
    .foregroundColor(RecoveryAppearance.text)
    .tint(RecoveryAppearance.accent)
    .preferredColorScheme(.dark)
    .ignoresSafeArea()
    .alert(
      model.environmentIssue?.title ?? "Setup could not finish",
      isPresented: Binding(
        get: { model.environmentIssue != nil || model.failure != nil },
        set: {
          if !$0 {
            model.environmentIssue = nil
            model.failure = nil
          }
        })
    ) {
      if model.environmentIssue?.canRepairStartupSelection == true {
        Button("Set Startup Disk and Shut Down") {
          model.environmentIssue = nil
          model.repairRecoveryBoot {
            authorizingRecoveryRepair = true
            activeSheet = .authorization
          }
        }
        Button("Cancel", role: .cancel) { model.environmentIssue = nil }
      } else {
        Button("Show details") {
          model.environmentIssue = nil
          model.failure = nil
          activeSheet = .details
        }
        Button("OK") {
          model.environmentIssue = nil
          model.failure = nil
        }
      }
    } message: {
      Text(model.environmentIssue?.message(for: DestinationVolume.name) ?? model.failure ?? "")
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .authorization: authorization
      case .advanced: advancedOptions
      case .details: details
      }
    }
  }

  private var welcome: some View {
    VStack(spacing: 8) {
      Text(
        model.recoveryInterface
          ? "Restore the startup software for your Mac." : "Finish setting up Aurora on your Mac."
      )
      .font(RecoveryAppearance.font(15)).foregroundColor(RecoveryAppearance.secondaryText)
      Text(
        model.recoveryInterface
          ? "Use the saved recovery files to repair your\nstartup software."
          : "The final step installs the startup software for your\nselected Aurora volume."
      )
      .font(RecoveryAppearance.font(13)).foregroundColor(RecoveryAppearance.secondaryText)
      .multilineTextAlignment(.center).lineSpacing(4)
      .padding(.top, 4)
      VStack(spacing: 13) {
        Image(nsImage: DestinationVolume.icon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 96, height: 96)
          .accessibilityHidden(true)
        Text(DestinationVolume.name)
          .font(RecoveryAppearance.font(14, .medium))
          .lineLimit(1)
      }
      .padding(.top, 32)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Selected startup volume: \(DestinationVolume.name)")
    }
  }

  private var authorization: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text(authorizingRecoveryRepair ? "Authorize startup disk" : "Authorize installation")
          .font(RecoveryAppearance.font(17, .semibold))
        Text(
          "Enter password for \(RecoveryActions.inRecovery ? (model.authorizationOwner?.username ?? "the volume owner") : NSUserName())"
        )
        .font(RecoveryAppearance.font(12)).foregroundColor(RecoveryAppearance.secondaryText)
        if !authorizingRecoveryRepair {
          Text(
            model.authorizationUsesSourceOwner
              ? "Use your existing macOS owner’s password to set up Aurora. Your macOS security settings are unaffected."
              : "Use your Aurora installation’s credentials to adjust its security settings. The security of your macOS installations is unaffected."
          )
          .font(RecoveryAppearance.font(12)).foregroundColor(RecoveryAppearance.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
          if RecoveryActions.allowsCustomBootArguments {
            Text("Aurora will also allow custom Aura boot arguments, including USB proxy mode.")
              .font(RecoveryAppearance.font(12)).foregroundColor(RecoveryAppearance.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      SecureField("Password", text: $model.password)
        .textFieldStyle(.roundedBorder)
        .focused($passwordFocused)
        .onSubmit { authorize() }
        .accessibilityLabel("Password")
      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          model.password.removeAll(keepingCapacity: false)
          activeSheet = nil
        }
        .keyboardShortcut(.cancelAction)
        Button(authorizingRecoveryRepair ? "Shut Down" : "Install") { authorize() }
          .keyboardShortcut(.defaultAction)
          .disabled(model.password.isEmpty)
      }
    }
    .padding(28)
    .frame(width: 410)
    .onAppear { passwordFocused = true }
    .onDisappear { model.password.removeAll(keepingCapacity: false) }
  }

  private func authorize() {
    guard !model.password.isEmpty else { return }
    if authorizingRecoveryRepair {
      let credential = model.password
      model.password.removeAll(keepingCapacity: false)
      activeSheet = nil
      model.repairRecoveryBoot(password: credential) {
        activeSheet = .authorization
      }
    } else {
      model.startDemo()
      activeSheet = nil
    }
  }

  private var advancedOptions: some View {
    VStack(alignment: .leading, spacing: 26) {
      Text("Advanced Options")
        .font(RecoveryAppearance.font(19, .semibold))
      Toggle("Enable Mach-O Boot Mode", isOn: $model.machoBootMode)
        .toggleStyle(.checkbox)
        .disabled(!RecoveryActions.supportsMachO)
      HStack(spacing: 8) {
        Toggle("Enable Nested Virtualization", isOn: $model.nestedVirtualization)
          .toggleStyle(.checkbox)
          .fixedSize()
          .disabled(!RecoveryActions.supportsMachO || !model.machoBootMode)
        NestedVirtualizationInfo()
        Spacer(minLength: 0)
      }
      HStack {
        Spacer()
        Button("Done") { activeSheet = nil }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(28)
    .frame(width: 430)
  }

  private var installing: some View {
    VStack(spacing: 14) {
      Text("\(model.recoveryInterface ? "Restoring" : "Setting up") \(DestinationVolume.name)")
        .font(RecoveryAppearance.font(14)).foregroundColor(RecoveryAppearance.secondaryText)
      ProgressView(value: model.progress)
        .progressViewStyle(.linear)
        .frame(width: 380).padding(.top, 12)
      Text(model.currentOperation + "…")
        .font(RecoveryAppearance.font(12)).foregroundColor(RecoveryAppearance.secondaryText)
        .accessibilityLabel("Simulating: \(model.currentOperation)")
    }
  }

  private var complete: some View {
    VStack(spacing: 16) {
      Text(
        model.accountNeedsAuthorization
          ? "\(DestinationVolume.name) is ready for authorization."
          : "\(DestinationVolume.name) is ready to start."
      )
      .font(RecoveryAppearance.font(15))
      .foregroundColor(RecoveryAppearance.secondaryText)
      Image(nsImage: DestinationVolume.icon)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: 96, height: 96)
        .padding(.vertical, 12)
        .accessibilityHidden(true)
      VStack(spacing: 8) {
        Text("Select “\(DestinationVolume.name)”, click “Restart…”, then “Authorize Users…”.")
        Text(
          "Enter the credentials for your macOS account and the recovery account you just created."
        )
        .foregroundColor(RecoveryAppearance.secondaryText)
      }
      .font(RecoveryAppearance.font(12))
      .multilineTextAlignment(.center)
    }
  }

  private var account: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        model.accountAlreadyStarted
          ? "Verify your recovery account’s password to resume authorization.\n\nYour Linux login is separate."
          : "Create a separate recovery account for your Linux volume. Next, authorize it as a volume owner to manage Linux boot settings independently of your macOS account.\n\nYour Linux login is separate."
      )
      .font(RecoveryAppearance.font(12)).foregroundColor(RecoveryAppearance.secondaryText)
      VStack(alignment: .leading, spacing: 5) {
        Text("Username").font(RecoveryAppearance.font(12))
        TextField("recovery-owner", text: $model.accountUsername)
          .textContentType(.username).autocorrectionDisabled()
          .disabled(model.accountAlreadyStarted)
          .focused($accountField, equals: .username)
          .onSubmit { accountField = .password }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("Password").font(RecoveryAppearance.font(12))
        SecureField("Password", text: $model.accountPassword)
          .privacySensitive()
          .focused($accountField, equals: .password)
          .onSubmit { accountField = .confirmation }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("Retype password").font(RecoveryAppearance.font(12))
        SecureField("Retype password", text: $model.accountConfirmation)
          .privacySensitive()
          .focused($accountField, equals: .confirmation)
          .onSubmit { model.createRecoveryAccount() }
      }
    }
    .frame(width: 380)
    .textFieldStyle(.roundedBorder)
    .disabled(model.creatingAccount || model.restartingWithoutAccount)
    .onAppear { accountField = model.accountAlreadyStarted ? .password : .username }
    .onDisappear {
      model.accountPassword = ""
      model.accountConfirmation = ""
    }
  }

  @ViewBuilder private var navigation: some View {
    switch model.stage {
    case .welcome:
      HStack(spacing: 12) {
        Button(model.recoveryInterface ? "Restore" : "Continue") {
          if model.recoveryInterface {
            model.restore()
          } else {
            model.checkEnrollmentEnvironment {
              authorizingRecoveryRepair = false
              activeSheet = .authorization
            }
          }
        }
        if model.recoveryInterface {
          Button(model.debugEnabled ? "Disable Debug" : "Enable Debug") {
            model.toggleBootFlag("debug")
          }
          Button(model.proxyEnabled ? "Disable Proxy" : "Enable Proxy") {
            model.toggleBootFlag("proxy")
          }
        }
      }
      .buttonStyle(.borderedProminent).controlSize(.large)
      .disabled(model.checkingEnvironment)
    case .installing:
      EmptyView()
    case .account:
      VStack(spacing: 8) {
        HStack(spacing: 12) {
          ProgressView().controlSize(.small)
            .frame(width: 16, height: 16)
            .opacity(model.creatingAccount ? 1 : 0)
            .accessibilityLabel("Preparing account")
            .accessibilityHidden(!model.creatingAccount)
          Button(model.accountAlreadyStarted ? "Continue" : "Create Account") {
            model.createRecoveryAccount()
          }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .disabled(!model.canCreateAccount)
          Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
        }
        Button(model.restartingWithoutAccount ? "Restarting…" : "Skip, Restart Now") {
          model.skipRecoveryAccountAndRestart()
        }
        .buttonStyle(.plain)
        .font(RecoveryAppearance.font(12))
        .foregroundColor(RecoveryAppearance.secondaryText)
        .disabled(model.creatingAccount || model.restartingWithoutAccount)
      }
    case .complete:
      Button("Restart") { model.openStartupDisk() }
        .buttonStyle(.borderedProminent).controlSize(.large)
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Installation details").font(RecoveryAppearance.font(20, .semibold))
      Text(
        "Boot security is reduced only for this Aurora installation. Your macOS security settings are unchanged."
      )
      .font(RecoveryAppearance.font(12))
      .foregroundColor(RecoveryAppearance.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      LogTextView(text: log.text.isEmpty ? model.operations.joined(separator: "\n") : log.text)
        .frame(height: 200)
      if log.truncated {
        Text("Showing recent output. Copy Log includes this attempt’s full log.")
          .font(RecoveryAppearance.font(11)).foregroundColor(RecoveryAppearance.secondaryText)
      }
      HStack {
        Button(copyingLog ? "Copying…" : "Copy Log") { copyFullLog() }
          .disabled(copyingLog)
        Spacer()
        Button("Done") { activeSheet = nil }.keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 530)
  }
  private func copyFullLog() {
    copyingLog = true
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try log.fullText() }
      DispatchQueue.main.async {
        copyingLog = false
        switch result {
        case .success(let text):
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        case .failure(let error): model.failure = error.localizedDescription
        }
      }
    }
  }

}

// Let AppKit own the outer rounded frame, including the sheet dimming layer.
// Clipping only the SwiftUI content of a borderless window does not clip that layer.
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
    isMovableByWindowBackground = true
    // Full-size content occupies the titlebar too. Preserve the original outer
    // dimensions instead of adding AppKit's titlebar height to the layout.
    setFrame(NSRect(x: 0, y: 0, width: 780, height: 660), display: false)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
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
    NSApp.applicationIconImage = DestinationVolume.icon
    LaunchTrace.mark("window.creatingContent")
    let content = NSHostingView(rootView: InstallerView(model: model))
    // This fixed-size design includes the transparent titlebar. Do not let
    // hosting's preferred-content sizing add that titlebar a second time.
    content.sizingOptions = []
    window.contentView = content
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
  #if OMARCHY_STEP2_RECOVERY
    print("recovery")
  #elseif OMARCHY_STEP2_PREVIEW
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
