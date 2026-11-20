#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// Holds which release channel this run of the app reads.
  ///
  /// A choice from the Release channel menu wins. Otherwise each distribution
  /// profile's default is decided once per launch from that profile's verified
  /// Edge catalog: Edge where it admits this Mac, the bundled default (Nightly)
  /// where it verifiably doesn't. The choice and the decisions live in memory
  /// only, and one app process can never change another's channel. It only
  /// chooses between the channel URLs already baked into the signed app bundle, so
  /// it can never introduce a source the app was not built to trust.
  public struct ReleaseChannelPreference: Sendable {
    /// Reads one profile's Edge catalog and says what it offers this Mac.
    public typealias EdgeCheck =
      @Sendable (_ deviceIdentifier: String) async -> ReleaseChannelAvailability

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

      func forgetFailedCheck(_ profileID: String) -> Bool {
        lock.withLock {
          guard decided[profileID]?.edgeCheckFailed == true else { return false }
          decided[profileID] = nil
          checks[profileID] = nil
          return true
        }
      }
    }

    struct LaunchDefault: Equatable, Sendable {
      let channel: ReleaseChannel
      /// Edge's catalog couldn't be fetched or verified, so this Mac's
      /// support is unknown and Check Channels Again may decide it.
      let edgeCheckFailed: Bool
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

    /// Edge wherever the profile's verified Edge catalog admits this Mac, and
    /// the bundled default only where Edge verifiably doesn't. A catalog that
    /// couldn't be fetched or verified says nothing about this Mac: Edge stays
    /// the channel, and preparing it fetches the catalog again.
    public static func launchDefault(
      descriptorDefault: ReleaseChannel, edge: ReleaseChannelAvailability
    ) -> ReleaseChannel {
      switch edge {
      case .available, .checkFailed: .edge
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
        if case .checkFailed = edge {
          return LaunchDefault(channel: .edge, edgeCheckFailed: true)
        }
        return LaunchDefault(
          channel: Self.launchDefault(descriptorDefault: descriptorDefault, edge: edge),
          edgeCheckFailed: false)
      }.value
      return stored ?? decision.channel
    }

    /// Check Channels Again: a default decided from a failed Edge check is
    /// decided again by the next resolve. A verified answer holds for the
    /// launch. Returns whether there was one to decide again.
    @discardableResult
    public func recheckFailedEdgeDefault(profileID: String) -> Bool {
      store.forgetFailedCheck(profileID)
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
