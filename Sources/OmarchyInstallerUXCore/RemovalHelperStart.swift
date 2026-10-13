#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// How the removal sheet starts. Removal needs the helper even to look for
  /// an installation, so without one the sheet asks for the administrator
  /// account first, sets the helper up with it, and only then scans. The
  /// same password then approves the removal: one prompt for the action.
  public enum RemovalHelperStart: Equatable, Sendable {
    /// A helper is registered: scan right away, as before.
    case scan
    /// No helper, or one from another build, and this build can install its
    /// own: ask for the account first.
    case credentialsFirst
    /// No helper, and this build cannot install one.
    case unavailable
    /// The person switched the helper off in Login Items: ask for the
    /// account first and offer to turn it back on with it.
    case switchedOff
    /// This Mac model is refused outright; nothing privileged is set up.
    case blockedModel
    /// The helper is busy with another job; try again later.
    case busy

    /// - Parameter helper: the status from asking the helper itself, so a
    ///   switched-off helper shows as `.disabled`.
    /// - Parameter blockedModel: this Mac is a model the installer refuses;
    ///   it wins over every helper state, so no helper is ever installed.
    public init(helper: HelperDisplay, blockedModel: Bool = false) {
      if blockedModel {
        self = .blockedModel
        return
      }
      switch helper.status {
      case .current:
        self = .scan
      case .outdated:
        // Replace it first: a helper from another build may refuse this app.
        self = helper.canInstall ? .credentialsFirst : .scan
      case .disabled:
        self = helper.canInstall ? .switchedOff : .scan
      case .busy:
        self = .busy
      case .missing:
        self = helper.canInstall ? .credentialsFirst : .unavailable
      }
    }
  }

  /// What a lost connection after a submitted removal means. It counts as
  /// done only when the outcome shows on disk: the helper has retired
  /// completely (it deletes its job file, binary and state only after a
  /// completed removal) and the macOS container has reached its planned size
  /// after removal, by the helper's own completion tolerance. Anything less
  /// stays unknown, including a helper briefly absent while another build
  /// reinstalls it.
  public enum RemovalConnectionLoss: Equatable, Sendable {
    case completed
    case unknown

    /// - Parameters:
    ///   - helperRetired: the helper's job file, binary and state directory
    ///     are all gone, in two looks a moment apart.
    ///   - macOSContainerBytes: the macOS APFS container's size now, if known.
    ///   - macOSBytesAfter: its size once removal completes, from the plan.
    ///   - reclaimBytes: the space removal returns to it, from the plan.
    public init(
      helperRetired: Bool, macOSContainerBytes: UInt64?, macOSBytesAfter: UInt64,
      reclaimBytes: UInt64
    ) {
      guard helperRetired, let macOSContainerBytes, reclaimBytes > 0,
        macOSBytesAfter >= reclaimBytes
      else {
        self = .unknown
        return
      }
      // The helper's own test that macOS took the space back: within 1 MiB
      // of its planned size, and not beyond it.
      let tolerance: UInt64 = 1_048_576
      let reclaimed =
        macOSContainerBytes <= macOSBytesAfter
        && macOSBytesAfter - macOSContainerBytes <= tolerance
      self = reclaimed ? .completed : .unknown
    }
  }

  extension PlainLanguage {
    /// Shown when the reply was lost but the helper's retirement proves the
    /// removal completed.
    public static func removalCompletedWithoutReply(freeSpace: Bool) -> String {
      let result =
        freeSpace
        ? "The free space is now part of macOS."
        : "Omarchy and its data have been removed. The freed space is now part of macOS."
      return result
        + " The removal service finished and removed itself before this window heard back, as can happen if the Mac sleeps."
    }

    public static let removalCredentialsFirst =
      "To look for Omarchy on this Mac, enter your macOS administrator account. It sets up the removal service and approves the removal you’ll review next. macOS will show a notice that \(windowTitle) added a background item."
    public static let removalContinue = "Continue"
    public static let removalNotStarted =
      "The removal service didn’t answer, so removal didn’t start. No disk changes were made. Close this window and try again."
    public static let removalServiceBusy =
      "The removal service is busy with another request. Close this window and try again when it finishes. If it stays busy, an installation or removal may still be running, perhaps in another user’s session: let it finish, and don’t restart or shut down this Mac while it runs. No disk changes were made."
    public static let removalBlockedModel =
      "Removal is not supported on this Mac model. No disk changes were made."
    public static let removalSwitchedOff =
      "The removal service is switched off in Login Items, and it’s needed to look for Omarchy. Enter your macOS administrator account and choose Turn On & Continue to switch it back on, or switch it on in Login Items yourself and reopen this window."
    public static let removalTurnOnAndContinue = "Turn On & Continue"
    /// Builds that cannot install the helper, when the package has not.
    public static let removalServiceMissing =
      "The removal service isn’t available. Run the downloaded \(installerPackage) again, then try again. No disk changes were made."
    public static let removalServiceNotResponding =
      "The removal service didn’t respond. Close this window and try again. No disk changes were made."

    /// What the removal sheet says when setting up the helper failed.
    public static func removalHelperSetupMessage(for error: any Error) -> String {
      if let submission = error as? EngineXPCSubmissionError,
        submission == .machineOwnerCredentialsRejected
      {
        return
          "The macOS account or password was not accepted. Use a macOS administrator account. No disk changes were made."
      }
      switch error as? InstallerHelperSetupError {
      case .cancelled:
        return
          "The removal service wasn’t set up. Try again, and approve the macOS password prompt if it appears. No disk changes were made."
      case .switchedOff:
        return
          "The removal service is switched off. In System Settings, open General → Login Items & Extensions, switch it on under Allow in the Background, then try again. No disk changes were made."
      case .unavailable:
        return removalServiceMissing
      case .busy:
        return removalServiceBusy
      case .notAdministrator:
        return
          "This account isn’t a macOS administrator, and setting up the removal service needs one. Use an administrator account. No disk changes were made."
      case .failed, nil:
        return "The removal service couldn’t be set up. Try again. No disk changes were made."
      }
    }
  }
#endif
