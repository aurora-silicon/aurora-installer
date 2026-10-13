#if os(macOS)
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class RemovalHelperStartTests: XCTestCase {
    func testASwitchedOffHelperIsOfferedBackWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: true)),
        .switchedOff)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: false)), .scan)
    }

    func testABlockedModelNeverSetsUpTheHelper() {
      for status in [InstallerHelperStatus.current, .outdated, .disabled, .missing] {
        for canInstall in [true, false] {
          XCTAssertEqual(
            RemovalHelperStart(
              helper: HelperDisplay(status: status, canInstall: canInstall), blockedModel: true),
            .blockedModel, "\(status) canInstall=\(canInstall)")
        }
      }
      XCTAssertTrue(PlainLanguage.removalBlockedModel.hasSuffix("No disk changes were made."))
    }

    func testABusyHelperIsLeftToFinish() {
      for canInstall in [true, false] {
        XCTAssertEqual(
          RemovalHelperStart(helper: HelperDisplay(status: .busy, canInstall: canInstall)), .busy)
      }
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(for: InstallerHelperSetupError.busy).contains(
          "busy"))
    }

    func testALostReplyCountsAsRemovedOnlyWhenTheOutcomeShowsOnDisk() {
      let after: UInt64 = 500_000_000_000
      let reclaim: UInt64 = 100_000_000_000
      func loss(_ retired: Bool, _ container: UInt64?) -> RemovalConnectionLoss {
        RemovalConnectionLoss(
          helperRetired: retired, macOSContainerBytes: container, macOSBytesAfter: after,
          reclaimBytes: reclaim)
      }
      XCTAssertEqual(loss(true, after), .completed)
      // The helper's own tolerance: within 1 MiB of the planned size.
      XCTAssertEqual(loss(true, after - 1_048_576), .completed)
      XCTAssertEqual(loss(true, after - 1_048_577), .unknown)
      XCTAssertEqual(loss(true, after - reclaim / 4), .unknown, "most of the way is not done")
      XCTAssertEqual(loss(true, after + 4096), .unknown, "larger than planned is not this removal")
      // The space never came back: removal didn't finish, or never started.
      XCTAssertEqual(loss(true, after - reclaim), .unknown)
      // A helper still (or again) present leaves it unknown, whatever the disk.
      XCTAssertEqual(loss(false, after), .unknown)
      XCTAssertEqual(loss(true, nil), .unknown, "an unreadable container proves nothing")
      XCTAssertEqual(
        RemovalConnectionLoss(
          helperRetired: true, macOSContainerBytes: after, macOSBytesAfter: after,
          reclaimBytes: 0), .unknown)
      XCTAssertTrue(
        PlainLanguage.removalCompletedWithoutReply(freeSpace: false).hasPrefix(
          "Omarchy and its data have been removed."))
      XCTAssertTrue(PlainLanguage.removalNotStarted.contains("No disk changes were made."))
    }

    func testACurrentHelperScansRightAway() {
      for canInstall in [true, false] {
        XCTAssertEqual(
          RemovalHelperStart(helper: HelperDisplay(status: .current, canInstall: canInstall)),
          .scan)
      }
    }

    func testAnOutdatedHelperIsReplacedFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: true)),
        .credentialsFirst)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: false)), .scan)
    }

    func testAMissingHelperAsksForTheAccountFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: true)),
        .credentialsFirst)
    }

    func testAMissingHelperIsUnavailableWhenTheBuildCannotInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: false)),
        .unavailable)
    }

    func testEverySetupFailureSaysNothingChanged() {
      let errors: [any Error] = [
        EngineXPCSubmissionError.machineOwnerCredentialsRejected,
        InstallerHelperSetupError.cancelled,
        InstallerHelperSetupError.switchedOff,
        InstallerHelperSetupError.unavailable,
        InstallerHelperSetupError.notAdministrator,
        InstallerHelperSetupError.failed("launchd"),
        CocoaError(.fileNoSuchFile),
      ]
      for error in errors {
        XCTAssertTrue(
          PlainLanguage.removalHelperSetupMessage(for: error).hasSuffix(
            "No disk changes were made."), "\(error)")
      }
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(
          for: EngineXPCSubmissionError.machineOwnerCredentialsRejected
        ).contains("not accepted"))
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(for: InstallerHelperSetupError.switchedOff)
          .contains("Login Items"))
    }

    func testOnlyTheBuildThatCannotInstallTheHelperPointsAtThePackage() {
      XCTAssertTrue(PlainLanguage.removalServiceMissing.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(
        PlainLanguage.removalServiceNotResponding.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(PlainLanguage.removalCredentialsFirst.contains(PlainLanguage.installerPackage))
    }
  }
#endif
