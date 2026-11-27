#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class ExperimentalMacTests: XCTestCase {
    func testExperimentalBoardsAreMarkedAndOthersAreNot() {
      let experimental = [
        "j575d", "j614s", "j604", "j623", "j624", "j715", "j773g", "j614c", "j773s", "j575c",
        "j616c", "j516s", "j813", "j873g", "j704", "j815", "j804", "j833ct", "j714c", "j714s",
        "j716c", "j716s", "j775c", "j775d", "j873s", "k114c", "k114s", "k116c", "k116s",
      ]
      for board in experimental {
        XCTAssertTrue(ExperimentalMac.isExperimental("apple," + board), board)
        XCTAssertTrue(ExperimentalMac.isExperimental("Apple," + board.uppercased()), board)
      }
      XCTAssertEqual(ExperimentalMac.boards.count, experimental.count)
      let others = [
        "j274", "j413", "j616s", "j713", "j700", "j314s", "j316s", "j314c", "j316c", "j375c",
        "j375d",
      ]
      for board in others {
        XCTAssertFalse(ExperimentalMac.isExperimental("apple," + board), board)
      }
    }

    func testTheExperimentalNoteIsOneGenericLineWithTheIssuesLink() {
      XCTAssertEqual(PlainLanguage.experimentalTitle, "Experimental on this Mac")
      XCTAssertEqual(
        PlainLanguage.experimentalNote,
        "Support for this Mac is experimental and may be untested. Please report bugs or successes on GitHub Issues."
      )
      XCTAssertEqual(
        PlainLanguage.experimentalIssuesURL.absoluteString,
        "https://github.com/aurora-silicon/aurora-installer/issues")
      // No hardware details and no recovery steps in the box.
      for word in ["Always Use", "Erase Linux", "touchscreen", "GPU", "Wi-Fi", "27.2", "#"] {
        XCTAssertFalse(PlainLanguage.experimentalNote.contains(word), word)
      }
    }

    func testTheCheckboxKeepsItsSentenceAndTheExperimentalLineIsSeparate() {
      XCTAssertEqual(
        PlainLanguage.planAcknowledgement(resizesMacOS: false),
        "I have a current backup, and I approve this disk layout.")
      XCTAssertEqual(
        PlainLanguage.planExperimentalAcknowledgement,
        "I understand support for this Mac is experimental.")
      for resizes in [false, true] {
        let sentence = PlainLanguage.planAcknowledgement(resizesMacOS: resizes)
        XCTAssertFalse(sentence.contains("experimental"))
        XCTAssertFalse(sentence.contains("may not start"))
      }
    }
  }
#endif
