#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class Stage1CautionTests: XCTestCase {
    func testM1ProMaxAndUltraAreWarnedNotBlocked() {
      for board in ["j314s", "j316s", "j314c", "j316c", "j375c", "j375d", "j575d"] {
        XCTAssertNotNil(Stage1Caution.reason(for: "apple," + board), board)
      }
      for board in ["j274", "j413", "j616s", "j700"] {
        XCTAssertNil(Stage1Caution.reason(for: "apple," + board), board)
      }
    }

    func testTheAcknowledgementNamesTheRiskAndTheRecoveryIsSpelledOut() {
      let text = PlainLanguage.planAcknowledgement(resizesMacOS: false, stage1Caution: true)
      XCTAssertEqual(
        text,
        "I have a current backup and approve the disk layout above, and I understand Aurora may not start on this Mac."
      )
      XCTAssertEqual(
        PlainLanguage.planAcknowledgement(resizesMacOS: true, stage1Caution: false),
        PlainLanguage.planAcknowledgement(resizesMacOS: true))
      XCTAssertTrue(PlainLanguage.stage1CautionRecovery.contains("Always Use"))
      XCTAssertTrue(PlainLanguage.stage1CautionRecovery.contains("Erase Linux"))
      XCTAssertFalse(PlainLanguage.stage1CautionRecovery.contains("—"))
    }
  }
#endif
