#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  @testable import AuroraInstallerUXCore

  final class ReleaseChannelPreferenceTests: XCTestCase {
    private var store = ReleaseChannelPreference.Store()

    override func setUp() {
      store = ReleaseChannelPreference.Store()
    }

    func testAnUnsetPreferenceUsesTheDescriptorDefault() {
      let preference = ReleaseChannelPreference(store: store)

      XCTAssertNil(preference.stored)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .stable)
      XCTAssertEqual(preference.resolve(descriptorDefault: .rc), .rc)
    }

    func testSelectingBetaIsRemembered() {
      let preference = ReleaseChannelPreference(store: store)

      preference.select(.rc)

      XCTAssertEqual(preference.stored, .rc)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .rc)
    }

    func testAnExplicitEdgePickIsRememberedForThisLaunch() {
      let preference = ReleaseChannelPreference(store: store)
      XCTAssertEqual(preference.resolve(descriptorDefault: .testing), .testing)
      preference.select(.edge)
      XCTAssertEqual(preference.resolve(descriptorDefault: .testing), .edge)
      let fresh = ReleaseChannelPreference(store: ReleaseChannelPreference.Store())
      XCTAssertEqual(fresh.resolve(descriptorDefault: .testing), .testing)
    }

    func testClearingThePreferenceReturnsToTheDefault() {
      let preference = ReleaseChannelPreference(store: store)
      preference.select(.rc)

      preference.select(nil)

      XCTAssertNil(preference.stored)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .stable)
    }

    func testAPickIsNotSavedAcrossLaunches() {
      // A saved pick once kept a Mac opening on RC; the choice must not reach
      // UserDefaults, where the next launch or another instance would read it.
      let legacy = UserDefaults.standard.object(forKey: "ReleaseChannel") as? String
      ReleaseChannelPreference(store: store).select(.rc)

      XCTAssertEqual(ReleaseChannelPreference(store: store).stored, .rc)
      XCTAssertNil(ReleaseChannelPreference(store: ReleaseChannelPreference.Store()).stored)
      XCTAssertEqual(UserDefaults.standard.object(forKey: "ReleaseChannel") as? String, legacy)
    }

    func testAnyFamilyQualifiedMacDefaultsToEdge() async throws {
      // The app names no model and no profile: a Mac gets Edge as soon as the
      // selected profile's verified Edge catalog admits it and lists it as
      // family-qualified.
      let configuration = try Self.bundledConfiguration()
      for deviceIdentifier in ["apple,j700", "apple,j714s", "apple,j313"] {
        let preference = ReleaseChannelPreference(
          store: ReleaseChannelPreference.Store(), deviceIdentifier: deviceIdentifier)
        let edge = EdgeAnswers([Self.proven])

        XCTAssertNil(preference.resolve(configuration: configuration, profileID: "arch-kde"))
        let channel = await preference.resolve(
          configuration: configuration, profileID: "arch-kde", checkEdge: edge.check)

        XCTAssertEqual(channel, .edge, deviceIdentifier)
        XCTAssertEqual(
          preference.resolve(configuration: configuration, profileID: "arch-kde"), .edge,
          deviceIdentifier)
        XCTAssertEqual(edge.checkedDevices, [deviceIdentifier])
      }
    }

    func testNightlyIsTheDefaultOnlyWhereEdgeDoesNotSupportThisMac() async throws {
      let configuration = try Self.bundledConfiguration()
      XCTAssertEqual(configuration.defaultChannel, .testing)
      let unsupported: [ReleaseChannelAvailability] = [
        .modelUnavailable(supportedDeviceIdentifiers: ["apple,j700"]),
        .noRelease,
        .notPublished,
      ]
      for availability in unsupported {
        let preference = ReleaseChannelPreference(
          store: ReleaseChannelPreference.Store(), deviceIdentifier: "apple,j313")
        let channel = await preference.resolve(
          configuration: configuration, profileID: "fedora-kde",
          checkEdge: EdgeAnswers([EdgeCatalogCheck(availability: availability)]).check)
        XCTAssertEqual(channel, .testing, "\(availability)")
      }
    }

    func testAListedMacThatIsNotFamilyQualifiedDefaultsToNightly() async throws {
      // Being listed makes Edge selectable on this Mac, not its default; an
      // explicit pick still gets Edge.
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j313")
      let listed = EdgeCatalogCheck(availability: .available, qualifiesThisMac: false)

      let channel = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([listed]).check)
      XCTAssertEqual(channel, .testing)
      XCTAssertTrue(listed.availability.isSelectable)

      preference.select(.edge)
      let picked = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([listed]).check)
      XCTAssertEqual(picked, .edge)
    }

    func testAFailedEdgeCheckNeverFallsBackToNightly() async throws {
      // An Edge catalog that couldn't be fetched or verified says nothing
      // about this Mac. Edge stays the channel, so preparing it fetches again.
      let configuration = try Self.bundledConfiguration()
      for failure in [ReleaseChannelCheckFailure.network, .verification] {
        let preference = ReleaseChannelPreference(
          store: ReleaseChannelPreference.Store(), deviceIdentifier: "apple,j313")
        let channel = await preference.resolve(
          configuration: configuration, profileID: "fedora-kde",
          checkEdge: EdgeAnswers([EdgeCatalogCheck(availability: .checkFailed(failure))]).check)
        XCTAssertEqual(channel, .edge, "\(failure)")
      }
    }

    @MainActor
    func testCheckingAgainRedecidesOnlyADefaultFromAFailedCheck() async throws {
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j313")
      let offline = EdgeCatalogCheck(availability: .checkFailed(.network))
      let first = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([offline]).check)
      XCTAssertEqual(first, .edge)

      // Still unreachable: Edge stays, and can be decided again later.
      let stillOffline = await preference.checkAgain(
        profileID: "fedora-kde", read: { offline }, isCurrent: { true })
      XCTAssertEqual(stillOffline, .edge)
      // The same read that refreshes the menu decides the default.
      let again = await preference.checkAgain(
        profileID: "fedora-kde", read: { EdgeCatalogCheck(availability: .noRelease) },
        isCurrent: { true })
      XCTAssertEqual(again, .testing)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, profileID: "fedora-kde"), .testing)

      // A verified answer holds for the rest of this launch.
      let later = await preference.checkAgain(
        profileID: "fedora-kde", read: { Self.proven }, isCurrent: { true })
      XCTAssertNil(later)
      let resolved = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([Self.proven]).check)
      XCTAssertEqual(resolved, .testing)
    }

    @MainActor
    func testCheckingAgainForAProfileNoLongerOnScreenChangesNothing() async throws {
      // The person picked another distribution while Check Channels Again was
      // reading: the new profile's channel stands, and the old profile's
      // default isn't decided from the late answer either.
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j313")
      let offline = EdgeCatalogCheck(availability: .checkFailed(.network))
      _ = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([offline]).check)
      var onScreen = "fedora-kde"

      let stale = await preference.checkAgain(
        profileID: "fedora-kde",
        read: {
          onScreen = "arch-kde"
          return EdgeCatalogCheck(availability: .noRelease)
        },
        isCurrent: { onScreen == "fedora-kde" })

      XCTAssertNil(stale)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, profileID: "fedora-kde"), .edge)
      let unanswered = await preference.checkAgain(
        profileID: "fedora-kde", read: { nil }, isCurrent: { true })
      XCTAssertNil(unanswered)
    }

    func testAnExistingInstallationKeepsTheChannelItCameFrom() async throws {
      // Reset and Update Boot Loader act on an installation that is already
      // there: they read the channel recorded when it was installed, or
      // Nightly when none was, never this launch's Edge default.
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let newInstall = await preference.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([Self.proven]).check)
      XCTAssertEqual(newInstall, .edge)

      // A Nightly installation from an earlier installer records nothing.
      XCTAssertEqual(
        preference.resolve(configuration: configuration, existingInstallationChannel: nil),
        .testing)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, existingInstallationChannel: .testing),
        .testing)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, existingInstallationChannel: .edge),
        .edge)

      // A choice in the Release channel menu still wins.
      preference.select(.edge)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, existingInstallationChannel: .testing),
        .edge)
      preference.select(.testing)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, existingInstallationChannel: .edge),
        .testing)
    }

    func testAnExplicitChoiceWinsOverTheEdgeDefault() async throws {
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let edge = EdgeAnswers([Self.proven])
      func resolve() async -> ReleaseChannel {
        await preference.resolve(
          configuration: configuration, profileID: "fedora-kde", checkEdge: edge.check)
      }

      let decided = await resolve()
      XCTAssertEqual(decided, .edge)
      preference.select(.testing)
      let chosen = await resolve()
      XCTAssertEqual(chosen, .testing)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, profileID: "fedora-kde"), .testing)
      preference.select(nil)
      let cleared = await resolve()
      XCTAssertEqual(cleared, .edge)

      // Choosing Edge on a Mac it doesn't admit is still honoured; the
      // preparation then explains that Edge has nothing for this Mac.
      let other = ReleaseChannelPreference(
        store: ReleaseChannelPreference.Store(), deviceIdentifier: "apple,j313")
      other.select(.edge)
      let picked = await other.resolve(
        configuration: configuration, profileID: "fedora-kde",
        checkEdge: EdgeAnswers([EdgeCatalogCheck(availability: .noRelease)]).check)
      XCTAssertEqual(picked, .edge)
    }

    func testEachProfileIsDecidedByItsOwnEdgeCatalog() async throws {
      // Every distribution profile has its own signed Edge catalog. Today only
      // Fedora KDE's admits a Mac; the others are signed and empty.
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let catalogs: [(String, EdgeCatalogCheck, ReleaseChannel)] = [
        ("fedora-kde", Self.proven, .edge),
        ("arch-kde", EdgeCatalogCheck(availability: .noRelease), .testing),
        ("nixos-gnome", EdgeCatalogCheck(availability: .noRelease), .testing),
        ("arch-gnome", EdgeCatalogCheck(availability: .available), .testing),
      ]
      for (profileID, edge, expected) in catalogs {
        let channel = await preference.resolve(
          configuration: configuration, profileID: profileID,
          checkEdge: EdgeAnswers([edge]).check)
        XCTAssertEqual(channel, expected, profileID)
      }

      // Deciding one profile settles no other.
      XCTAssertNil(preference.resolve(configuration: configuration, profileID: "fedora-minimal"))
      XCTAssertEqual(
        preference.resolve(configuration: configuration, profileID: "fedora-kde"), .edge)
      XCTAssertEqual(
        preference.resolve(configuration: configuration, profileID: "arch-kde"), .testing)
    }

    func testTheWindowAndTheDownloadShareOneDecisionPerLaunch() async throws {
      // Edge's catalog is read once per profile; the window and the download
      // both get that answer even though a later read would differ.
      let configuration = try Self.bundledConfiguration()
      let window = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let download = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let edge = EdgeAnswers(
        [Self.proven, EdgeCatalogCheck(availability: .noRelease)], delay: .milliseconds(50))

      XCTAssertNil(window.resolve(configuration: configuration, profileID: "fedora-kde"))
      async let shown = window.resolve(
        configuration: configuration, profileID: "fedora-kde", checkEdge: edge.check)
      async let fetched = download.resolve(
        configuration: configuration, profileID: "fedora-kde", checkEdge: edge.check)
      let (windowChannel, downloadChannel) = await (shown, fetched)

      XCTAssertEqual(windowChannel, .edge)
      XCTAssertEqual(downloadChannel, .edge)
      let later = await download.resolve(
        configuration: configuration, profileID: "fedora-kde", checkEdge: edge.check)
      XCTAssertEqual(later, .edge)
      XCTAssertEqual(window.resolve(configuration: configuration, profileID: "fedora-kde"), .edge)
      XCTAssertEqual(edge.checkedDevices, ["apple,j700"])
    }

    func testBuildsAndDescriptorsOutsideTheEdgeRuleKeepTheirDefault() async throws {
      let bundled = try Self.bundledConfiguration()
      let legacy = InstallerReleaseConfiguration(
        channels: bundled.channels, defaultChannel: .testing, trustRoot: bundled.trustRoot,
        helperMachServiceName: bundled.helperMachServiceName,
        helperCodeSigningRequirement: bundled.helperCodeSigningRequirement,
        legacyDevelopmentChannel: true)
      let rcDefault = InstallerReleaseConfiguration(
        channels: bundled.channels, defaultChannel: .rc, trustRoot: bundled.trustRoot,
        helperMachServiceName: bundled.helperMachServiceName,
        helperCodeSigningRequirement: bundled.helperCodeSigningRequirement)
      let edge = EdgeAnswers([Self.proven, Self.proven, Self.proven])

      // Only the standard build profile knows this Mac's identifier.
      let unidentified = ReleaseChannelPreference(store: store, deviceIdentifier: nil)
      XCTAssertEqual(
        unidentified.resolve(configuration: bundled, profileID: "fedora-kde"), .testing)
      let developer = await unidentified.resolve(
        configuration: bundled, profileID: "fedora-kde", checkEdge: edge.check)
      XCTAssertEqual(developer, .testing)

      let neo = ReleaseChannelPreference(
        store: ReleaseChannelPreference.Store(), deviceIdentifier: "apple,j700")
      let legacyChannel = await neo.resolve(
        configuration: legacy, profileID: "fedora-kde", checkEdge: edge.check)
      XCTAssertEqual(legacyChannel, .testing)
      let rcChannel = await neo.resolve(
        configuration: rcDefault, profileID: "fedora-kde", checkEdge: edge.check)
      XCTAssertEqual(rcChannel, .rc)
      XCTAssertEqual(edge.checkedDevices, [])
    }

    func testTheWindowAndTheDownloadResolveTheChannelTheSameWay() throws {
      // A window-side fallback of its own once showed Stable while the
      // download fetched the bundled rc default.
      let app = Self.packageRoot.appendingPathComponent("Sources/AuroraAppleInstallerApp")
      var offenders = [String]()
      var resolvers = [String: Int]()
      let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
      while let file = files?.nextObject() as? URL {
        guard file.pathExtension == "swift" else { continue }
        let text = try String(contentsOf: file, encoding: .utf8)
        if text.contains("descriptorDefault") { offenders.append(file.lastPathComponent) }
        let count = text.components(separatedBy: "ReleaseChannelPreference().resolve(").count - 1
        if count > 0 { resolvers[file.lastPathComponent] = count }
      }
      XCTAssertEqual(offenders, [])
      // The app's two resolvers: a new installation's channel, which the
      // window and every new plan share, and an existing installation's.
      XCTAssertEqual(resolvers, ["LiveInstallerEnvironment.swift": 2])

      let scene = try String(
        contentsOf: app.appendingPathComponent("AuroraAppleInstallerApp.swift"), encoding: .utf8)
      let download = try String(
        contentsOf: app.appendingPathComponent("LiveInstallerEnvironment.swift"), encoding: .utf8)
      let page = try String(
        contentsOf: app.appendingPathComponent("OnePage/OnePageInstallerView.swift"),
        encoding: .utf8)
      // Wiring guard only; the resolver's behaviour is tested above.
      XCTAssertTrue(scene.contains(".task(id: selection.profileID)"))
      XCTAssertTrue(
        scene.contains(
          "let decided = await LiveInstallerEnvironment.releaseChannel(for: selection)"))
      XCTAssertTrue(
        scene.contains(
          "environment: LiveInstallerEnvironment(selection: selection), channel: channel,"))
      XCTAssertFalse(scene.contains("channel = ."))
      XCTAssertTrue(download.contains("Release/Profiles"))
      XCTAssertEqual(
        download.components(separatedBy: "await releaseChannel(configuration: configuration)")
          .count - 1, 2)
      XCTAssertTrue(download.contains("checkEdge: edgeCheck(configuration: configuration"))
      // Reset and Update Boot Loader read the installation's own channel, and
      // every installation records the channel it came from.
      XCTAssertTrue(
        download.contains(
          "existingInstallationChannel(configuration: configuration, "
            + "sourceIdentifier: preservedSource)"))
      XCTAssertTrue(download.contains("try Self.installationChannelStore().record("))
      // The window shows the channel the plan on screen reads.
      XCTAssertTrue(scene.contains("liveSession?.existingInstallationChannel ?? channel"))
      XCTAssertTrue(page.contains("session.existingInstallationChannel ?? channel"))
      // A Reset or boot loader update names its channel in the masthead.
      XCTAssertTrue(
        page.contains("existingInstallation: session.existingInstallationChannel != nil"))
      let masthead = try String(
        contentsOf: app.appendingPathComponent("InstallerMasthead.swift"), encoding: .utf8)
      XCTAssertTrue(
        masthead.contains(
          "PlainLanguage.mastheadChannelLabel("
            + "channel, existingInstallation: existingInstallation)"))
      // Check Channels Again: one read, and a stale answer is dropped.
      XCTAssertTrue(scene.contains("ReleaseChannelPreference().checkAgain("))
      XCTAssertTrue(scene.contains("selection.profileID == profileID && liveSession === session"))
      // Settling the default only fills in the channel a preparation already
      // waited for; it must not restart that preparation.
      XCTAssertTrue(page.contains("guard previous != nil, current != nil else { return }"))
    }

    /// Edge's catalog admits this Mac and lists it as family-qualified.
    private static let proven = EdgeCatalogCheck(availability: .available, qualifiesThisMac: true)

    private final class EdgeAnswers: @unchecked Sendable {
      private let lock = NSLock()
      private var answers: [EdgeCatalogCheck]
      private var devices = [String]()
      private let delay: Duration

      init(_ answers: [EdgeCatalogCheck], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
      }

      var checkedDevices: [String] { lock.withLock { devices } }

      var check: ReleaseChannelPreference.EdgeCheck {
        { [self] deviceIdentifier in
          if delay > .zero { try? await Task.sleep(for: delay) }
          return lock.withLock { () -> EdgeCatalogCheck in
            devices.append(deviceIdentifier)
            return answers.isEmpty
              ? EdgeCatalogCheck(availability: .checkFailed(.network)) : answers.removeFirst()
          }
        }
      }
    }

    private static func bundledConfiguration() throws -> InstallerReleaseConfiguration {
      try InstallerReleaseConfigurationLocator().load(
        from: packageRoot.appendingPathComponent("Release", isDirectory: true))
    }

    private static var packageRoot: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }
  }
#endif
