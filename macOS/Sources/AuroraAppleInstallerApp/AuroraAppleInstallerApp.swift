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
        || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview-screen=") })
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
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The install ends with a shutdown the app itself requests. macOS would
    // otherwise treat it as an app open at shutdown and bring it back at the
    // next login, so someone rebooting from Aurora into macOS met the
    // installer again. Opt out for good.
    NSApp.disableRelaunchOnLogin()
    #if DEBUG
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
  @State private var removalNeedsReview = false
  @State private var removalBusy = false
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
      AuroraWelcomeView(selection: $selection, device: .inspect(isSimulation: isSimulation)) {
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
          onRemoveLinux: { showsRemoval = true })
      } else {
        liveContent
      }
    #else
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        ContentUnavailableView(
          "Simulation is available in debug builds only.", systemImage: "lock.shield")
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
      onChooseSystem: {
        liveSession?.cancelPrefetchOnQuit()
        liveSession = nil
        choosingSystem = true
        generation = UUID()
      })
  }

  @State private var channel = ReleaseChannelPreference().resolveFromMainBundle()

  var body: some Scene {
    WindowGroup(PlainLanguage.windowTitle) {
      Group {
        if removalNeedsReview {
          VStack {
            ContentUnavailableView(
              "Removal needs review", systemImage: "externaldrive.badge.exclamationmark",
              description: Text(
                "Check the removal record and disk layout before changing any disks."))

          }
        } else {
          installerContent
        }
      }
      .id(generation)
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
      .sheet(isPresented: $showsRemoval, onDismiss: { generation = UUID() }) {
        AuroraRemovalSheet(
          isSimulation: isSimulation,
          onBusyChanged: { busy in
            removalBusy = busy
            InstallerApplicationDelegate.removalInProgress = busy
            for window in NSApp.windows where window.sheetParent == nil {
              window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
          }, onClose: { showsRemoval = false }, onRequiresReview: { removalNeedsReview = true },
          simulationScenario: previewRemovalScenario)
      }
      .preferredColorScheme(previewColorScheme)
      .frame(minWidth: 800, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .top)
      .auroraTypography()
      .tint(.gray)
      // The window itself takes the theme colour, title bar included, so the
      // translucent system title bar never tints from the wallpaper behind.
      .containerBackground(InstallerTheme.window, for: .window)
    }
    .defaultSize(width: 840, height: 680)
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      #if DEBUG
        if isSimulation {
          CommandMenu("Simulation") {
            Picker("Hold Screen", selection: $simulation.heldScreen) {
              Text("Live simulation").tag("")
              Text("Getting everything ready").tag("loading")
              Text("Preparing your installation").tag("preparing")
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
        Button("Choose system") {
          liveSession?.cancelPrefetchOnQuit()
          liveSession = nil
          choosingSystem = true
          generation = UUID()
        }.disabled(!choosingSystem && liveSession?.canChangeChannel != true)
        Divider()
        Button("Erase Linux") { showsRemoval = true }
          .disabled(removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true)
      }
      if InstallerBuildProfile.current.showsReleaseChannels {
        CommandMenu(PlainLanguage.channelMenuTitle) {
          // One toggle per channel rather than an inline picker, so a channel
          // with nothing for this Mac can be shown but not chosen.
          ForEach(ReleaseChannel.allCases, id: \.self) { option in
            let availability = liveSession?.channelAvailability[option]
            Toggle(
              PlainLanguage.channelMenuItem(option, availability: availability),
              isOn: channelBinding(option)
            )
            .disabled(
              !PlainLanguage.channelMenuItemEnabled(
                option, selected: channel, availability: availability))
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
          Divider()
          Button(PlainLanguage.channelMenuCheckAgain) {
            Task { await liveSession?.refreshChannelAvailability() }
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
        }
      }
    }
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

  private func channelBinding(_ option: ReleaseChannel) -> Binding<Bool> {
    Binding(
      get: { channel == option },
      set: { isOn in
        guard isOn, option != channel,
          liveSession?.canChangeChannel == true && !isSimulation,
          PlainLanguage.channelMenuItemEnabled(
            option, selected: channel,
            availability: liveSession?.channelAvailability[option])
        else {
          return
        }
        ReleaseChannelPreference().select(option)
        channel = option
      }
    )
  }
}
