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

    func testAnyMacTheProfilesEdgeCatalogAdmitsDefaultsToEdge() async throws {
      // The app names no model and no profile: a Mac gets Edge as soon as the
      // selected profile's verified Edge catalog admits it.
      let configuration = try Self.bundledConfiguration()
      for deviceIdentifier in ["apple,j700", "apple,j714s", "apple,j313"] {
        let preference = ReleaseChannelPreference(
          store: ReleaseChannelPreference.Store(), deviceIdentifier: deviceIdentifier)
        let edge = EdgeAnswers([.available])

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
          checkEdge: EdgeAnswers([availability]).check)
        XCTAssertEqual(channel, .testing, "\(availability)")
      }
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
          checkEdge: EdgeAnswers([.checkFailed(failure)]).check)
        XCTAssertEqual(channel, .edge, "\(failure)")
      }
    }

    func testCheckingAgainRedecidesOnlyADefaultFromAFailedCheck() async throws {
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j313")
      let edge = EdgeAnswers([.checkFailed(.network), .noRelease, .available])
      func resolve() async -> ReleaseChannel {
        await preference.resolve(
          configuration: configuration, profileID: "fedora-kde", checkEdge: edge.check)
      }

      let first = await resolve()
      XCTAssertEqual(first, .edge)
      XCTAssertTrue(preference.recheckFailedEdgeDefault(profileID: "fedora-kde"))
      let second = await resolve()
      XCTAssertEqual(second, .testing)
      // A verified answer holds for the rest of this launch.
      XCTAssertFalse(preference.recheckFailedEdgeDefault(profileID: "fedora-kde"))
      let third = await resolve()
      XCTAssertEqual(third, .testing)
      XCTAssertEqual(edge.checkedDevices.count, 2)
    }

    func testAnExplicitChoiceWinsOverTheEdgeDefault() async throws {
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let edge = EdgeAnswers([.available])
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
        checkEdge: EdgeAnswers([.noRelease]).check)
      XCTAssertEqual(picked, .edge)
    }

    func testEachProfileIsDecidedByItsOwnEdgeCatalog() async throws {
      // Every distribution profile has its own signed Edge catalog. Today only
      // Fedora KDE's admits a Mac; the others are signed and empty.
      let configuration = try Self.bundledConfiguration()
      let preference = ReleaseChannelPreference(store: store, deviceIdentifier: "apple,j700")
      let catalogs: [(String, ReleaseChannelAvailability, ReleaseChannel)] = [
        ("fedora-kde", .available, .edge),
        ("arch-kde", .noRelease, .testing),
        ("nixos-gnome", .noRelease, .testing),
      ]
      for (profileID, availability, expected) in catalogs {
        let channel = await preference.resolve(
          configuration: configuration, profileID: profileID,
          checkEdge: EdgeAnswers([availability]).check)
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
      let edge = EdgeAnswers([.available, .noRelease], delay: .milliseconds(50))

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
      let edge = EdgeAnswers([.available, .available, .available])

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
      // One resolver in the app, which the window and every preparation call.
      XCTAssertEqual(resolvers, ["LiveInstallerEnvironment.swift": 1])

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
        scene.contains("channel = await LiveInstallerEnvironment.releaseChannel(for: selection)"))
      XCTAssertTrue(
        scene.contains(
          "environment: LiveInstallerEnvironment(selection: selection), channel: channel,"))
      XCTAssertFalse(scene.contains("channel = ."))
      XCTAssertTrue(download.contains("Release/Profiles"))
      XCTAssertEqual(
        download.components(separatedBy: "await releaseChannel(configuration: configuration)")
          .count - 1, 2)
      XCTAssertTrue(download.contains("checkEdge: edgeCheck(configuration: configuration"))
      // Settling the default only fills in the channel a preparation already
      // waited for; it must not restart that preparation.
      XCTAssertTrue(page.contains("guard previous != nil else { return }"))
    }

    private final class EdgeAnswers: @unchecked Sendable {
      private let lock = NSLock()
      private var answers: [ReleaseChannelAvailability]
      private var devices = [String]()
      private let delay: Duration

      init(_ answers: [ReleaseChannelAvailability], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
      }

      var checkedDevices: [String] { lock.withLock { devices } }

      var check: ReleaseChannelPreference.EdgeCheck {
        { [self] deviceIdentifier in
          if delay > .zero { try? await Task.sleep(for: delay) }
          return lock.withLock {
            devices.append(deviceIdentifier)
            return answers.isEmpty ? .checkFailed(.network) : answers.removeFirst()
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
