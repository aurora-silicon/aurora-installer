#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class Stage1CautionTests: XCTestCase {
    func testOnlyTheUntriedM3UltraJ614sAndOLEDMacBookProsAreWarnedAndNotBlocked() {
      XCTAssertNotNil(Stage1Caution.reason(for: "apple,j575d"))
      XCTAssertNotNil(Stage1Caution.reason(for: "apple,j614s"))
      for board in ["k114c", "k114s", "k116c", "k116s"] {
        let reason = Stage1Caution.reason(for: "apple," + board)
        XCTAssertTrue(reason?.contains("untested on hardware") ?? false, board)
        XCTAssertTrue(reason?.contains("touchscreen") ?? false, board)
        XCTAssertFalse(reason?.contains("—") ?? true, board)
      }
      let others = [
        "j274", "j413", "j616s", "j700", "j314s", "j316s", "j314c", "j316c", "j375c", "j375d",
      ]
      for board in others {
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
