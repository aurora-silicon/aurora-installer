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

    func testTheAboutPanelCarriesTheTrademarkNotices() {
      let credits = TrademarkNotice.credits.string
      XCTAssertTrue(credits.contains("Fedora® is a registered trademark of Red Hat, Inc."))
      XCTAssertTrue(
        credits.contains("GNOME is a registered trademark or trademark of the GNOME Foundation"))
      XCTAssertTrue(credits.contains("KDE® is a registered trademark of KDE e.V."))
      XCTAssertTrue(credits.contains("not provided, supported or endorsed"))
    }

    func testOnlyTheAuroraLogoAndLicensedScreenshotsAreBundled() throws {
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let resources = root.appendingPathComponent("Resources")
      let images = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        .filter { $0.hasSuffix(".png") || $0.hasSuffix(".svg") }
      XCTAssertEqual(Set(images), ["AuroraLogo.png", "KDE-Desktop.png", "GNOME-Desktop.png"])
      let manifest =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: resources.appendingPathComponent("BrandSources/manifest.json")))
        as? [String: [String: String]]
      for screenshot in ["KDE-Desktop.png", "GNOME-Desktop.png"] {
        XCTAssertNotNil(manifest?[screenshot]?["license"], screenshot)
        XCTAssertNotNil(manifest?[screenshot]?["attribution"], screenshot)
      }
      let credits = TrademarkNotice.credits.string
      XCTAssertTrue(credits.contains("KDE Plasma screenshot by the KDE Community, CC BY 4.0"))
      XCTAssertTrue(credits.contains("GNOME screenshot by the GNOME Project, CC BY-SA 4.0"))
      let brand = try FileManager.default.contentsOfDirectory(
        atPath: resources.appendingPathComponent("BrandSources").path)
      XCTAssertEqual(brand, ["manifest.json"])
      let icons = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Packaging/DistributionIcons").path
      ).filter { $0.hasSuffix(".icns") }
      XCTAssertEqual(icons, ["aurora.icns"])
    }

    func testTheChooserNamesUpstreamsOnlyAsTheirTermsAllow() {
      // Fedora's Remix mark follows the brand ("<name> Fedora Remix"); Arch is
      // named as Asahi Alarm is, with no Arch mark; the notices say "based on".
      XCTAssertEqual(AuroraDistribution.fedora.title, "Aurora Fedora Remix")
      XCTAssertEqual(AuroraDistribution.arch.title, "Aurora Alarm")
      XCTAssertEqual(AuroraDistribution.nixos.title, "Aurora NixOS")
      XCTAssertEqual(AuroraDistribution.legacyTitles, ["Fedora Aurora Remix", "Aurora ALARM"])
    }
  }
#endif
