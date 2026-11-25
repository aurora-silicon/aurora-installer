import Foundation

/// Where a startup firmware upgrade goes on when Recovery's `bless` refuses
/// (RestoreImageStubUpgrade.Failure.needsMacOSBless): Preboot and System
/// are back as they were and the journal says so, and the main installer
/// approves the files from macOS with its own handoff bless (`bless
/// --setBoot --device ... --user ... --stdinpass`, which needs no paired
/// recoveryOS), then sends the person back to Recovery, which resumes after
/// the files it finds recorded.
///
/// The main installer side is not built yet: `next` is what it and Recovery
/// read from the journal, `recordMacOSBless` what it records once its bless
/// succeeded. It would write Preboot, System and also the Recovery image
/// before blessing (macOS's bless personalizes the group's Recovery from the
/// restore bundle, so the image should already be the new one), then record
/// `recoveryWritten: true`.
public enum StubUpgradeFallback {
  public enum Next: Equatable {
    /// Recovery runs (or goes on with) the upgrade from this phase.
    case recovery(RestoreImageStubUpgrade.Phase)
    /// A put-back was cut short: Recovery finishes it first.
    case finishPutBack
    /// Recovery couldn't approve the files: the main installer does, in macOS.
    case finishInMacOS
  }

  /// What the person sees when Recovery's bless refused.
  public static let message =
    "Aurora can't approve the new startup firmware from this Recovery. Restart into macOS, open the Aurora Installer and choose Finish startup firmware update; it will ask for the owner's password once, then return here."

  public static func next(_ journal: RestoreImageStubUpgrade.Journal?) -> Next {
    guard let journal else { return .recovery(.started) }
    if journal.state == "rolling-back" { return .finishPutBack }
    if journal.state == RestoreImageStubUpgrade.needsMacOSBlessState, journal.macOSBlessed != true {
      return .finishInMacOS
    }
    return .recovery(journal.phase)
  }

  public enum Failure: Error, Equatable {
    /// The journal isn't waiting for the main installer.
    case notWaiting
  }

  /// Records that the main installer wrote the files (`installed`, Preboot
  /// and System, and the Recovery image when `recoveryWritten`) and its
  /// bless approved them, with what that bless personalized. Recovery then
  /// resumes after them: at the Recovery image when it isn't written yet,
  /// else at enrolment.
  public static func recordMacOSBless(
    _ journal: inout RestoreImageStubUpgrade.Journal,
    installed: [RestoreImageStubFiles.Installed], recoveryWritten: Bool,
    recoveryPersonalized: Bool
  ) throws {
    guard journal.state == RestoreImageStubUpgrade.needsMacOSBlessState,
      journal.macOSBlessed != true
    else { throw Failure.notWaiting }
    journal.installed = installed
    journal.prebootChecked = true
    journal.prebootPersonalized = true
    journal.recoveryPersonalized = recoveryPersonalized || recoveryWritten
    journal.macOSBlessed = true
    journal.state = nil
    journal.phase = recoveryWritten ? .recoveryWritten : .blessed
  }
}
