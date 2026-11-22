#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// Holds which release channel this run of the app reads.
  ///
  /// A choice from the Release channel menu wins. Otherwise each distribution
  /// profile's default for a new installation is decided once per launch from
  /// that profile's verified Edge catalog: Edge where it admits this Mac and
  /// lists it as family-qualified (its chip family passed the Edge rows on a
  /// named machine), the bundled default (Nightly) where it doesn't. A plan
  /// for an existing installation reads the channel it came from instead. The
  /// choice and the decisions live in memory only, and one app process can
  /// never change another's channel. It only chooses between the channel URLs
  /// already baked into the signed app bundle, so it can never introduce a
  /// source the app was not built to trust.
  public struct ReleaseChannelPreference: Sendable {
    /// Reads one profile's Edge catalog and says what it offers this Mac.
    public typealias EdgeCheck = @Sendable (_ deviceIdentifier: String) async -> EdgeCatalogCheck

    public final class Store: @unchecked Sendable {
      private let lock = NSLock()
      private var value: ReleaseChannel?
      private var checks = [String: Task<LaunchDefault, Never>]()
      private var decided = [String: LaunchDefault]()

      public init() {}

      var channel: ReleaseChannel? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
      }

      func decided(_ profileID: String) -> LaunchDefault? {
        lock.withLock { decided[profileID] }
      }

      /// Every caller for one profile waits on the same check.
      func decide(
        _ profileID: String, check: @escaping @Sendable () async -> LaunchDefault
      ) -> Task<LaunchDefault, Never> {
        lock.withLock {
          if let running = checks[profileID] { return running }
          let task = Task<LaunchDefault, Never> {
            let decision = await check()
            self.lock.withLock { self.decided[profileID] = decision }
            return decision
          }
          checks[profileID] = task
          return task
        }
      }

      /// Decides a default that came from a failed Edge check again, from
      /// this fresh read. A verified decision holds for the launch.
      func redecide(_ profileID: String, edge: EdgeCatalogCheck) -> LaunchDefault? {
        lock.withLock {
          guard let previous = decided[profileID], previous.edgeCheckFailed else { return nil }
          let decision = LaunchDefault(descriptorDefault: previous.descriptorDefault, edge: edge)
          decided[profileID] = decision
          checks[profileID] = Task { decision }
          return decision
        }
      }
    }

    struct LaunchDefault: Equatable, Sendable {
      let channel: ReleaseChannel
      let descriptorDefault: ReleaseChannel
      /// Edge's catalog couldn't be fetched or verified, so this Mac's
      /// support is unknown and Check Channels Again may decide it.
      let edgeCheckFailed: Bool

      init(descriptorDefault: ReleaseChannel, edge: EdgeCatalogCheck) {
        channel = ReleaseChannelPreference.launchDefault(
          descriptorDefault: descriptorDefault, edge: edge)
        self.descriptorDefault = descriptorDefault
        if case .checkFailed = edge.availability {
          edgeCheckFailed = true
        } else {
          edgeCheckFailed = false
        }
      }
    }

    public static let processStore = Store()

    private static let processDeviceIdentifier: String? = {
      guard InstallerBuildProfile.current == .standard else { return nil }
      return (try? AppleSiliconHostInspector().inspectIdentity())?.deviceIdentifier
    }()
    private let store: Store
    private let deviceIdentifier: String?

    public init(store: Store = processStore) {
      self.init(store: store, deviceIdentifier: Self.processDeviceIdentifier)
    }

    public init(store: Store, deviceIdentifier: String?) {
      self.store = store
      self.deviceIdentifier = deviceIdentifier
    }

    /// The choice made in this run, or `nil` when none was made.
    public var stored: ReleaseChannel? { store.channel }

    public func select(_ channel: ReleaseChannel?) {
      store.channel = channel
    }

    public func resolve(descriptorDefault: ReleaseChannel) -> ReleaseChannel {
      stored ?? descriptorDefault
    }

    /// Edge wherever the profile's verified Edge catalog admits this Mac and
    /// lists it as family-qualified, and the bundled default wherever it
    /// doesn't. A listed Mac that isn't family-qualified can still choose Edge.
    /// A catalog that couldn't be fetched or verified says nothing about this
    /// Mac: Edge stays the channel, and preparing it fetches the catalog again.
    public static func launchDefault(
      descriptorDefault: ReleaseChannel, edge: EdgeCatalogCheck
    ) -> ReleaseChannel {
      switch edge.availability {
      case .available: edge.qualifiesThisMac ? .edge : descriptorDefault
      case .checkFailed: .edge
      case .noRelease, .notPublished, .modelUnavailable: descriptorDefault
      }
    }

    /// The channel already settled for this profile, without waiting: the
    /// choice made in this run, the descriptor default where Edge doesn't
    /// decide it, or this launch's Edge decision. `nil` while that check runs.
    public func resolve(
      configuration: InstallerReleaseConfiguration, profileID: String
    ) -> ReleaseChannel? {
      if let stored { return stored }
      guard decidesFromEdge(configuration) != nil else { return configuration.defaultChannel }
      return store.decided(profileID)?.channel
    }

    /// The channel the next preparation fetches. The window and the download
    /// both resolve through here and share one Edge check per profile, so they
    /// cannot disagree.
    public func resolve(
      configuration: InstallerReleaseConfiguration, profileID: String,
      checkEdge: @escaping EdgeCheck
    ) async -> ReleaseChannel {
      if let stored { return stored }
      guard let deviceIdentifier = decidesFromEdge(configuration) else {
        return configuration.defaultChannel
      }
      let descriptorDefault = configuration.defaultChannel
      let decision = await store.decide(profileID) {
        let edge = await checkEdge(deviceIdentifier)
        return LaunchDefault(descriptorDefault: descriptorDefault, edge: edge)
      }.value
      return stored ?? decision.channel
    }

    /// The channel a plan for an existing installation reads, for Reset and
    /// Update Boot Loader: the choice made in this run, else the channel
    /// recorded when it was installed, else the descriptor default. This
    /// launch's Edge default is for new installations only.
    public func resolve(
      configuration: InstallerReleaseConfiguration,
      existingInstallationChannel recorded: ReleaseChannel?
    ) -> ReleaseChannel {
      stored ?? recorded ?? configuration.defaultChannel
    }

    /// Check Channels Again. `read` re-reads every channel once for the menu
    /// and returns Edge's part of that same read; a default decided while Edge
    /// couldn't be checked is decided again from it. Returns the channel the
    /// window now shows, or `nil` to keep it: nothing was decided again, there
    /// was no answer, or `isCurrent` says another profile or session is on
    /// screen by the time the read finishes, so its channel stands.
    @MainActor
    public func checkAgain(
      profileID: String,
      read: () async -> EdgeCatalogCheck?,
      isCurrent: () -> Bool
    ) async -> ReleaseChannel? {
      let edge = await read()
      guard isCurrent(), let edge, let decision = store.redecide(profileID, edge: edge)
      else { return nil }
      return stored ?? decision.channel
    }

    /// The Mac whose Edge support decides the default, or `nil` when the
    /// descriptor's own default applies: a build other than the standard one,
    /// a legacy development descriptor (it has no Edge), or a descriptor whose
    /// default isn't Testing.
    private func decidesFromEdge(_ configuration: InstallerReleaseConfiguration) -> String? {
      guard configuration.defaultChannel == .testing, !configuration.legacyDevelopmentChannel
      else { return nil }
      return deviceIdentifier
    }
  }
#endif
