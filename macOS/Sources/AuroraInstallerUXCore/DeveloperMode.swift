#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// Developer mode shows expert options that regular users never see.
  ///
  /// Command-D (Installation > Developer Mode) turns it on and off. It lasts
  /// for this launch only and is never saved, so a fresh launch always starts
  /// in the regular mode. While it is on, the window shows a "Developer mode"
  /// badge with a button that turns it off.
  ///
  /// Regular users see the Stable and Nightly channels. Developer mode adds
  /// Release candidate and Edge, any distribution that is not ready for
  /// everyone, and the macOS stub override once the engine offers choices.
  /// It only chooses among channels and profiles already signed into this
  /// build, so it can never add a source the app was not built to trust.
  public final class DeveloperMode: @unchecked Sendable {
    public static let shared = DeveloperMode()

    private let lock = NSLock()
    private var on = false
    private var stub: StubOverrideChoice?
    private var stubs = [StubOverrideChoice]()

    public init() {}

    public var isOn: Bool {
      get { lock.withLock { on } }
      set {
        lock.withLock {
          on = newValue
          if !newValue { stub = nil }
        }
      }
    }

    /// The stub picked instead of the qualified default, or `nil` for the
    /// default. Always `nil` outside Developer mode.
    public var stubOverride: StubOverrideChoice? {
      get { lock.withLock { on ? stub : nil } }
      set { lock.withLock { stub = on ? newValue : nil } }
    }

    /// The stubs the engine lets a developer pick for this Mac
    /// (`NativeStubOverride.candidates`). Empty when the policy knows fewer
    /// than two; the menu then shows no stub choice at all.
    public var stubOverrideCandidates: [StubOverrideChoice] {
      get { lock.withLock { stubs } }
      set { lock.withLock { stubs = newValue } }
    }

    /// The stub a fresh installation asks the engine for: `--stub-version`
    /// from the command line if given, which works whether or not Developer
    /// mode is on, else the Developer mode menu's pick (`nil` outside
    /// Developer mode). A build is asked for by build, so it names one entry.
    public var requestedStubVersion: String? {
      Self.stubVersionArgument() ?? stubOverride.map { $0.build.isEmpty ? $0.version : $0.build }
    }

    /// `--stub-version VERSION-OR-BUILD` or `--stub-version=VERSION-OR-BUILD`.
    public static func stubVersionArgument(
      _ arguments: [String] = CommandLine.arguments
    ) -> String? {
      for (index, argument) in arguments.enumerated() {
        if argument.hasPrefix("--stub-version=") {
          let value = String(argument.dropFirst("--stub-version=".count))
          return value.isEmpty ? nil : value
        }
        if argument == "--stub-version", index + 1 < arguments.count {
          let value = arguments[index + 1]
          return value.isEmpty || value.hasPrefix("--") ? nil : value
        }
      }
      return nil
    }

    /// The channels everyone sees.
    public static let everyoneChannels: [ReleaseChannel] = [.stable, .testing]

    public static func isDeveloperChannel(_ channel: ReleaseChannel) -> Bool {
      !everyoneChannels.contains(channel)
    }

    /// The Release channel menu's items. Outside Developer mode the channel
    /// in use is still listed, so an existing Edge installation can be reset
    /// or updated from the channel it came from.
    public static func menuChannels(isOn: Bool, inUse: ReleaseChannel?) -> [ReleaseChannel] {
      ReleaseChannel.allCases.filter { isOn || !isDeveloperChannel($0) || $0 == inUse }
    }

    /// The channel choice to keep when Developer mode is turned off: a
    /// developer-only pick is dropped, so the profile's default applies again.
    public static func choiceAfterLeaving(_ stored: ReleaseChannel?) -> ReleaseChannel? {
      guard let stored, !isDeveloperChannel(stored) else { return nil }
      return stored
    }

    /// Distributions that only Developer mode offers, because they have no
    /// signed catalog for everyone yet. Aurora, based on Debian testing joins
    /// this set until its signed catalog is live.
    public static let developerOnlyDistributions: Set<AuroraDistribution> = []

    /// The distributions the chooser shows.
    public static func distributions(isOn: Bool) -> [AuroraDistribution] {
      AuroraDistribution.installable.filter { isOn || !developerOnlyDistributions.contains($0) }
    }

    /// The selection to show when Developer mode is turned off: a
    /// developer-only distribution falls back to the default selection.
    public static func selectionAfterLeaving(
      _ selection: AuroraInstallationSelection
    ) -> AuroraInstallationSelection {
      developerOnlyDistributions.contains(selection.distribution)
        ? AuroraInstallationSelection() : selection
    }

    /// The Mac whose Edge support may make Edge the launch default. Edge is a
    /// developer channel, so outside Developer mode no Mac does.
    public static func edgeDecidingDevice(_ deviceIdentifier: String?, isOn: Bool) -> String? {
      isOn ? deviceIdentifier : nil
    }
  }

// StubOverrideChoice lives in the engine (AuroraAppleInstallerTrustCore,
// NativeStubOverride.swift), so the engine never depends on this module.
#endif
