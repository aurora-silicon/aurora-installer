import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

@MainActor
private final class InstallerApplicationDelegate: NSObject, NSApplicationDelegate {
  static var removalInProgress = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if Self.removalInProgress {
      NSSound.beep()
      return .terminateCancel
    }
    return .terminateNow
  }

  private var instanceLease: InstallerAppInstanceLease?

  func applicationWillFinishLaunching(_ notification: Notification) {
    #if !DEBUG
      if ProcessInfo.processInfo.arguments.contains("--simulate")
        || ProcessInfo.processInfo.arguments.contains(where: {
          $0.hasPrefix("--preview-screen=") || $0.hasPrefix("--render-flow=")
        })
      {
        fputs("Simulation requires a debug build. Refusing to launch the live installer.\n", stderr)
        NSApplication.shared.terminate(nil)
        return
      }
    #endif
    do {
      let lockFile = try InstallerAppInstanceLease.defaultLockFileURL()
      instanceLease = try InstallerAppInstanceLease.acquire(at: lockFile)
    } catch {
      fputs(
        "\(InstallerProductIdentity.appName) refused a duplicate or unsafe launch: \(error)\n",
        stderr)
      NSApplication.shared.terminate(nil)
      return
    }
    startInstallerLog()
  }

  /// The one instance logs into the shared store, and the live installer
  /// also appends to the person's log file. Simulations stay in memory, so a
  /// rehearsal never reads as a real installation.
  private func startInstallerLog() {
    let store = InstallerLogStore.shared
    InstallerLog.setProcessBuffer(store.buffer)
    let simulated =
      ProcessInfo.processInfo.arguments.contains("--simulate")
      || ProcessInfo.processInfo.arguments.contains(where: {
        $0.hasPrefix("--preview-screen=") || $0.hasPrefix("--render-flow=")
      })
      || Bundle.main.object(forInfoDictionaryKey: "AuroraPreviewOnly") as? Bool == true
    if !simulated, let directory = InstallerLogFile.defaultDirectory() {
      store.persist(to: InstallerLogFile(directory: directory))
    }
    InstallerLog.progress(
      "\(InstallerProductIdentity.appName) \(InstallerVersion.current().map { "\($0)" } ?? "") "
        + "started" + (simulated ? " (simulation; nothing is saved to disk)" : ""))
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    #if DEBUG
      // The flow renderer ends the app itself once every image is written.
      if CommandLine.arguments.contains(where: { $0.hasPrefix("--render-flow=") }) {
        return false
      }
    #endif
    return true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The install ends with a shutdown the app itself requests. macOS would
    // otherwise treat it as an app open at shutdown and bring it back at the
    // next login, so someone rebooting from Aurora into macOS met the
    // installer again. Opt out for good.
    NSApp.disableRelaunchOnLogin()
    #if DEBUG
      if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--render-flow=") }) {
        // Offscreen only: no installer window is shown while it renders.
        let directory = URL(fileURLWithPath: String(argument.dropFirst("--render-flow=".count)))
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
          for window in NSApp.windows { window.orderOut(nil) }
        }
        Task { @MainActor in
          await FlowRenderer.run(directory: directory)
          NSApplication.shared.terminate(nil)
        }
        return
      }
      if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
        let path = String(argument.dropFirst("--snapshot=".count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          if let view = NSApp.keyWindow?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
          {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
              try? data.write(to: URL(fileURLWithPath: path))
            }
          }
          if CommandLine.arguments.contains("--quit-after-snapshot") {
            // An open preview sheet can defer application termination. End it
            // after capture so automated snapshots release their instance lease.
            for window in NSApp.windows {
              if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.orderOut(nil)
              }
            }
            NSApplication.shared.terminate(nil)
          }
        }
      }
    #endif
    DispatchQueue.main.async {
      for window in NSApp.windows where window.sheetParent == nil {
        if Bundle.main.object(forInfoDictionaryKey: "AuroraPreviewOnly") as? Bool == true {
          let compact = CommandLine.arguments.contains("--preview-compact")
          window.setContentSize(NSSize(width: 840, height: compact ? 580 : 680))
          window.center()
        }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          window.standardWindowButton(button)?.isHidden = true
        }
      }
    }

    #if DEBUG
      // A bare SwiftPM executable has no Info.plist, so Launch Services
      // registers it background-only and the window never appears. Promote
      // unbundled debug runs to a regular, frontmost app; the packaged app
      // is already regular and never enters this branch.
      if Bundle.main.bundleURL.pathExtension != "app" {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
      }
    #endif
  }
}

@main
struct AuroraAppleInstallerApp: App {
  @NSApplicationDelegateAdaptor(InstallerApplicationDelegate.self)
  private var applicationDelegate

  /// Testers switch to a pre-release channel here. The choice only picks among
  /// the URLs already signed into this build; changing it restarts the check so
  /// nothing planned against one channel is installed from the other.
  @State private var liveSession: InstallerSession?
  @State private var selection = AuroraInstallationSelection()
  @State private var choosingSystem = true
  @State private var checkedPendingInstallation = false
  @State private var showsRemoval = false
  /// The startup container chosen with Erase on the Partitions screen.
  @State private var removalTarget: DiskLayoutDisplay.EraseTarget?
  @State private var removalNeedsReview = false
  @State private var removalBusy = false
  /// Command-D. Lives for this launch only; see `DeveloperMode`.
  @State private var developerMode = Self.previewsDeveloperMode

  /// Visual previews can show the Developer mode badge; live launches never
  /// start in Developer mode.
  private static var previewsDeveloperMode: Bool {
    #if DEBUG
      return CommandLine.arguments.contains("--preview-developer-mode")
        && CommandLine.arguments.contains("--simulate")
    #else
      return false
    #endif
  }
  /// Changed to read the profile's default channel again, after Developer
  /// mode is turned off while a developer-only channel was in use.
  @State private var channelCheck = UUID()
  #if DEBUG
    @State private var simulation = SimulationControls()
  #endif
  @State private var generation = UUID()

  private var isSimulation: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.arguments.contains("--simulate")
        || Bundle.main.object(forInfoDictionaryKey: "AuroraPreviewOnly") as? Bool == true
    #else
      return false
    #endif
  }

  @ViewBuilder
  private var installerContent: some View {
    #if DEBUG
      if !simulation.heldScreen.isEmpty {
        if isSimulation {
          InstallerVisualPreview(screen: simulation.heldScreen)
        } else {
          ContentUnavailableView("Visual previews require --simulate", systemImage: "lock.shield")
        }
      } else {
        selectedInstallerContent
      }
    #else
      selectedInstallerContent
    #endif
  }

  @ViewBuilder
  private var selectedInstallerContent: some View {
    if choosingSystem {
      #if DEBUG
        let selectedChannel = isSimulation ? simulation.channel : channel
      #else
        let selectedChannel = channel
      #endif
      AuroraWelcomeView(
        selection: $selection, device: .inspect(isSimulation: isSimulation),
        channel: selectedChannel,
        distributions: DeveloperMode.distributions(isOn: developerMode)
      ) {
        choosingSystem = false
        generation = UUID()
      }
    } else {
      flowContent
    }
  }

  @ViewBuilder
  private var flowContent: some View {
    #if DEBUG
      if isSimulation {
        SimulationDashboard(
          controls: simulation, selection: selection, onSessionAvailable: { liveSession = $0 },
          onRemoveLinux: { showsRemoval = true },
          onEraseInstallation: {
            removalTarget = $0
            showsRemoval = true
          })
      } else {
        liveContent
      }
    #else
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        ContentUnavailableView(
          "Simulation needs a debug build.", systemImage: "lock.shield")
      } else {
        liveContent
      }
    #endif
  }

  private var liveContent: some View {
    OnePageInstallerView(
      environment: LiveInstallerEnvironment(selection: selection), channel: channel,
      selection: selection, startAtPlan: true,
      onSessionAvailable: { liveSession = $0 }, onRemoveLinux: { showsRemoval = true },
      onEraseInstallation: {
        removalTarget = $0
        showsRemoval = true
      },
      onChooseSystem: {
        liveSession?.cancelPrefetchOnQuit()
        liveSession = nil
        choosingSystem = true
        generation = UUID()
      })
  }

  /// The channel the selected profile reads: the Release channel menu's
  /// choice, or this launch's default from the profile's verified Edge
  /// catalog. `nil` while that catalog is read, or when the bundle has no
  /// release descriptor for the profile.
  @State private var channel: ReleaseChannel?

  var body: some Scene {
    WindowGroup(PlainLanguage.windowTitle) {
      Group {
        if removalNeedsReview {
          VStack {
            ContentUnavailableView(
              "Removal needs a check", systemImage: "externaldrive.badge.exclamationmark",
              description: Text(
                "Check the removal record and the disk layout before you change any disk."))

          }
        } else {
          installerContent
        }
      }
      .id(generation)
      .overlay(alignment: .top) {
        if developerMode {
          DeveloperModeBadge { setDeveloperMode(false) }.padding(.top, Space.s)
        }
      }
      .task(id: selection.profileID + channelCheck.uuidString) {
        guard !isSimulation else { return }
        // Another profile's channel says nothing about this one.
        channel = nil
        let decided = await LiveInstallerEnvironment.releaseChannel(for: selection)
        // A newer selection's check replaces this one.
        guard !Task.isCancelled else { return }
        channel = decided
      }
      .task {
        guard !isSimulation, !checkedPendingInstallation else { return }
        checkedPendingInstallation = true
        do {
          if let hint = try LiveInstallerEnvironment.pendingJobStore().load() {
            selection = hint.ticket.selection
            choosingSystem = false
          }
        } catch {
          // The live environment reports unsafe state before fresh admission.
          choosingSystem = false
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      ) { _ in
        liveSession?.cancelPrefetchOnQuit()
      }
      .disabled(showsRemoval)
      .sheet(
        isPresented: $showsRemoval,
        onDismiss: {
          removalTarget = nil
          generation = UUID()
        }
      ) {
        AuroraRemovalSheet(
          isSimulation: isSimulation,
          onBusyChanged: { busy in
            removalBusy = busy
            InstallerApplicationDelegate.removalInProgress = busy
            for window in NSApp.windows where window.sheetParent == nil {
              window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
          }, onClose: { showsRemoval = false }, onRequiresReview: { removalNeedsReview = true },
          simulationScenario: previewRemovalScenario,
          eraseTarget: removalTarget)
      }
      .preferredColorScheme(previewColorScheme)
      .frame(minWidth: 800, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .top)
      .auroraTypography()
      // The window itself takes the theme colour, title bar included, so the
      // translucent system title bar never tints from the wallpaper behind.
      .containerBackground(InstallerTheme.window, for: .window)
    }
    .defaultSize(width: 840, height: 680)
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(before: .windowList) {
        InstallerLogMenuItem()
        Divider()
      }
      CommandGroup(replacing: .appInfo) {
        Button("About Aurora Installer") {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: TrademarkNotice.credits
          ])
        }
      }
      #if DEBUG
        if isSimulation {
          CommandMenu("Simulation") {
            Picker("Hold Screen", selection: $simulation.heldScreen) {
              Text("Live simulation").tag("")
              Text("Checking this Mac").tag("loading")
              Text("Preparing to install").tag("preparing")
              Text("Disk allocation").tag("allocation")
            }
            Divider()
            Picker("Scenario", selection: $simulation.scenario) {
              ForEach(InstallerSimulationScenario.allCases) { item in
                Text(item.title).tag(item)
              }
            }
            Picker("Test Channel", selection: $simulation.channel) {
              ForEach(ReleaseChannel.allCases, id: \.self) { item in
                Text(PlainLanguage.badge(for: item)).tag(item)
              }
            }.disabled(!simulation.canChangeChannel)
            Toggle("Slow Playback", isOn: $simulation.slow)
            Toggle("Dark Appearance", isOn: $simulation.dark)
            Divider()
            Button("Preview Recovery Handoff…") { simulation.previewsRecoveryHandoff = true }
            Picker("Removal Scenario", selection: $simulation.removalScenario) {
              ForEach(RemovalPreviewScenario.allCases, id: \.self) { item in
                Text(item.rawValue).tag(item)
              }
            }.disabled(removalBusy)
            Divider()
            Button("Reset Simulation") {
              guard !removalBusy else { return }
              showsRemoval = false
              removalNeedsReview = false
              simulation.reset()
              generation = UUID()
            }.disabled(removalBusy)
            Button("Scenario Guidance…") { simulation.showGuidance() }
          }
        }
      #endif
      CommandMenu("Installation") {
        Button("Choose a System") {
          liveSession?.cancelPrefetchOnQuit()
          liveSession = nil
          choosingSystem = true
          generation = UUID()
        }.disabled(!choosingSystem && liveSession?.canChangeChannel != true)
        Divider()
        Button("Erase Linux…") {
          removalTarget = nil
          showsRemoval = true
        }
        .disabled(removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true)
        Divider()
        Toggle(PlainLanguage.developerModeMenuItem, isOn: developerModeBinding)
          .keyboardShortcut("d", modifiers: .command)
          .disabled(!canToggleDeveloperMode)
        if developerMode, !DeveloperMode.shared.stubOverrideCandidates.isEmpty {
          Picker(PlainLanguage.developerStubMenuTitle, selection: stubOverrideBinding) {
            Text(PlainLanguage.developerStubDefault).tag(StubOverrideChoice?.none)
            ForEach(DeveloperMode.shared.stubOverrideCandidates) { choice in
              Text(choice.title).tag(StubOverrideChoice?.some(choice))
            }
          }
          .disabled(liveSession?.canChangeChannel != true && !choosingSystem)
        }
      }
      if InstallerBuildProfile.current.showsReleaseChannels {
        CommandMenu(PlainLanguage.channelMenuTitle) {
          // One toggle per channel rather than an inline picker, so a channel
          // with nothing for this Mac can be shown but not chosen.
          ForEach(
            DeveloperMode.menuChannels(isOn: developerMode, inUse: shownChannel), id: \.self
          ) { option in
            let availability = liveSession?.channelAvailability[option]
            Toggle(
              PlainLanguage.channelMenuItem(option, availability: availability),
              isOn: channelBinding(option)
            )
            .disabled(
              !PlainLanguage.channelMenuItemEnabled(
                option, selected: shownChannel, availability: availability))
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
          Divider()
          Button(PlainLanguage.channelMenuCheckAgain) {
            guard let session = liveSession else { return }
            let profileID = selection.profileID
            Task {
              // One read refreshes the menu and decides again a default that
              // came from a failed Edge check; an answer that arrives after
              // another distribution or session is on screen is dropped.
              let decided = await ReleaseChannelPreference().checkAgain(
                profileID: profileID,
                read: {
                  await session.refreshChannelAvailability()
                  return session.edgeCheck
                },
                isCurrent: { selection.profileID == profileID && liveSession === session })
              if let decided { channel = decided }
            }
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
        }
      }
    }

    Window(InstallerLogWindow.title, id: InstallerLogWindow.id) {
      InstallerLogView(store: .shared)
        .preferredColorScheme(previewColorScheme)
    }
    .defaultSize(width: 780, height: 480)
    // The Window menu's own item, with ⌘L, opens it.
    .commandsRemoved()
  }

  private var previewColorScheme: ColorScheme? {
    #if DEBUG
      if CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-screen=") }) {
        return CommandLine.arguments.contains("--preview-dark") ? .dark : .light
      }
      if isSimulation { return simulation.dark ? .dark : .light }
    #endif
    return nil
  }

  private var previewRemovalScenario: String? {
    #if DEBUG
      if isSimulation { return simulation.removalScenario.rawValue }
    #endif
    return nil
  }

  /// The channel the plan on screen reads: an existing installation's own
  /// for Reset and Update Boot Loader, otherwise the selected profile's.
  private var shownChannel: ReleaseChannel? {
    liveSession?.existingInstallationChannel ?? channel
  }

  /// Developer mode can be turned on or off while the user is choosing a
  /// system or reviewing a plan, never while an installation or removal runs.
  private var canToggleDeveloperMode: Bool {
    !removalNeedsReview && !showsRemoval && !removalBusy
      && (choosingSystem || liveSession?.canChangeChannel == true)
  }

  private var developerModeBinding: Binding<Bool> {
    Binding(get: { developerMode }, set: { setDeveloperMode($0) })
  }

  @State private var stubOverride: StubOverrideChoice?

  private var stubOverrideBinding: Binding<StubOverrideChoice?> {
    Binding(
      get: { stubOverride },
      set: {
        DeveloperMode.shared.stubOverride = $0
        stubOverride = DeveloperMode.shared.stubOverride
      })
  }

  /// Turning Developer mode on only shows more options; nothing on screen
  /// changes. Turning it off drops a developer-only channel, distribution or
  /// stub, and the plan on screen starts again from the regular defaults.
  private func setDeveloperMode(_ on: Bool) {
    guard on != developerMode, canToggleDeveloperMode else { return }
    developerMode = on
    DeveloperMode.shared.isOn = on
    InstallerLog.progress(
      on ? PlainLanguage.developerModeOnLog : PlainLanguage.developerModeOffLog)
    guard !on else { return }
    stubOverride = nil
    let preference = ReleaseChannelPreference()
    let usedDeveloperChannel = channel.map(DeveloperMode.isDeveloperChannel) ?? false
    preference.select(DeveloperMode.choiceAfterLeaving(preference.stored))
    let regular = DeveloperMode.selectionAfterLeaving(selection)
    let changedSelection = regular != selection
    selection = regular
    guard usedDeveloperChannel || changedSelection else { return }
    if usedDeveloperChannel { channelCheck = UUID() }
    if !choosingSystem {
      liveSession?.cancelPrefetchOnQuit()
      liveSession = nil
      generation = UUID()
    }
  }

  private func channelBinding(_ option: ReleaseChannel) -> Binding<Bool> {
    Binding(
      get: { shownChannel == option },
      set: { isOn in
        guard isOn, option != shownChannel,
          liveSession?.canChangeChannel == true && !isSimulation,
          PlainLanguage.channelMenuItemEnabled(
            option, selected: shownChannel,
            availability: liveSession?.channelAvailability[option])
        else {
          return
        }
        ReleaseChannelPreference().select(option)
        guard option == channel else {
          channel = option
          return
        }
        // The plan on screen read an existing installation's channel; start
        // again on the chosen one, as any other channel switch does.
        liveSession?.cancelPrefetchOnQuit()
        liveSession = nil
        generation = UUID()
      }
    )
  }
}
