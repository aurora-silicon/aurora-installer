#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// Every user-visible string in the installer. Screens read from here so the
  /// wording can be reviewed in one place and unit-tested for completeness.
  public enum PlainLanguage {
    // MARK: Chrome

    public static let windowTitle = InstallerProductIdentity.appName
    /// The downloaded package people run again to repair the installation
    /// service, named as it is saved so it can't be mistaken for this app.
    public static let installerPackage = InstallerProductIdentity.appName + ".pkg"

    // MARK: Screen A — Check

    public static let checkSubheadline =
      "Aurora installs next to macOS. To switch between them, hold the power button when your Mac starts."
    public static let checkContinue = "Continue"
    public static let checkAgain = "Check again"
    public static let inspectingHeadline = "Checking this Mac…"
    public static let inspectingSubheadline =
      "Checking the Mac model, macOS version, power, FileVault, and free disk space."

    // MARK: Screen A2 — Existing install

    public static let existingInstallHeadline = "Linux is already on this Mac"
    public static let closeInstaller = "Close"

    // MARK: Partitions on this Mac

    public static let partitionsTitle = "Partitions on this Mac"
    public static let partitionsSubtitle =
      "To make room, erase a partition or shrink macOS."
    public static let partitionsAddHeading = "Where to install"
    public static let partitionsNoRoomTitle = "No room for another installation"
    public static let partitionsNotByAurora = "Not installed by Aurora"
    /// The removal service's scan found another installation than the row
    /// the person chose to erase.
    public static let removalTargetMismatch =
      "The removal service found a different installation than the one you chose. The disk wasn’t changed."

    // MARK: Screen B — Plan

    public static func allocationNotice(requestedBytes: UInt64, actualBytes: UInt64) -> String? {
      let formatter = DiskSizeInput()
      let requested = formatter.display(requestedBytes)
      let actual = formatter.display(actualBytes)
      // Disk alignment changes bytes without changing the whole GB the user chose.
      guard requested != actual else { return nil }
      return
        "Space for Aurora changed from \(requested) GB to \(actual) GB. Check the new size before you install."
    }

    public static let replanning = "Checking the new size…"
    /// A free-space plan leaves macOS its current size, so only a plan that
    /// shrinks macOS asks to approve a resize.
    public static func planAcknowledgement(resizesMacOS: Bool) -> String {
      resizesMacOS
        ? "I have a current backup, and I approve resizing the disk."
        : "I have a current backup, and I approve this disk layout."
    }
    /// Shown on the plan for an M1 Pro, M1 Max or M1 Ultra Mac, whose iBoot
    /// may refuse the current Stage 1. The owner can still install.
    public static let stage1CautionHeadline = "Aurora may not start on this Mac yet"
    public static let stage1CautionRecovery =
      "If the Mac shows “macOS needs to be reinstalled” or doesn’t start Aurora: shut it down, press and hold the power button until startup options appear, select Macintosh HD and choose Always Use. macOS starts as before. Then open this installer in macOS and use Erase Linux to remove the Aurora installation. macOS and its data are not changed by any of this."
    public static func planAcknowledgement(resizesMacOS: Bool, stage1Caution: Bool) -> String {
      stage1Caution
        ? String(planAcknowledgement(resizesMacOS: resizesMacOS).dropLast())
          + ", and I understand Aurora may not start on this Mac."
        : planAcknowledgement(resizesMacOS: resizesMacOS)
    }
    public static let planPreservedAcknowledgement =
      "I have a current backup, and I approve erasing Linux. Stage 1 and the partition sizes stay."
    public static let planInstall = "Install"
    public static let downloadingPackagesTitle = "Downloading Aurora"
    public static let encryptLinuxDiskTitle = "Encrypt the Aurora disk"
    public static let encryptLinuxDiskPassword =
      "Your Aurora password unlocks the disk. You create it the first time Aurora starts."
    public static let encryptLinuxDiskNoRecovery =
      "There’s no recovery key, so keep the password somewhere safe."
    public static let encryptionChoiceNotRecorded =
      "The encryption choice wasn’t saved, so Aurora will encrypt its disk at first boot."
    public static let encryptionOptOutRecorded =
      "Disk encryption is off, and that choice was saved."
    public static let encryptionChoiceUnconfirmed =
      "Encryption was saved, but the installer couldn’t confirm the disk was unmounted."
    public static let prefetchWaitingForNetwork = "Waiting for Wi-Fi or Ethernet…"
    public static let prefetchPaused = "Download paused"
    public static let prefetchVerifying = "Verifying download…"
    public static let prefetchFailed = "Download failed"
    public static let prefetchRetry = "Try again"

    public static func prefetchTitle(for state: PayloadPrefetchState) -> String {
      switch state {
      case .idle, .downloading:
        downloadingPackagesTitle
      case .waitingForUnmeteredNetwork:
        prefetchWaitingForNetwork
      case .paused:
        prefetchPaused
      case .verifying:
        prefetchVerifying
      case .verified:
        downloadingPackagesTitle
      case .failed:
        prefetchFailed
      case .cancelled:
        prefetchPaused
      }
    }

    public static func preparingStageTitle(
      _ stage: AssetProgressUpdate.Stage
    ) -> String {
      switch stage {
      case .fetchingCatalog: "Verifying the release…"
      case .downloading: "Downloading Aurora…"
      case .inspectingEngine: "Checking disk compatibility…"
      case .planning: "Planning the disk layout…"
      }
    }

    // MARK: Screen C — Authorize

    public static let authorizeTitle =
      "Approve installation"
    public static let authorizeRetryTitle = "Approve the Recovery step"
    public static let authorizeUsernameLabel = "User name"
    public static let authorizeChecking = "Checking your macOS account…"
    public static let authorizeStillWorking =
      "This can take a few minutes. Once your account is confirmed, the installer prepares Aurora’s files."
    public static let authorizePasswordLabel = "Password"
    public static let authorizeCancel = "Cancel"
    public static let authorizeRetryAction = "Authorize"
    public static let authorizeRejected =
      "The user name or password is incorrect."
    /// Shown on the sheet when authorizing will install the helper.
    public static let authorizeBackgroundItemNotice =
      "macOS may say \(windowTitle) added a background item. That is the helper that changes the disk. It removes itself when the installation or Erase finishes. Its recovery records stay."
    public static let authorizeHelperCancelled =
      "The installation service wasn’t set up. The disk wasn’t changed. Try again and approve the macOS password prompt."
    public static let authorizeHelperSwitchedOff =
      "The installation service is off in Login Items. Enter your password to turn it on, or turn it on in Login Items and try again."
    /// Shown on the sheet when the person switched the helper off.
    public static let authorizeHelperSwitchedOffNotice =
      "The installation service is off in Login Items, and the installer needs it to change the disk. Your password turns it back on. It’s removed with Aurora."
    public static let authorizeTurnOnAndInstall = "Turn on and install"
    public static let authorizeTurnOnAndRetry = "Turn on and continue"
    public static let openLoginItems = "Open Login Items"
    /// System Settings → General → Login Items & Extensions.
    public static let loginItemsSettingsURL = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    public static let openSoftwareUpdate = "Open Software Update"
    /// System Settings → General → Software Update.
    public static let softwareUpdateSettingsURL = URL(
      string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    public static let helperBeingReplacedHeadline = "The installation service is being updated"
    public static let helperBeingReplacedDetail =
      "Another copy of the installer is updating the service. The disk wasn’t changed. Try again in a moment."
    public static let helperRetiringHeadline = "The installation service was removed a moment ago"
    public static let helperRetiringDetail =
      "Aurora was removed, and its installation service is removing itself. The disk wasn’t changed. Try again in a moment. Your password sets the service up again."
    public static let authorizeNotAdministrator =
      "This account isn’t an administrator. Use a macOS administrator account."
    public static let authorizeHelperBusy =
      "The installation service is busy. The disk wasn’t changed. Try again when it finishes. If it stays busy, an installation or removal may be running, maybe for another user. Let it finish, and don’t restart or shut down this Mac."
    public static let authorizeHelperFailed =
      "The installation service couldn’t be set up. The disk wasn’t changed. Try again."

    // MARK: Confirmation dialogs (preserved verbatim)

    public static let recoveryRetryConfirmationTitle =
      "Continue the interrupted installation?"
    public static let recoveryRetryConfirmationBody =
      "The installer checks the plan, the disk and the saved files again, then continues in the space you approved. macOS isn’t resized again."
    public static let recoveryRetryConfirmationAction =
      "Continue"
    public static let partialInstallHeadline = "An unfinished installation is on this Mac"
    public static let partialInstallDetail =
      "An earlier installation stopped partway. Erase Linux deletes its startup container and gives that space, and any free space after it, back to macOS. Then you can install again."
    public static let startOverConfirmationTitle =
      "Start over?"
    public static let startOverConfirmationBody =
      "The installer stops this installation and lets you choose a system again. Its record and diagnostics are kept. The Linux partitions stay as this attempt left them, so Linux may not start until you install or reset it again."
    public static let startOverConfirmationAction = "Start over"
    public static let startOverFailed =
      "Couldn’t start over. The disk wasn’t changed. If the installation is still running, let it finish."
    public static let cancel = "Cancel"

    // MARK: Screen D — Install

    public static let installWarning =
      "Keep this Mac open and plugged in."
    public static let installDegraded =
      "Live progress isn’t available. The installer checks the result when it finishes."
    public static let installPreparing = "Preparing the installation…"
    /// What the Install screen lists: a few plain steps, the same from the
    /// first moment to the last. The checks before any disk change are the
    /// first two; the stages that change the disk follow.
    public static let installSteps = [
      "Getting ready", "Checking your Mac", "Making room on the disk", "Copying Aurora",
      "Preparing first startup",
    ]

    /// Reset Linux keeps Stage 1 and its partitions: one stage replaces Linux.
    public static let resetSteps = ["Getting ready", "Checking your Mac", "Replacing Linux"]

    /// The listed step a preparation check belongs to: the helper, the
    /// download and the account are getting ready; firmware, the restore
    /// image and the disk plan check this Mac.
    public static func installStep(forPreparationCheck check: Int) -> Int { check < 4 ? 0 : 1 }

    /// The number of listed steps before the first disk change.
    public static let installCheckSteps = 2

    /// The checks the installer makes before it changes anything, in the
    /// order they run. The Install screen groups them into its first two
    /// steps (`installStep(forPreparationCheck:)`).
    public static let installPreparationSteps = [
      "Checking the installer helper",
      "Handing the download to the helper",
      "Checking your macOS account",
      "Checking the Linux image",
      "Preparing firmware for this Mac",
      "Checking Apple’s restore image",
      "Planning the disk changes",
    ]

    /// The preparation step that a step the helper reported starting belongs
    /// to. A step after the preparation, or one this app doesn't know, such
    /// as one a newer helper adds, belongs to none.
    public static func installPreparationStep(forHelperStep name: String) -> Int? {
      switch name {
      case "credential_validation", "helper_import", "recovery_template", "restore_helper_check":
        1
      case "source_owner", "owner_device", "owner_snapshot", "owner_resolve", "owner_recheck": 2
      case "payload_preflight": 3
      case "firmware_preparation", "peripheral_inputs": 4
      case "apfs_preflight", "stub_files_preflight": 5
      case "os_partitions_preflight", "payload_images_preflight", "esp_files_preflight",
        "finishing_preflight":
        6
      default: nil
      }
    }

    /// The step the app reaches itself once the helper is ready: it hands
    /// the downloaded files to the helper.
    public static let installPreparationHandoffStep = 1

    public static func installPhaseTitle(forPhase phase: String?) -> String {
      switch phase {
      case "preflight": "Checking the disk…"
      case "existing_removal": "Removing the previous Aurora installation…"
      case "apfs_preparation": "Preparing disk space…"
      case "stub_and_esp": "Writing boot files…"
      case "awaiting_recovery": "Preparing final setup…"
      case "boot_policy": "Authorizing startup…"
      case "media_handoff": "Preparing installation media…"
      // A recorded journal phase name; it predates the Aurora name.
      case "omarchy_install": "Installing Aurora…"
      default: installPreparing
      }
    }

    public static func installPhaseTitle(forEvent event: String?) -> String? {
      switch event {
      case "existing_removal_started": "Removing the previous Aurora installation…"
      case "apfs_preparation_started": "Preparing disk space…"
      case "stub_and_esp_started": "Writing boot files…"
      case "recovery_handoff_started": "Preparing final setup…"
      default: nil
      }
    }

    public static func checkpointSummary(_ identifier: String) -> String {
      switch identifier {
      case "existing-install-removed": "Previous Aurora installation removed"
      case "apfs-target-prepared": "Disk space reserved for Aurora"
      case "stub-and-esp-installed": "Boot files written"
      case "recovery-handoff-prepared": "Ready to finish setup"
      case "preserved-install-written": "Linux and boot files replaced"
      default: "Other activity (\(identifier))"
      }
    }

    public static func eventSummary(_ name: String) -> String {
      switch name {
      case "existing_removal_started": "Started removing the previous Aurora installation"
      case "apfs_preparation_started": "Started preparing disk space"
      case "stub_and_esp_started": "Started writing boot files"
      case "recovery_handoff_started": "Started preparing final setup"
      case "preserved_reinstall_started": "Started resetting Linux"
      default: "Other activity (\(name))"
      }
    }

    // MARK: Screen E — Recovery

    public static let recoveryHeadline = "Finish setup in Recovery"
    public static let recoveryShutDown = "Shut down"
    public static let shutdownConfirmationTitle = "Shut down now?"
    public static let shutdownConfirmationBody =
      "Save your work first. When the Mac is off, hold the power button until “Loading startup options” appears. Choose Aurora, then Finish Installation, and sign in with your macOS account."
    public static let shutdownConfirmationAction = "Shut down"
    public static let mediaHeadline = "Connect the installation media"

    /// Numbered plain-language steps for the signed `requiredHumanSteps`
    /// tokens. Unknown tokens are surfaced rather than dropped.
    public static func recoverySteps(
      for requiredHumanSteps: [String]
    ) -> [RecoveryStep] {
      var steps = [RecoveryStep]()
      var number = 1
      func append(_ title: String, _ detail: String) {
        steps.append(RecoveryStep(number: number, title: title, detail: detail))
        number += 1
      }
      func enterRecovery() {
        append("Shut down your Mac", "Save your work first.")
        append(
          "Hold the power button",
          "When the Mac is off, hold the power button until “Loading startup options” appears."
        )
      }
      func authenticate() {
        append(
          "Finish installation",
          "Choose Aurora, then Finish Installation, and sign in with your macOS account.")
      }
      for token in requiredHumanSteps {
        switch token {
        case "enterOneTrueRecovery":
          enterRecovery()
        case "authenticateMachineOwner":
          authenticate()
        default:
          append(
            "Unknown Recovery step: \(token)",
            "Save the Installer Log and get help before you continue.")
        }
      }
      if steps.isEmpty {
        enterRecovery()
        authenticate()
      }
      return steps
    }

    // MARK: Boot loader update

    public static let bootLoaderUpdateAction = "Update boot loader"
    public static let bootLoaderUpdateMenuItem = "Update Boot Loader…"
    public static let bootLoaderUpdateRemedy =
      "In Partitions on this Mac, choose Update Boot Loader… from this installation’s ⋯ menu. Finish the update in Recovery, then reset it."
    /// Shaped like `resetSteps`: the two checks, then one stage for Recovery.
    public static let bootLoaderUpdateSteps = [
      "Getting ready", "Checking your Mac", "Preparing the boot loader",
    ]
    public static let bootLoaderUpdateReviewTitle = "Review the boot loader update"
    public static let bootLoaderUpdateReviewDetail =
      "Installs this release’s boot loader (Stage 1). Linux, its files, its partitions and the EFI partition stay as they are. You finish the update in Recovery with your macOS password."
    public static let bootLoaderUpdateAcknowledgement =
      "I’ll finish the update in Recovery."
    public static let bootLoaderUpdateHeadline = "Finish the update in Recovery"
    public static let bootLoaderUpToDateHeadline = "The boot loader is up to date"
    public static let bootLoaderUpToDateMessage =
      "This installation already has this release’s boot loader. The disk wasn’t changed."
    public static let bootLoaderShutdownBody =
      "Save your work first. When the Mac is off, hold the power button until “Loading startup options” appears. Choose Aurora, then enter your macOS password in Aurora Installer."

    /// Steps after the update is staged. Recovery enrolls the boot loader.
    public static func bootLoaderUpdateRecoverySteps(volumeName: String = "Aurora")
      -> [RecoveryStep]
    {
      [
        RecoveryStep(number: 1, title: "Shut down your Mac", detail: "Save your work first."),
        RecoveryStep(
          number: 2, title: "Hold the power button",
          detail:
            "When the Mac is off, hold the power button until “Loading startup options” appears."
        ),
        RecoveryStep(
          number: 3, title: "Update the boot loader",
          detail:
            "Choose \(volumeName). In Aurora Installer, click Update and enter your macOS password. Then restart."
        ),
      ]
    }

    static func bootLoaderUpdateState(unchanged: Bool) -> String {
      unchanged
        ? "The disk wasn’t changed."
        : "Linux, its partitions and the EFI partition weren’t changed. The installation’s Recovery files may have been."
    }

    // MARK: Screen F — Boot / completion

    public static let doneHeadline = "Aurora is installed"
    public static let startOver = "Start over"
    public static let downloadInstaller = "Download installer"
    public static let rcBadge = "Release candidate"
    public static let channelMenuTitle = "Release channel"
    public static let channelStable = "Stable"
    public static let channelRC = "Release candidate"
    public static let channelNightly = "Nightly"
    public static let channelEdge = "Edge"
    public static let channelEdgeNotPublished = "No release"
    public static let channelNoMacRelease = "No Mac release yet"
    public static let channelModelUnavailable = "Not available for this Mac"
    public static let channelUnreachable = "Couldn’t load"
    public static let channelUnverified = "Couldn’t verify"
    public static let channelMenuCheckAgain = "Check Channels Again"

    // MARK: Developer mode

    public static let developerModeMenuItem = "Developer Mode"
    public static let developerModeBadge = "Developer mode"
    public static let developerModeLeave = "Turn off"
    public static let developerModeBadgeHelp =
      "Shows Edge, release candidates and other expert options. Press Command-D to turn it off."
    public static let developerModeOnLog =
      "Developer mode is on. Edge, release candidates and expert options are shown."
    public static let developerModeOffLog =
      "Developer mode is off. Developer-only choices were reset to their defaults."
    public static let developerStubMenuTitle = "macOS Stub"
    public static let developerStubDefault = "Qualified Default"
    public static let stubOverrideRefusedHeadline = "This macOS stub can’t be used on this Mac"
    public static let stubOverrideRefusedRemedy =
      "Choose Qualified Default in Installation → macOS Stub, or start the installer without --stub-version."

    public static func badge(for channel: ReleaseChannel) -> String {
      switch channel {
      case .stable: channelStable
      case .rc: rcBadge
      case .testing: channelNightly
      case .edge: channelEdge
      }
    }

    /// The masthead's channel label. A new installation is labelled only when
    /// it reads Nightly. A Reset or boot loader update of an existing
    /// installation always names its channel, Edge included: it reads the
    /// channel recorded for that installation, or Nightly when none was, which
    /// may differ from the channel the installed system follows.
    public static func mastheadChannelLabel(
      _ channel: ReleaseChannel?, existingInstallation: Bool
    ) -> String? {
      guard let channel else { return nil }
      if existingInstallation { return badge(for: channel) }
      return channel == .testing ? channelNightly : nil
    }

    /// A channel menu item: the channel's name, then what its verified
    /// catalog offers this Mac when that is not simply "available".
    public static func channelMenuItem(
      _ channel: ReleaseChannel,
      availability: ReleaseChannelAvailability?
    ) -> String {
      let name = badge(for: channel)
      let state: String? =
        switch availability {
        case .none, .available: nil
        case .noRelease: channel == .edge ? channelEdgeNotPublished : channelNoMacRelease
        case .notPublished: channelEdgeNotPublished
        case .modelUnavailable: channelModelUnavailable
        case .checkFailed(.network): channelUnreachable
        case .checkFailed(.verification): channelUnverified
        }
      guard let state else { return name }
      return "\(name) (\(state))"
    }

    /// Whether the channel menu lets this item be chosen. The channel in use
    /// always stays chosen; one not yet checked, or whose check failed, can
    /// be chosen to try it.
    public static func channelMenuItemEnabled(
      _ channel: ReleaseChannel,
      selected: ReleaseChannel?,
      availability: ReleaseChannelAvailability?
    ) -> Bool {
      channel == selected || availability?.isSelectable ?? true
    }

    public static var doneVerifiedRows: [PlanFactRow] {
      doneVerifiedRows(profile: .current)
    }

    public static func doneVerifiedRows(profile: InstallerBuildProfile) -> [PlanFactRow] {
      [
        PlanFactRow(label: "Startup sequence", value: profile.startupSequence),
        PlanFactRow(
          label: "File verification",
          value: "Release verified, files written"
        ),
      ]
    }

    public static func installConfWarning(_ installConf: InstallConfHandoff) -> String? {
      switch installConf {
      case .recorded:
        nil
      case .notRecorded:
        encryptionChoiceNotRecorded
      case .unconfirmed(let encrypt):
        encrypt ? encryptionChoiceUnconfirmed : encryptionOptOutRecorded
      }
    }

    public static func nextActionMessage(
      _ action: InstallerNextAction,
      installConf: InstallConfHandoff = .recorded
    ) -> String {
      let base: String
      switch action {
      case .continueInstallation:
        base = "Your plan was accepted. The installation continues."
      case .enterRecovery:
        base =
          "Aurora’s files are in place. Finish setup in Recovery so this Mac can start Aurora."
      case .attachInstallationMedia:
        base = "Ready. Connect the installation media to continue."
      case .verifyInstalledSystem:
        base = "Installation is complete. Start Aurora and check that it works."
      case .manualRecovery:
        base = "The installation needs manual recovery before it can continue."
      }
      if let warning = installConfWarning(installConf) {
        return base + " " + warning
      }
      return base
    }

    // MARK: Blocked

    public static let blockedHeadline = "This Mac isn’t supported yet"
    public static let blockedSubheadline =
      "This Mac model has not been approved for this release."
    public static let blockedExplainer =
      "Each release supports the Macs it has device trees for. Newer models need a newer installer."
    public static let blockedBadge = "Not supported"
    public static let notReadyHeadline = "This Mac isn’t ready yet"
    public static let notReadyDetail =
      "The installer couldn’t confirm that this Mac meets the installation requirements."
    public static let supportedBadge = "Supported"

    /// "MacBook Pro 14-inch (M3, 2023) · Mac15,3 · apple,j504", leaving out
    /// what isn't known.
    public static func macDescription(
      deviceIdentifier: String,
      modelIdentifier: String? = nil
    ) -> String {
      [MacModelNames.name(for: deviceIdentifier), modelIdentifier, deviceIdentifier]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// The blocked-model card: names this Mac and, when the signed catalog
    /// could be read, the model families this release supports.
    public static func unsupportedModel(
      deviceIdentifier: String,
      modelIdentifier: String? = nil,
      supportedDeviceIdentifiers: [String]? = nil,
      technicalDetail: String? = nil
    ) -> FailureDisplay {
      let mac = macDescription(
        deviceIdentifier: deviceIdentifier, modelIdentifier: modelIdentifier)
      let remedy: String
      if let supported = supportedDeviceIdentifiers,
        let summary = MacModelNames.supportedFamiliesSummary(supported)
      {
        remedy =
          "Supported Macs (\(supported.count)): \(summary). "
          + blockedExplainer
      } else {
        remedy = blockedExplainer
      }
      return FailureDisplay(
        headline: blockedHeadline,
        plainDetail: "This release doesn’t support this Mac (\(mac)).",
        technicalDetail: technicalDetail,
        remedy: remedy,
        isBlockedModel: true
      )
    }

    /// A verified, signed catalog that admits no Mac: the channel exists but
    /// has nothing to install yet. Not a network or verification problem.
    public static func noMacRelease(technicalDetail: String? = nil) -> FailureDisplay {
      FailureDisplay(
        headline: "No Mac release on this channel yet",
        plainDetail:
          "This channel doesn’t offer Aurora for any Mac yet. Nothing was downloaded, and the disk wasn’t changed.",
        technicalDetail: technicalDetail,
        remedy: "Choose another channel from the Release channel menu, or check again later."
      )
    }

    public static func unsupportedModel(_ model: UnsupportedModelDisplay) -> FailureDisplay {
      unsupportedModel(
        deviceIdentifier: model.deviceIdentifier,
        modelIdentifier: model.modelIdentifier,
        supportedDeviceIdentifiers: model.supportedDeviceIdentifiers
      )
    }

    // MARK: Engine failures

    public static let replanAction = "Check available space"
    public static let engineDiagnosticsLocation =
      "To keep the details, open Details and choose Copy. A copy is also saved in ~/Library/Logs/\(EngineFailureUserLog.directoryName)."

    /// Plain wording for a typed engine failure. The disk-unchanged sentence
    /// appears only when the helper proved it from the installation journal.
    public static func engineFailure(
      _ notice: EngineFailureNotice,
      technicalDetail: String
    ) -> FailureDisplay {
      let unchanged = notice.diskUnchanged
      let diskState =
        unchanged
        ? "The disk wasn’t changed."
        : "The installer couldn’t confirm whether disk changes started."
      // The helper's summary names the check that stopped and why. It is
      // already one printable line; a blank one leaves only the disk state.
      let cause = notice.summary.isEmpty ? diskState : "\(notice.summary) \(diskState)"
      switch notice.reason {
      case .approvedSpaceChanged:
        // The native helper's summary carries the measured sizes and, when
        // snapshots hold the space, says so. Older summaries are technical.
        let measured = ApprovedSpaceShortfall.isSummary(notice.summary)
        let snapshots =
          ApprovedSpaceShortfall.namesSnapshots(notice.summary)
          ? "To get that space back, back up your Mac, then let macOS remove its local Time Machine snapshots (see Apple’s guide). Don’t delete system or update snapshots. "
          : ""
        return FailureDisplay(
          headline: "The space available for Aurora changed",
          plainDetail: measured
            ? "macOS now needs more of the disk than when you approved the plan, so the installer stopped. \(notice.summary) \(diskState)"
            : "The size you approved no longer fits, so the installer stopped. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "\(snapshots)Choose \(replanAction) to make a new plan, then review it."
            : "Copy the details and check Completed steps before you try again. \(engineDiagnosticsLocation)",
          replanAvailable: unchanged
        )
      case .diskLayoutChanged:
        return FailureDisplay(
          headline: "The disk changed after you approved the plan",
          plainDetail:
            "The disk no longer matches the plan you approved, so the installer stopped. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose \(replanAction) to make a new plan, then review it."
            : "Copy the details and check Completed steps before you try again. \(engineDiagnosticsLocation)",
          replanAvailable: unchanged
        )
      case .deviceUnsupported:
        return FailureDisplay(
          headline: blockedHeadline,
          plainDetail: notice.summary.isEmpty
            ? "The installer doesn’t support this Mac model. \(diskState)" : cause,
          technicalDetail: technicalDetail,
          remedy: blockedExplainer,
          isBlockedModel: true
        )
      case .planIntegrity:
        return FailureDisplay(
          headline: "The installation plan failed a safety check",
          plainDetail: notice.summary.isEmpty
            ? "The plan failed a safety check. \(diskState)" : cause,
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose Check again to make a new plan. \(engineDiagnosticsLocation)"
            : "Copy the details and check Completed steps before you try again. \(engineDiagnosticsLocation)"
        )
      case .firmwarePreparation:
        return FailureDisplay(
          headline: "Firmware preparation didn’t finish",
          plainDetail: cause,
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Check your internet connection and free space, then choose Check again. Finished downloads are reused."
            : "Copy the details and check Completed steps before you try again."
        )
      case .peripheralInputs:
        return FailureDisplay(
          headline: "This Mac’s calibration data couldn’t be prepared",
          plainDetail: cause,
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "This isn’t a network or disk space problem, and checking again won’t help. Copy the details and report them on GitHub Issues. \(engineDiagnosticsLocation)"
            : "Copy the details and check Completed steps before you try again."
        )
      case .macOSUpdateRequired:
        let required = EngineFailureReason.requiredMacOSVersion(inSummary: notice.summary)
        let needed =
          required.map { "macOS \($0), which this release needs" } ?? "this release needs"
        let update = required.map { "macOS \($0) or later" } ?? "the latest macOS"
        return FailureDisplay(
          headline: "Update macOS to install Aurora",
          plainDetail: "This Mac’s firmware is older than \(needed). \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Install \(update) in System Settings → General → Software Update, then open \(windowTitle) again."
            : "Copy the details and check Completed steps before you try again. \(engineDiagnosticsLocation)",
          actionURL: unchanged ? softwareUpdateSettingsURL : nil,
          actionTitle: unchanged ? openSoftwareUpdate : nil
        )
      case .networkUnavailable:
        return FailureDisplay(
          headline: "The download was interrupted",
          plainDetail:
            "The connection to Apple’s servers dropped during the download. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Check your internet connection, then choose Check again."
            : "Check your internet connection, then choose \(retry). The installer picks up where it stopped and reuses what it downloaded."
        )
      case .recoveryPreparation:
        return FailureDisplay(
          headline: "Recovery preparation didn’t finish",
          plainDetail: cause,
          technicalDetail: technicalDetail,
          remedy: !unchanged
            ? "Copy the details and check Completed steps before you try again."
            : NativeInstallerExecutor.isPrebootAdminListSummary(notice.summary)
              ? prebootAdminListRemedy : "Update the installer and choose Check again."
        )
      case .reinstallRequired:
        return FailureDisplay(
          headline: "Update this installation’s boot loader first",
          plainDetail: cause,
          technicalDetail: technicalDetail,
          remedy:
            "\(bootLoaderUpdateRemedy) Or choose Erase Linux and install again. \(engineDiagnosticsLocation)"
        )
      case .bootLoaderUpdateRefused:
        return FailureDisplay(
          headline: "The boot loader wasn’t updated",
          plainDetail: notice.summary.isEmpty
            ? bootLoaderUpdateState(unchanged: unchanged)
            : "\(notice.summary) \(bootLoaderUpdateState(unchanged: unchanged))",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Fix the problem above, then choose Check again and Update boot loader. \(engineDiagnosticsLocation)"
            : "Choose Check again, then Update boot loader again to finish. \(engineDiagnosticsLocation)"
        )
      case .startOverRequired:
        return FailureDisplay(
          headline: "This installation can’t be continued",
          plainDetail:
            "An older version of \(windowTitle) started it in a way this version can’t continue. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose Check again to start over."
            : "Erase the unfinished Linux installation, then choose Check again. \(engineDiagnosticsLocation)"
        )
      case .macOSSpaceRequired:
        return FailureDisplay(
          headline: "macOS needs more free space",
          plainDetail: MacOSFreeSpaceShortfall.isSummary(notice.summary)
            ? cause
            : "macOS doesn’t have enough free space for the installation. \(diskState)",
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "\(freeMacOSSpace) Then choose Check again. \(purgeableSpaceNote)"
            : "\(freeMacOSSpace) Then choose \(retry) to pick up where it stopped. \(purgeableSpaceNote)"
        )
      case .unclassified:
        return FailureDisplay(
          headline: "The installer stopped with an error",
          plainDetail: cause,
          technicalDetail: technicalDetail,
          remedy: unchanged
            ? "Choose Check again to start over. \(engineDiagnosticsLocation)"
            : "Copy the details and check Completed steps before you try again. \(engineDiagnosticsLocation)"
        )
      }
    }

    // MARK: Errors

    public static let retry = "Try again"

    static let freeMacOSSpace =
      "In macOS, empty the Trash and delete or move large files you don’t need."
    /// The helper counts only space macOS has already freed. Finder can also
    /// count purgeable space, such as iCloud files it can download again.
    static let purgeableSpaceNote =
      "Finder may count space macOS hasn’t freed yet, so free a little more than shown."
    /// macOS writes its Preboot list of Recovery administrators from its
    /// accounts, and rewrites it on request. Nothing of the installer's runs.
    static let prebootAdminListRemedy =
      "Have macOS rebuild that list. In Terminal, run sudo diskutil apfs updatePreboot / and enter your password, then choose Check again. If it still stops, save the Installer Log (Command-L) and share it on GitHub Issues."

    /// Planning found that macOS can't hold what the installation stages on
    /// it, before anything was approved.
    public static func macOSSpaceShortfall(
      _ shortfall: MacOSFreeSpaceShortfall, technicalDetail: String
    ) -> FailureDisplay {
      FailureDisplay(
        headline: "macOS needs more free space",
        plainDetail: "\(shortfall.summary) The disk wasn’t changed.",
        technicalDetail: technicalDetail,
        remedy:
          "\(freeMacOSSpace) Then choose Check again. \(purgeableSpaceNote)"
      )
    }

    /// Shown only by builds that cannot install the helper themselves, when
    /// the installer package has not put it in place.
    public static let helperNotInstalled =
      "The installer helper didn’t start. Quit Aurora Installer, open it again, and try again."

    public static let engineUnavailable =
      "This build is missing the required validation engine. Installation is unavailable."
    public static let engineIdentityMismatch =
      "The validation engine failed an identity check. Installation is unavailable."
    public static let releaseResourcesUnavailable =
      "This build is missing its release identity, so it can’t install."
    public static let planChangedBeforeApproval =
      "The plan changed. Review the new plan before you continue."
    public static let approvalUnavailable =
      "The approved plan or the installation service is gone. Review the plan again."
    public static let retryCheckpointUnavailable =
      "The checkpoint needed to retry the Recovery step is missing. The installation stays stopped."
    public static let inspectionRequired =
      "Complete the Mac and disk checks before continuing."

    /// Maps a thrown error to the four-part failure card the screens render.
    /// `technicalDetail` always preserves `String(describing:)` so nothing is
    /// lost behind the plain-language headline.
    public static func failure(
      for error: any Error,
      retryRecoveryAvailable: Bool = false
    ) -> FailureDisplay {
      let technical = String(describing: error)

      if let initial = error as? InstallerPreSubmissionFailure, !retryRecoveryAvailable {
        return FailureDisplay(
          headline: "Installation didn’t start",
          plainDetail: "Nothing was sent, and the disk wasn’t changed.",
          technicalDetail: String(describing: initial.underlying),
          remedy: "Open the latest installer and review the installation again.")
      }

      if retryRecoveryAvailable {
        // An interrupted download or a full macOS volume says so; Try again
        // continues from the last completed step once that is fixed.
        if case .engineFailed(let notice) = error as? EngineXPCSubmissionError,
          notice.reason == .networkUnavailable || notice.reason == .macOSSpaceRequired
        {
          let network = engineFailure(notice, technicalDetail: technical)
          return FailureDisplay(
            headline: network.headline, plainDetail: network.plainDetail,
            technicalDetail: network.technicalDetail, remedy: network.remedy,
            retryRecoveryAvailable: true)
        }
        return FailureDisplay(
          headline: "Installation paused",
          plainDetail:
            "Progress is saved. Aurora checks the disk and files before it continues.",
          technicalDetail: technical,
          remedy:
            "Enter the macOS password you used before to continue.",
          retryRecoveryAvailable: true
        )
      }

      if let submission = error as? EngineXPCSubmissionError {
        switch submission {
        case .machineOwnerCredentialsRejected:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail:
              "The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Enter the name and password of a macOS administrator."
          )
        case .recoveryAuthorizationFailed:
          return FailureDisplay(
            headline: "The Recovery step didn’t finish",
            plainDetail:
              "The disk and files are ready. The Recovery step still needs your approval.",
            technicalDetail: technical,
            remedy: "Choose Try again to redo only the Recovery step."
          )
        case .helperUnresponsive:
          return FailureDisplay(
            headline: "The installation service isn’t responding",
            plainDetail:
              "Installation hasn’t started.",
            technicalDetail: technical,
            remedy: "Quit \(windowTitle), open it again, and try again."
          )
        case .connectionFailed:
          return FailureDisplay(
            headline: "Lost connection to the installation service",
            plainDetail:
              "Disk changes may have started. The result isn’t known yet.",
            technicalDetail: technical,
            remedy:
              "Keep your Mac plugged in. Copy the details and check Completed steps before you try again."
          )
        case .engineFailed(let notice):
          return engineFailure(notice, technicalDetail: technical)
        case .helperRejected(let domain, let code):
          let replaced = ClosedEngineHelperError.beingReplaced as NSError
          if domain == replaced.domain, code == replaced.code {
            return FailureDisplay(
              headline: PlainLanguage.helperBeingReplacedHeadline,
              plainDetail: PlainLanguage.helperBeingReplacedDetail,
              technicalDetail: technical
            )
          }
          let retiring = ClosedEngineHelperError.retiring as NSError
          if domain == retiring.domain, code == retiring.code {
            return FailureDisplay(
              headline: PlainLanguage.helperRetiringHeadline,
              plainDetail: PlainLanguage.helperRetiringDetail,
              technicalDetail: technical
            )
          }
          let busy = ClosedEngineHelperError.busy as NSError
          if domain == busy.domain, code == busy.code {
            return FailureDisplay(
              headline: "An installation may already be running",
              plainDetail:
                "Keep your Mac on. Check the running installation’s record before you start another.",
              technicalDetail: technical
            )
          }
          return FailureDisplay(
            headline: "The installation service couldn’t complete the request",
            plainDetail:
              "The service returned an error. Disk changes may have started.",
            technicalDetail: technical,
            remedy:
              "Copy the details and check Completed steps before you try again."
          )
        default:
          return FailureDisplay(
            headline: "The installation result is unknown",
            plainDetail:
              "The installation service didn’t return a result. Disk changes may have started.",
            technicalDetail: technical,
            remedy:
              "Copy the details and check Completed steps before you try again."
          )
        }
      }

      if let job = error as? InstallerJobError {
        return savedInstallationFailure(job, technicalDetail: technical)
      }

      if let helper = error as? ClosedEngineHelperError {
        switch helper {
        case .beingReplaced:
          return FailureDisplay(
            headline: PlainLanguage.helperBeingReplacedHeadline,
            plainDetail: PlainLanguage.helperBeingReplacedDetail,
            technicalDetail: technical
          )
        case .retiring:
          return FailureDisplay(
            headline: PlainLanguage.helperRetiringHeadline,
            plainDetail: PlainLanguage.helperRetiringDetail,
            technicalDetail: technical
          )
        case .busy:
          return FailureDisplay(
            headline: "An installation may already be running",
            plainDetail:
              "Keep your Mac on. Check the running installation before you try again.",
            technicalDetail: technical
          )
        case .invalidMachineOwnerCredentials:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail: "The disk wasn’t changed.",
            technicalDetail: technical
          )
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        default:
          return FailureDisplay(
            headline: "The installation service reported an error",
            plainDetail:
              "Check Completed steps to see what finished.",
            technicalDetail: technical,
            remedy:
              "Copy the details and check Completed steps before you try again."
          )
        }
      }

      if let allocation = error as? InstallerAllocationRecommendationError {
        switch allocation {
        case .snapshotConstrained(let constraint):
          let detail =
            constraint == .timeMachine
            ? "A local Time Machine snapshot limits how far macOS can shrink."
            : "An APFS snapshot limits how far macOS can shrink. It isn’t a Time Machine snapshot."
          let remedy =
            constraint == .timeMachine
            ? "Back up your Mac first. Local snapshots are restore points on this disk, not your backups. Wait for macOS to clear them, or follow Apple’s guide. Then choose Check again."
            : "Back up your Mac first. Let any pending macOS update finish, restart, then choose Check again. Don’t delete system or update snapshots."
          return FailureDisplay(
            headline: "Snapshots limit the space for Aurora",
            plainDetail:
              "\(detail) Free space in macOS isn’t always space that can become a partition. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "\(remedy) The installer never deletes snapshots.",
            actionURL: URL(string: "https://support.apple.com/en-us/102154"),
            actionTitle: "Open Apple’s guide"
          )
        case .insufficientSpace(let required, let available):
          let shortfall = bytesRoundedUp(required - min(required, available))
          return FailureDisplay(
            headline:
              "Free up at least \(shortfall) to install Aurora",
            plainDetail:
              "Aurora needs \(bytes(required)). Only \(bytes(available)) can be freed safely. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Delete files you don’t need in macOS and empty the Trash, then choose Check again. If an old Linux installation is on this Mac, Erase Linux gives its space back."
          )
        case .noEligibleCandidate:
          return FailureDisplay(
            headline: "There isn’t enough usable disk space",
            plainDetail:
              "The installer couldn’t find space that meets its requirements. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Back up your Mac first. Check free storage and pending macOS updates, then choose Check again. Local snapshots may also limit resizing."
          )
        }
      }
      if let shortfall = error as? MacOSFreeSpaceShortfall {
        return macOSSpaceShortfall(shortfall, technicalDetail: technical)
      }
      if error is URLError {
        return FailureDisplay(
          headline: "The network connection failed",
          plainDetail: "The installer couldn’t reach the server.",
          technicalDetail: technical, remedy: "Check your internet connection, then try again.")
      }

      if let preparation = error as? InstallerPlanPreparationError {
        switch preparation {
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        case .preservedReinstallUnavailable:
          return FailureDisplay(
            headline: "This installation can’t be reset",
            plainDetail:
              "The startup setup and disk weren’t changed.",
            technicalDetail: technical,
            remedy: "Choose a system, pick the one that’s installed, then check again."
          )
        case .targetUnavailable:
          return FailureDisplay(
            headline: "The space you chose changed",
            plainDetail:
              "The disk no longer matches the last check. The installer didn’t change it.",
            technicalDetail: technical,
            remedy: "Check again, then choose where to install."
          )
        case .macOSUpdateRequired(let version):
          return FailureDisplay(
            headline: "Update macOS to install Aurora",
            plainDetail:
              "This Mac’s firmware is older than macOS \(version), which this release needs. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Install macOS \(version) or later in System Settings → General → Software Update, then open \(windowTitle) again.",
            actionURL: softwareUpdateSettingsURL,
            actionTitle: openSoftwareUpdate
          )
        case .firmwareBelowRelease(let version, let check, let detected, let required):
          return FailureDisplay(
            headline: "This Mac’s \(check) is older than Aurora needs",
            plainDetail:
              "This Mac’s \(check) is \(detected). Aurora needs \(required) or later. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Install any update in System Settings → General → Software Update, then open \(windowTitle) again. If there’s none, reinstall macOS \(version) from Recovery.",
            actionURL: softwareUpdateSettingsURL,
            actionTitle: openSoftwareUpdate
          )
        case .firmwareUnavailable:
          return FailureDisplay(
            headline: "No boot firmware fits this Mac",
            plainDetail:
              "The release has no boot firmware for this Mac’s macOS and firmware versions. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Update macOS, then choose Check again."
          )
        case .releaseLacksMachOStartup:
          return FailureDisplay(
            headline: blockedHeadline,
            plainDetail:
              "This release doesn’t include the startup software this Mac needs yet. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy:
              "Check for a newer \(windowTitle).",
            isBlockedModel: true
          )
        case .stubOverrideRefused(let reason):
          return FailureDisplay(
            headline: stubOverrideRefusedHeadline,
            plainDetail: reason + " The disk wasn’t changed.",
            technicalDetail: technical,
            remedy: stubOverrideRefusedRemedy
          )
        case .firmwareArchiveUnsupported(let version):
          return FailureDisplay(
            headline: "This installer can’t install on this Mac yet",
            plainDetail:
              "This Mac needs boot firmware from macOS \(version), which this installer can’t unpack yet. The disk wasn’t changed.",
            technicalDetail: technical,
            remedy: "Check for a newer \(windowTitle)."
          )
        default:
          return FailureDisplay(
            headline: "Couldn’t make an installation plan",
            plainDetail:
              "Nothing was installed.",
            technicalDetail: technical,
            remedy: "Open Details, then choose Check again."
          )
        }
      }

      if let preparation = error as? InstallerAssetPreparationError {
        switch preparation {
        case .installerOutdated(let current, let minimum, let downloadURL):
          return FailureDisplay(
            headline: "This installer is out of date",
            plainDetail:
              "This release needs installer \(minimum) or later. You have \(current).",
            technicalDetail: technical,
            remedy:
              "Download the latest \(windowTitle) and open it.",
            actionURL: downloadURL,
            actionTitle: downloadInstaller
          )
        case .hostBlocked(let reason):
          return FailureDisplay(
            headline: "This Mac isn’t supported yet",
            plainDetail: reason,
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .unsupportedDevice(let identifier):
          return unsupportedModel(deviceIdentifier: identifier, technicalDetail: technical)
        case .noMacRelease:
          return noMacRelease(technicalDetail: technical)
        case .notInCatalog(let identifier, let model, let supported):
          return unsupportedModel(
            deviceIdentifier: identifier,
            modelIdentifier: model,
            supportedDeviceIdentifiers: supported,
            technicalDetail: technical
          )
        case .deliveryMetadataUnavailable:
          return FailureDisplay(
            headline: "Installation files aren’t listed for this Mac",
            plainDetail:
              "The release supports this Mac but lists no installation files for it. Installation can’t continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        }
      }

      if let staging = error as? ArtifactStageError {
        switch staging {
        case .digestMismatch, .sizeMismatch, .destinationConflict,
          .partSizeSumMismatch:
          return FailureDisplay(
            headline: "An installation file couldn’t be verified",
            plainDetail:
              "A downloaded file failed verification. Installation can’t continue.",
            technicalDetail: technical,
            remedy: "Choose Check again to download it again."
          )
        default:
          return FailureDisplay(
            headline: "The installation files couldn’t be prepared",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Open Details, then try again."
          )
        }
      }

      if let configuration = error as? InstallerReleaseConfigurationError {
        switch configuration {
        case .edgeAlphaUnavailable:
          return FailureDisplay(
            headline: "Edge isn’t available yet",
            plainDetail: "There’s no Edge release yet. Nothing was installed.",
            technicalDetail: technical,
            remedy: "Choose Nightly from the Release channel menu, or check Edge again later."
          )
        case .releaseResourcesUnavailable:
          return FailureDisplay(
            headline: "This build can’t install",
            plainDetail: releaseResourcesUnavailable,
            technicalDetail: technical
          )
        case .unexpectedHTTPStatus(404):
          return FailureDisplay(
            headline: "This channel’s release list wasn’t found",
            plainDetail:
              "The release server has no release list for this channel. Nothing was installed.",
            technicalDetail: technical,
            remedy:
              "Check again later, or choose another channel from the Release channel menu."
          )
        case .unexpectedHTTPStatus:
          return FailureDisplay(
            headline: "The release server returned an error",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Open Details, then try again."
          )
        case .catalogUnreachable:
          return FailureDisplay(
            headline: "The release list couldn’t be downloaded",
            plainDetail:
              "The installer couldn’t reach the release server. Nothing was installed.",
            technicalDetail: technical,
            remedy:
              "Check your internet connection and try again, or choose another channel from the Release channel menu."
          )
        case .invalidCatalogEnvelope, .invalidCatalogSignature,
          .invalidCatalogChannel, .oversizedDocument:
          return FailureDisplay(
            headline: "The release couldn’t be verified",
            plainDetail:
              "The server’s answer failed verification. Installation can’t continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        default:
          return FailureDisplay(
            headline: "The release is unavailable",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Open Details, then try again."
          )
        }
      }

      if case SupportCatalogSequenceError.belowBuildFloor = error {
        return FailureDisplay(
          headline: "This installer is newer than the release server",
          plainDetail:
            "This channel’s release list is older than this installer expects. The server hasn’t caught up yet. Nothing was installed.",
          technicalDetail: technical,
          remedy: "Check again later, or choose another channel from the Release channel menu."
        )
      }

      if case SupportCatalogError.nativeEngineRequired = error {
        return FailureDisplay(
          headline: "This channel isn’t ready for this installer",
          plainDetail:
            "Its release list is for an older installer, so this version can’t use it. Nothing was installed.",
          technicalDetail: technical,
          remedy: "Choose another channel from the Release channel menu, or check again later."
        )
      }

      if let catalog = error as? SupportCatalogError {
        return FailureDisplay(
          headline: "The release list couldn’t be verified",
          plainDetail:
            "Its signature or version doesn’t match what this installer needs. Installation can’t continue.",
          technicalDetail: String(describing: catalog),
          remedy: "Try again later, or download the latest installer."
        )
      }

      return FailureDisplay(
        headline: "Something went wrong",
        plainDetail:
          "Check Completed steps before you continue.",
        technicalDetail: technical,
        remedy:
          "If the installation started, keep your Mac plugged in and check Completed steps before you try again."
      )
    }

    /// A saved installation the app couldn't look up or use. It names what
    /// happened instead of falling back to a generic error.
    private static func savedInstallationFailure(
      _ error: InstallerJobError, technicalDetail: String
    ) -> FailureDisplay {
      switch error {
      case .unavailable:
        FailureDisplay(
          headline: "The installer helper isn’t answering",
          plainDetail:
            "Your saved installation is safe. After an update, the helper can take a moment to start.",
          technicalDetail: technicalDetail,
          remedy: "Quit \(windowTitle) and open it again.")
      case .identityMismatch:
        FailureDisplay(
          headline: "The saved installation doesn’t match this installer",
          plainDetail:
            "It belongs to another installer or release channel. The disk wasn’t changed.",
          technicalDetail: technicalDetail,
          remedy: "Use the installer and channel that started it.")
      case .interrupted:
        FailureDisplay(
          headline: "The installer helper stopped before the installation finished",
          plainDetail: error.errorDescription ?? "",
          technicalDetail: technicalDetail,
          remedy:
            "Keep your Mac plugged in, and check Completed steps before you continue."
        )
      case .invalidRequest, .unsafeState, .historyFull, .notAdmitted:
        FailureDisplay(
          headline: "The saved installation couldn’t be used",
          plainDetail: error.errorDescription ?? "",
          technicalDetail: technicalDetail,
          remedy: "Copy the details and check Completed steps before you try again.")
      }
    }

    // MARK: Formatting

    /// Whole-number sizes: "137 GB", "18 MB". Decimal places only add noise
    /// at the scale people choose disk space in.
    public static func bytes(_ value: UInt64) -> String {
      let gb: Double = 1_000_000_000
      let mb: Double = 1_000_000
      let kb: Double = 1_000
      let count = Double(value)
      if count >= gb { return "\(Int((count / gb).rounded())) GB" }
      if count >= mb { return "\(Int((count / mb).rounded())) MB" }
      if count >= kb { return "\(Int((count / kb).rounded())) KB" }
      return "\(value) bytes"
    }

    /// Whole gigabytes, rounded up: for amounts the person must free, where
    /// rounding down would ask for too little.
    public static func bytesRoundedUp(_ value: UInt64) -> String {
      let gb: UInt64 = 1_000_000_000
      return "\(value / gb + (value % gb == 0 ? 0 : 1)) GB"
    }

    public static func shortDigest(_ value: String) -> String {
      let body =
        value.hasPrefix("sha256:")
        ? String(value.dropFirst(7)) : value
      guard body.count > 20 else {
        return body
      }
      return String(body.prefix(8)) + "…" + String(body.suffix(8))
    }
  }
#endif
