#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest
  @testable import AuroraAppleInstallerApp

  final class DistributionNoticeTests: XCTestCase {
    func testEveryDistributionSaysItIsNotFromItsUpstream() {
      for distribution in AuroraDistribution.allCases {
        let text = String(AuroraWelcomeView.notice(for: distribution).characters)
        XCTAssertTrue(text.contains("not provided"), distribution.rawValue)
        XCTAssertFalse(text.contains("]("), "markdown left unparsed for \(distribution.rawValue)")
      }
    }

    func testTheFedoraNoticeLinksToOfficialFedoraAndAttributesTheMark() {
      let notice = AuroraWelcomeView.notice(for: .fedora)
      let links = notice.runs.compactMap(\.link)
      XCTAssertEqual(links, [URL(string: "https://fedoraproject.org/")!])
      let text = String(notice.characters)
      XCTAssertTrue(text.contains("not provided or supported by the Fedora Project"))
      XCTAssertTrue(text.contains("Fedora is a registered trademark of Red Hat, Inc."))
    }

    func testOnlyNixOSKeepsItsUpstreamLogo() {
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let resources = root.appendingPathComponent("Resources")
      for removed in [
        "Fedora.png", "ArchLinuxARM.png", "BrandSources/Fedora.svg",
        "BrandSources/Fedora-Icon.svg", "BrandSources/ArchLinux.svg",
      ] {
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: resources.appendingPathComponent(removed).path),
          removed)
      }
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("NixOS.png").path))
    }
  }
#endif
