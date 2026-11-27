#if os(macOS)
  import XCTest

  @testable import AuroraAppleInstallerTrustCore
  @testable import AuroraInstallerUXCore

  final class DeveloperModeTests: XCTestCase {
    func testRegularUsersSeeStableAndNightlyOnly() {
      XCTAssertEqual(DeveloperMode.menuChannels(isOn: false, inUse: .testing), [.stable, .testing])
      XCTAssertEqual(DeveloperMode.menuChannels(isOn: false, inUse: nil), [.stable, .testing])
      XCTAssertEqual(
        DeveloperMode.menuChannels(isOn: true, inUse: .testing), ReleaseChannel.allCases)
    }

    func testAnExistingEdgeInstallationStillShowsItsChannel() {
      XCTAssertEqual(
        DeveloperMode.menuChannels(isOn: false, inUse: .edge), [.stable, .testing, .edge])
    }

    func testTurningItOffDropsADeveloperChannelPick() {
      XCTAssertNil(DeveloperMode.choiceAfterLeaving(.edge))
      XCTAssertNil(DeveloperMode.choiceAfterLeaving(.rc))
      XCTAssertNil(DeveloperMode.choiceAfterLeaving(nil))
      XCTAssertEqual(DeveloperMode.choiceAfterLeaving(.stable), .stable)
      XCTAssertEqual(DeveloperMode.choiceAfterLeaving(.testing), .testing)
    }

    func testEdgeDecidesTheDefaultOnlyInDeveloperMode() {
      XCTAssertNil(DeveloperMode.edgeDecidingDevice("apple,j700", isOn: false))
      XCTAssertEqual(DeveloperMode.edgeDecidingDevice("apple,j700", isOn: true), "apple,j700")
    }

    func testAMacWithoutDeveloperModeReadsTheBundledDefault() async {
      // With no Mac to decide from, the Edge check never runs.
      let preference = ReleaseChannelPreference(
        store: ReleaseChannelPreference.Store(),
        deviceIdentifier: DeveloperMode.edgeDecidingDevice("apple,j700", isOn: false))
      XCTAssertEqual(preference.resolve(descriptorDefault: .testing), .testing)
    }

    func testTheChooserHidesDeveloperOnlyDistributions() {
      for distribution in DeveloperMode.developerOnlyDistributions {
        XCTAssertFalse(DeveloperMode.distributions(isOn: false).contains(distribution))
        XCTAssertTrue(DeveloperMode.distributions(isOn: true).contains(distribution))
      }
      XCTAssertEqual(DeveloperMode.distributions(isOn: true), AuroraDistribution.installable)
      let regular = AuroraInstallationSelection()
      XCTAssertEqual(DeveloperMode.selectionAfterLeaving(regular), regular)
    }

    func testAStubOverrideExistsOnlyInDeveloperMode() {
      let mode = DeveloperMode()
      let choice = StubOverrideChoice(version: "26.6", build: "25G83")
      mode.stubOverride = choice
      XCTAssertNil(mode.stubOverride)
      mode.isOn = true
      mode.stubOverride = choice
      XCTAssertEqual(mode.stubOverride, choice)
      XCTAssertEqual(choice.title, "macOS 26.6 (25G83)")
      mode.isOn = false
      XCTAssertNil(mode.stubOverride)
      mode.isOn = true
      XCTAssertNil(mode.stubOverride, "turning it off forgets the pick")
    }

    func testTheModeIsNeverSaved() {
      XCTAssertFalse(DeveloperMode().isOn)
      let defaults = UserDefaults.standard.dictionaryRepresentation().keys
      XCTAssertFalse(defaults.contains { $0.localizedCaseInsensitiveContains("developermode") })
    }
  }
#endif
