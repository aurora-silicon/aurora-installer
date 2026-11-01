#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest

  @testable import AuroraInstallerUXCore

  final class ExperimentalHardwareConsentTests: XCTestCase {
    func testOnlyTheTypedPhraseConsents() {
      XCTAssertNotNil(
        ExperimentalHardwareConsent(level: .fullSend, typed: "  Install on   untested hardware "))
      for typed in ["", "yes", "install on untested", "install on untested hardware now"] {
        XCTAssertNil(ExperimentalHardwareConsent(level: .bootloaderOnly, typed: typed), typed)
      }
    }

    func testTheWarningNamesTheRisksAndKeepsMacOS() {
      let text = PlainLanguage.experimentalWarning.joined(separator: " ")
      XCTAssertTrue(text.contains("Linux may not start"))
      XCTAssertTrue(text.contains("macOS Recovery"))
      XCTAssertTrue(text.contains("macOS stays untouched"))
      XCTAssertFalse(text.contains("—"))
      XCTAssertTrue(PlainLanguage.experimentalLevelDetail(.bootloaderOnly).contains("aura-proxy"))
    }
  }
#endif
