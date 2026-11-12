#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class Stage1CautionTests: XCTestCase {
    func testOnlyTheUntriedBoardsAreWarnedAndNotBlocked() {
      let untried = [
        "j575d", "j614s", "j604", "j623", "j624", "j715", "j773g", "j614c", "j773s", "j575c",
        "j616c", "j813", "j873g", "j704", "j815", "j804", "j833ct",
      ]
      for board in untried {
        XCTAssertNotNil(Stage1Caution.reason(for: "apple," + board), board)
      }
      for board in ["k114c", "k114s", "k116c", "k116s"] {
        let reason = Stage1Caution.reason(for: "apple," + board)
        XCTAssertTrue(reason?.contains("untested on hardware") ?? false, board)
        XCTAssertTrue(reason?.contains("touchscreen") ?? false, board)
        XCTAssertFalse(reason?.contains("\u{2014}") ?? true, board)
      }
      let mini = Stage1Caution.reason(for: "apple,j773g")
      XCTAssertTrue(mini?.contains("Mac mini with M4") ?? false)
      XCTAssertTrue(mini?.contains("did not start Aurora") ?? false)
      XCTAssertTrue(mini?.contains("not expected to start yet") ?? false)
      XCTAssertFalse(mini?.contains("\u{2014}") ?? true)
      let others = [
        "j274", "j413", "j616s", "j713", "j700", "j314s", "j316s", "j314c", "j316c", "j375c",
        "j375d",
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
