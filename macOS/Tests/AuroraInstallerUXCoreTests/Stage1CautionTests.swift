#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class Stage1CautionTests: XCTestCase {
    func testBoardsWithStartupCautionsAreWarnedAndNotBlocked() {
      let untried = [
        "j575d", "j614s", "j604", "j623", "j624", "j715", "j773g", "j614c", "j773s", "j575c",
        "j616c", "j516s", "j813", "j873g", "j704", "j815", "j804", "j833ct",
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
      let j516s = Stage1Caution.reason(for: "apple,j516s")
      XCTAssertTrue(j516s?.contains("16-inch MacBook Pro with M3 Pro") ?? false)
      XCTAssertTrue(j516s?.contains("needs macOS 27.2 or later") ?? false)
      XCTAssertTrue(j516s?.contains("not started Linux on one from the macOS 27.2 stub") ?? false)
      XCTAssertTrue(j516s?.contains("no GPU acceleration") ?? false)
      XCTAssertTrue(j516s?.contains("Aurora may not start") ?? false)
      XCTAssertFalse(j516s?.contains("\u{2014}") ?? true)
      let j813 = Stage1Caution.reason(for: "apple,j813")
      XCTAssertTrue(j813?.contains("13-inch MacBook Air with M5") ?? false)
      XCTAssertTrue(j813?.contains("needs macOS 27.2 or later") ?? false)
      XCTAssertTrue(j813?.contains("stops at the U-Boot prompt") ?? false)
      XCTAssertTrue(j813?.contains("Wi-Fi and Bluetooth firmware") ?? false)
      XCTAssertTrue(j813?.contains("display driver") ?? false)
      XCTAssertFalse(j813?.contains("has not used this installer on one") ?? true)
      XCTAssertFalse(j813?.contains("\u{2014}") ?? true)
      let j815 = Stage1Caution.reason(for: "apple,j815")
      XCTAssertTrue(j815?.contains("15-inch MacBook Air with M5") ?? false)
      XCTAssertTrue(j815?.contains("needs macOS 27.2 or later") ?? false)
      XCTAssertTrue(j815?.contains("separately built kernel") ?? false)
      XCTAssertTrue(j815?.contains("published downloads does not support") ?? false)
      XCTAssertTrue(j815?.contains("Wi-Fi and Bluetooth firmware") ?? false)
      XCTAssertFalse(j815?.contains("nobody on the Aurora team has one") ?? true)
      XCTAssertFalse(j815?.contains("\u{2014}") ?? true)
      let j704 = Stage1Caution.reason(for: "apple,j704")
      XCTAssertTrue(j704?.contains("14-inch MacBook Pro with M5") ?? false)
      XCTAssertTrue(j704?.contains("needs macOS 27.2 or later") ?? false)
      XCTAssertTrue(j704?.contains("contributor has installed it on the macOS 27.2 stub") ?? false)
      XCTAssertTrue(j704?.contains("development kernel") ?? false)
      XCTAssertTrue(j704?.contains("aurora-silicon/linux#2093") ?? false)
      XCTAssertTrue(j704?.contains("not in the kernel in the published downloads") ?? false)
      XCTAssertFalse(j704?.contains("The Aurora team has installed it") ?? true)
      XCTAssertFalse(j704?.contains("nobody on the Aurora team has one") ?? true)
      XCTAssertFalse(j704?.contains("\u{2014}") ?? true)
      let mini = Stage1Caution.reason(for: "apple,j773g")
      XCTAssertTrue(mini?.contains("Mac mini with M4") ?? false)
      XCTAssertTrue(mini?.contains("did not start Aurora") ?? false)
      XCTAssertTrue(mini?.contains("not expected to start yet") ?? false)
      XCTAssertFalse(mini?.contains("\u{2014}") ?? true)
      let studio = Stage1Caution.reason(for: "apple,j575c")
      XCTAssertTrue(studio?.contains("Mac Studio with M4 Max") ?? false)
      XCTAssertTrue(studio?.contains("restart the Mac once") ?? false)
      XCTAssertTrue(studio?.contains("Aurora may not start") ?? false)
      XCTAssertFalse(studio?.contains("not started Aurora on one yet") ?? true)
      XCTAssertFalse(studio?.contains("\u{2014}") ?? true)
      let others = [
        "j274", "j413", "j616s", "j713", "j700", "j314s", "j316s", "j314c", "j316c", "j375c",
        "j375d",
      ]
      for board in others {
        XCTAssertNil(Stage1Caution.reason(for: "apple," + board), board)
      }
    }

    func testT6050BoardsWarnAboutTheUnqualifiedInstallerComposition() {
      for board in ["j714c", "j714s", "j716c", "j716s", "j775c", "j775d", "j873s"] {
        let reason = Stage1Caution.reason(for: "apple," + board)
        XCTAssertTrue(reason?.contains("have not been qualified") ?? false, board)
        XCTAssertTrue(reason?.contains("Aurora may not start") ?? false, board)
        XCTAssertTrue(reason?.contains("recovery steps") ?? false, board)
        XCTAssertFalse(reason?.contains("nobody") ?? true, board)
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
