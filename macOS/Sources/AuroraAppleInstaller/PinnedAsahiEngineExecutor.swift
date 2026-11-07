#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  public enum PinnedAsahiEngineExecutionError:
    Error, Equatable, Sendable
  {
    case privilegeRequired
    /// A native stage stopped. The report's notice is the only part that may
    /// leave the privileged helper; the redacted detail stays in its root-only
    /// diagnostics.
    case engineFailed(EngineFailureReport)
    case recoveryAuthorizationFailed
    case restoreImageUnavailable
    case nativeReinstallUnavailable
    case unsafeTranscript
  }

  /// Runs an imported, approved installation with the helper's built-in
  /// native engine. Nothing here launches an interpreter or an engine archive:
  /// fresh installation, Recovery handoff and its retry, and preserved
  /// reinstallation are all compiled into the helper.
  public struct PinnedAsahiEngineExecutor:
    ImportedEngineHandoffExecuting, Sendable
  {
    public static let maximumTranscriptBytes: Int64 = 8_388_608

    private let effectiveUserID: @Sendable () -> uid_t
    private let expectedFileOwnerID: @Sendable () -> uid_t
    private let restoreImageRequirement: String?
    private let verifyRestoreImage: @Sendable (URL, String) throws -> Void
    private let firmwarePreparer: any NativeFirmwarePreparing
    private let peripheralPreparer: any NativePeripheralPreparing
    private let apfsPreparer: any NativeAPFSPreparing
    private let stubFilesPreparer: any NativeStubFilesPreparing
    private let osPartitionsPreparer: any NativeOSPartitionsPreparing
    private let payloadImagesPreparer: any NativePayloadImagesPreparing
    private let espFilesPreparer: any NativeESPFilesPreparing
    private let installationFinisher: any NativeInstallationFinishingPreparing
    private let preservedReinstall: any NativePreservedReinstallExecuting
    private let stage1Update: any NativeStage1UpdateExecuting
    private let nativeHandoff: any NativeRecoveryHandoffExecuting
    private let validatePayload: @Sendable (ImportedEngineHandoffPackage) async throws -> Void
    private let validateSourceOwner:
      @Sendable (ImportedEngineHandoffPackage, MachineOwnerAuthorization) throws ->
        NativeSourceBootstrap
    private let prepareRecoveryTemplate:
      @Sendable (ImportedEngineHandoffPackage) throws -> PreparedNativeRecoveryTemplate

    public init(
      restoreImageRequirement: String? = RestoreImageHelper.requirement(
        environment: ProcessInfo.processInfo.environment)
    ) {
      self.restoreImageRequirement = restoreImageRequirement
      verifyRestoreImage = { try RestoreImageHelper.verify($0, requirement: $1) }
      effectiveUserID = { geteuid() }
      expectedFileOwnerID = { geteuid() }
      firmwarePreparer = NativeFirmwarePreparer()
      peripheralPreparer = NativeNeoPeripheralPreparer()
      apfsPreparer = NativeAPFSPreparer()
      stubFilesPreparer = NativeStubFilesPreparer()
      osPartitionsPreparer = NativeOSPartitionsPreparer()
      payloadImagesPreparer = NativePayloadImagesPreparer()
      let finishing = NativeInstallationFinisher()
      espFilesPreparer = NativeESPFilesPreparer()
      installationFinisher = finishing
      preservedReinstall = NativePreservedInstallCoordinator()
      stage1Update = NativeStage1UpdateCoordinator()
      nativeHandoff = NativeRecoveryHandoffExecutor()
      validatePayload = { try await NativePayloadPreflight.check($0) }
      validateSourceOwner = {
        try NativeSourceOwnerAdmission().check(package: $0, authorization: $1)
      }
      prepareRecoveryTemplate = { try NativeRecoveryTemplate.prepare(package: $0) }
    }

    init(
      effectiveUserID: @escaping @Sendable () -> uid_t,
      expectedFileOwnerID: @escaping @Sendable () -> uid_t = { geteuid() },
      restoreImageRequirement: String? = nil,
      verifyRestoreImage: @escaping @Sendable (URL, String) throws -> Void = {
        try RestoreImageHelper.verify($0, requirement: $1)
      },
      firmwarePreparer: any NativeFirmwarePreparing = NativeFirmwarePreparer(),
      peripheralPreparer: any NativePeripheralPreparing = NativeNeoPeripheralPreparer(),
      apfsPreparer: any NativeAPFSPreparing = NativeAPFSPreparer(),
      stubFilesPreparer: any NativeStubFilesPreparing = NativeStubFilesPreparer(),
      osPartitionsPreparer: any NativeOSPartitionsPreparing = NativeOSPartitionsPreparer(),
      payloadImagesPreparer: any NativePayloadImagesPreparing = NativePayloadImagesPreparer(),
      espFilesPreparer: any NativeESPFilesPreparing = NativeESPFilesPreparer(),
      installationFinisher: any NativeInstallationFinishingPreparing = NativeInstallationFinisher(),
      preservedReinstall: any NativePreservedReinstallExecuting =
        NativePreservedInstallCoordinator(),
      stage1Update: any NativeStage1UpdateExecuting = NativeStage1UpdateCoordinator(),
      nativeHandoff: any NativeRecoveryHandoffExecuting = NativeRecoveryHandoffExecutor(),
      validatePayload: @escaping @Sendable (ImportedEngineHandoffPackage) async throws -> Void = {
        try await NativePayloadPreflight.check($0)
      },
      validateSourceOwner:
        @escaping @Sendable (ImportedEngineHandoffPackage, MachineOwnerAuthorization) throws ->
        NativeSourceBootstrap =
        {
          try NativeSourceOwnerAdmission().check(package: $0, authorization: $1)
        },
      prepareRecoveryTemplate:
        @escaping @Sendable (ImportedEngineHandoffPackage) throws -> PreparedNativeRecoveryTemplate =
        { try NativeRecoveryTemplate.prepare(package: $0) }
    ) {
      self.effectiveUserID = effectiveUserID
      self.expectedFileOwnerID = expectedFileOwnerID
      self.restoreImageRequirement = restoreImageRequirement
      self.verifyRestoreImage = verifyRestoreImage
      self.firmwarePreparer = firmwarePreparer
      self.peripheralPreparer = peripheralPreparer
      self.apfsPreparer = apfsPreparer
      self.stubFilesPreparer = stubFilesPreparer
      self.osPartitionsPreparer = osPartitionsPreparer
      self.payloadImagesPreparer = payloadImagesPreparer
      self.espFilesPreparer = espFilesPreparer
      self.installationFinisher = installationFinisher
      self.preservedReinstall = preservedReinstall
      self.stage1Update = stage1Update
      self.nativeHandoff = nativeHandoff
      self.validatePayload = validatePayload
      self.validateSourceOwner = validateSourceOwner
      self.prepareRecoveryTemplate = prepareRecoveryTemplate
    }

    public func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install
    ) async throws -> Data {
      try await execute(
        package, authorization: authorization, operation: operation, installConf: nil)
    }

    public func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation,
      installConf: InstallConf?
    ) async throws -> Data {
      guard effectiveUserID() == 0 else {
        throw PinnedAsahiEngineExecutionError.privilegeRequired
      }
      // A Stage 1 update keeps no execution journal: it never touches the
      // partitions, and the stub records its own state for Recovery.
      if operation == .updateStage1 {
        return try await updateStage1(package, authorization: authorization)
      }
      let journal = try preparePersistentJournal(for: package)
      // Only an older installer's retired engine could repair an installed
      // system. Nothing continues such a job; the person starts over.
      guard package.installationIntent != .repair else {
        throw preparationFailure(
          NativeHandoffValidationError.invalidTarget, reason: .startOverRequired,
          operation: operation, journal: journal, package: package,
          password: authorization.password,
          summary: "This installation was started by an older installer and can’t be continued.")
      }
      if package.installationIntent == .reinstall {
        guard let installConf,
          operation == .install || operation == .retryRecoveryAuthorization
        else {
          throw PinnedAsahiEngineExecutionError.nativeReinstallUnavailable
        }
        do {
          return try await InstallerPerformance.measuring("preserved_reinstall") {
            try await preservedReinstall.execute(
              package, journal: journal, authorization: authorization,
              installConf: installConf)
          }
        } catch let error as PinnedAsahiEngineExecutionError {
          throw error
        } catch {
          let update = Self.macOSUpdateSummary(for: error)
          throw preparationFailure(
            error, reason: update == nil ? Self.preservedReason(for: error) : .macOSUpdateRequired,
            operation: operation, journal: journal, package: package,
            password: authorization.password,
            summary: update ?? Self.preservedSummary(for: error)
              ?? (error is NativeSourceOwnerRefusal ? Self.sourceOwnerSummary(for: error) : nil)
              ?? "The preserved installation did not complete.")
        }
      }
      let resumesNativePreparation =
        operation == .retryRecoveryAuthorization
        && nativeDiskPreparationRetryEligible(
          journal: journal, identity: RecoveryRetryIdentity(package: package))
      let operation: EngineHandoffOperation = resumesNativePreparation ? .install : operation
      let recovery: PreparedNativeRecoveryTemplate
      do {
        recovery = try InstallerPerformance.measure("recovery_template") {
          try prepareRecoveryTemplate(package)
        }
      } catch {
        throw preparationFailure(
          error, reason: .recoveryPreparation, operation: operation,
          journal: journal, package: package, password: authorization.password)
      }
      defer { recovery.remove() }
      if operation == .retryRecoveryAuthorization {
        return try await finalizeNativeHandoff(
          package, journal: journal, authorization: authorization,
          requirement: recovery.requirement, fullReadback: true)
      }
      do {
        guard let restoreImageRequirement, let restoreImage = package.restoreImageURL else {
          throw PinnedAsahiEngineExecutionError.restoreImageUnavailable
        }
        try InstallerPerformance.measure("restore_helper_check") {
          try verifyRestoreImage(restoreImage, restoreImageRequirement)
        }
      } catch {
        throw preparationFailure(
          error, reason: .recoveryPreparation, operation: operation,
          journal: journal, package: package, password: authorization.password)
      }
      let sourceBootstrap: NativeSourceBootstrap
      do {
        sourceBootstrap = try InstallerPerformance.measure("source_owner") {
          try validateSourceOwner(package, authorization)
        }
      } catch {
        throw preparationFailure(
          error, reason: .recoveryPreparation, operation: operation, journal: journal,
          package: package, password: authorization.password,
          summary: Self.sourceOwnerSummary(for: error))
      }
      do {
        try await InstallerPerformance.measuring("payload_preflight") {
          try await validatePayload(package)
        }
      } catch {
        let (reason, summary) = Self.payloadFailure(error)
        throw preparationFailure(
          error, reason: reason, operation: operation, journal: journal,
          package: package, password: authorization.password, summary: summary)
      }
      let hadDiskWrites = !journalProvesNoMutation(
        journal, identity: RecoveryRetryIdentity(package: package))
      var preparedPeripherals: PreparedNativePeripheralInputs?
      do {
        if let raw = try await InstallerPerformance.measuring(
          "firmware_preparation",
          {
            try await firmwarePreparer.prepare(
              deviceIdentifier: package.deviceIdentifier,
              in: package.packageURL.deletingLastPathComponent())
          })
        {
          preparedPeripherals = try await InstallerPerformance.measuring("peripheral_inputs") {
            try await peripheralPreparer.prepare(package: package, rawDirectory: raw)
          }
        }
      } catch {
        let network = TransientTransport.isTransient(error)
        throw PinnedAsahiEngineExecutionError.engineFailed(
          EngineFailureReport(
            notice: EngineFailureNotice(
              reason: network ? .networkUnavailable : .firmwarePreparation, exitStatus: 1,
              diskUnchanged: journalProvesNoMutation(
                journal, identity: RecoveryRetryIdentity(package: package)),
              summary: network
                ? Self.networkSummary : "Native firmware preparation did not complete."),
            redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
              Data(String(describing: error).utf8), truncated: false,
              secrets: [authorization.password])))
      }
      return try await PreparedNativePeripheralInputs.withCleanup(preparedPeripherals) {
        let preparedAPFS: any NativeAPFSExecuting
        let preparedStubFiles: any NativeStubFilesExecuting
        let preparedOSPartitions: any NativeOSPartitionsExecuting
        let preparedPayloadImages: any NativePayloadImagesExecuting
        let preparedESPFiles: any NativeESPFilesExecuting
        let preparedFinishing: any NativeInstallationFinishing
        // Each preflight names its own stage, so a refusal reports the check
        // that made it and the cause, not one sentence for all six.
        var stage = NativePreflightStage.apfs
        do {
          // Every stage must preflight before the first disk change. A fresh
          // installation that any stage cannot take stops here.
          guard package.installationIntent == .fresh else {
            throw NativePreflightRefusal.notFreshInstallation
          }
          guard
            let apfs = try await InstallerPerformance.measuring(
              "apfs_preflight", { try await apfsPreparer.preflight(package) })
          else { throw NativePreflightRefusal.stageUnavailable }
          stage = .stubFiles
          guard
            let stubFiles = try await InstallerPerformance.measuring(
              "stub_files_preflight", { try await stubFilesPreparer.preflight(package) })
          else { throw NativePreflightRefusal.stageUnavailable }
          stage = .osPartitions
          let osPartitions = try InstallerPerformance.measure("os_partitions_preflight") {
            try osPartitionsPreparer.preflight(package)
          }
          stage = .payloadImages
          let payloadImages = try await InstallerPerformance.measuring(
            "payload_images_preflight"
          ) {
            try await payloadImagesPreparer.preflight(package)
          }
          stage = .espFiles
          guard
            let espFiles = try await InstallerPerformance.measuring(
              "esp_files_preflight", { try await espFilesPreparer.preflight(package) })
          else { throw NativePreflightRefusal.stageUnavailable }
          stage = .finishing
          guard
            let finishing = try InstallerPerformance.measure(
              "finishing_preflight",
              {
                try installationFinisher.preflight(
                  package: package, stub: stubFiles.firmwarePlan,
                  peripherals: preparedPeripherals)
              })
          else { throw NativePreflightRefusal.stageUnavailable }
          // The stub stage caches and decodes restore files on macOS. A plan
          // macOS lacks the free space for stops here, with the disk as is.
          stage = .stubFiles
          try InstallerPerformance.measure("staging_space") {
            try stubFiles.requireStagingSpace(journal: journal)
            if let expanded = espFiles.expandedStage1Bytes {
              try stubFiles.requireRoom(forExpandedStage1: expanded)
            }
          }
          preparedAPFS = apfs
          preparedStubFiles = stubFiles
          preparedOSPartitions = osPartitions
          preparedPayloadImages = payloadImages
          preparedESPFiles = espFiles
          preparedFinishing = finishing
        } catch {
          let (reason, summary) = Self.preflightFailure(stage: stage, error: error)
          throw preparationFailure(
            error, reason: reason, operation: operation,
            journal: journal, package: package, password: authorization.password,
            summary: summary)
        }
        do {
          try InstallerPerformance.measure("apfs_preparation") {
            try preparedAPFS.prepareTarget(
              journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
          }
          try await InstallerPerformance.measuring("stub_files") {
            try await preparedStubFiles.prepare(
              journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
          }
          try InstallerPerformance.measure("os_partitions") {
            try preparedOSPartitions.prepare(
              journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
          }
          try await InstallerPerformance.measuring("payload_images") {
            try await preparedPayloadImages.prepare(
              journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
          }
          try await InstallerPerformance.measuring("esp_files") {
            try await preparedESPFiles.prepare(
              journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
          }
        } catch {
          let network = TransientTransport.isTransient(error)
          let (reason, summary) = Self.executionFailure(error)
          throw PinnedAsahiEngineExecutionError.engineFailed(
            EngineFailureReport(
              notice: EngineFailureNotice(
                reason: network ? .networkUnavailable : reason,
                exitStatus: 1,
                diskUnchanged: journalProvesNoMutation(
                  journal, identity: RecoveryRetryIdentity(package: package)),
                summary: network ? Self.networkSummary : summary),
              redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
                Data(String(describing: error).utf8), truncated: false,
                secrets: [authorization.password])))
        }
        do {
          try await InstallerPerformance.measuring("finishing") {
            try await preparedFinishing.prepare(
              journal: journal, authorization: authorization,
              sourceBootstrap: sourceBootstrap, recovery: recovery)
          }
        } catch {
          let space = error as? MacOSFreeSpaceShortfall
          throw preparationFailure(
            error, reason: space == nil ? .recoveryPreparation : .macOSSpaceRequired,
            operation: operation, journal: journal, package: package,
            password: authorization.password,
            summary: space?.summary ?? "Native firmware and Recovery publication did not complete.")
        }
        return try await finalizeNativeHandoff(
          package, journal: journal, authorization: authorization,
          requirement: recovery.requirement, fullReadback: hadDiskWrites)
      }
    }

    private func finalizeNativeHandoff(
      _ package: ImportedEngineHandoffPackage, journal: URL,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool
    ) async throws -> Data {
      do {
        return try await InstallerPerformance.measuring("recovery_handoff") {
          try await nativeHandoff.execute(
            package: package, journal: journal,
            authorization: authorization, requirement: requirement, fullReadback: fullReadback)
        }
      } catch let error as PinnedAsahiEngineExecutionError { throw error } catch {
        throw PinnedAsahiEngineExecutionError.engineFailed(
          EngineFailureReport(
            notice: EngineFailureNotice(
              reason: .recoveryPreparation, exitStatus: 1,
              diskUnchanged: false, summary: "Native Recovery handoff did not complete."),
            redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
              Data(String(describing: error).utf8), truncated: false,
              secrets: [authorization.password])))
      }
    }

    /// How a refused payload preflight is reported. A Mac whose firmware is
    /// too old for every OS firmware the release allows is told which macOS
    /// version to install instead of getting a generic firmware failure.
    static func payloadFailure(_ error: any Error) -> (EngineFailureReason, String) {
      if let update = macOSUpdateSummary(for: error) {
        return (.macOSUpdateRequired, update)
      }
      if let chain = error as? NativeBootChainError, chain.releaseLacksMachO {
        return (.deviceUnsupported, NativeBootChainError.releaseLacksMachOSummary)
      }
      return error is NativeFirmwareSelectionError
        ? (.firmwarePreparation, "Compatible boot firmware could not be selected.")
        : (.planIntegrity, "The installation images could not be verified (\(errorName(error))).")
    }

    /// How a refused disk-preparation preflight is reported: the reason that
    /// matches its cause, and a summary naming the stage and the cause.
    static func preflightFailure(stage: NativePreflightStage, error: any Error)
      -> (EngineFailureReason, String)
    {
      if TransientTransport.isTransient(error) { return (.networkUnavailable, networkSummary) }
      if let shortfall = error as? MacOSFreeSpaceShortfall {
        return (.macOSSpaceRequired, shortfall.summary)
      }
      if let update = macOSUpdateSummary(for: error) { return (.macOSUpdateRequired, update) }
      if let chain = error as? NativeBootChainError, chain.releaseLacksMachO {
        return (.deviceUnsupported, NativeBootChainError.releaseLacksMachOSummary)
      }
      let name = errorName(error)
      switch error {
      case NativeFirmwareSelectionError.updateArchiveOnly(let version):
        return (.deviceUnsupported, updateArchiveSummary(version: version))
      case NativeFirmwareSelectionError.unsupportedDevice:
        return (.deviceUnsupported, "The installer engine doesn't support this Mac model.")
      case is NativeFirmwareSelectionError:
        return (.firmwarePreparation, "Compatible boot firmware could not be selected (\(name)).")
      case NativePreflightRefusal.notFreshInstallation:
        return (
          .unclassified,
          "This installer installs only into free space or a resized container, not over an "
            + "existing installation."
        )
      case NativePreflightRefusal.stageUnavailable:
        return (.planIntegrity, "This installer has no \(stage.step) step for this plan.")
      case NativeStubFileError.cacheFull, NativeStubFileError.freeSpaceUnavailable:
        return (.unclassified, stagingSummary(error))
      case NativeStubFileError.noRoomForStage1:
        return (
          .planIntegrity,
          "The startup container for this macOS version is too small for this Mac's startup "
            + "software. Nothing on the disk changed."
        )
      case is RestoreFailure:
        return (.firmwarePreparation, "The macOS restore image could not be read (\(name)).")
      case is CancellationError:
        return (.unclassified, "The installation was canceled during the \(stage.step) check.")
      case is NativeSourceOwnerRefusal, NativeHandoffValidationError.invalidOwner:
        return (.recoveryPreparation, sourceOwnerSummary(for: error))
      default: break
      }
      if isLayoutChange(error) {
        return (.diskLayoutChanged, "The disk changed after you approved the plan (\(name)).")
      }
      if isOutOfSpace(error) {
        return (
          .unclassified, "A volume ran out of space during the \(stage.step) check (\(name))."
        )
      }
      if isIntegrity(error) {
        return (.planIntegrity, "The \(stage.step) check refused the approved plan (\(name)).")
      }
      return (.unclassified, "The \(stage.step) check stopped (\(name)).")
    }

    /// How a stage that may have changed the disk is reported.
    static func executionFailure(_ error: any Error) -> (EngineFailureReason, String) {
      if let shortfall = error as? MacOSFreeSpaceShortfall {
        return (.macOSSpaceRequired, shortfall.summary)
      }
      let name = errorName(error)
      switch error {
      case is NativeRawImageError: return (.unclassified, "The Linux image could not be written.")
      case is RestoreFailure:
        return (.recoveryPreparation, "The Recovery archive could not be prepared.")
      case NativeInstallAdmissionError.invalidJournal:
        return (.planIntegrity, "The installation record could not be verified.")
      case is NativeSourceOwnerRefusal, NativeHandoffValidationError.invalidOwner:
        return (.recoveryPreparation, sourceOwnerSummary(for: error))
      case NativeStubFileError.cacheFull, NativeStubFileError.freeSpaceUnavailable:
        return (.unclassified, stagingSummary(error))
      case is NativeStubFileError:
        return (.unclassified, "Aurora stub files could not be copied (\(name)).")
      default: break
      }
      if isLayoutChange(error) {
        return (
          .diskLayoutChanged, "The current disk could not be admitted for a fresh installation."
        )
      }
      if isOutOfSpace(error) {
        return (.unclassified, "A volume ran out of space while preparing the disk (\(name)).")
      }
      return (.unclassified, "Disk preparation stopped (\(name)).")
    }

    private static func stagingSummary(_ error: any Error) -> String {
      error as? NativeStubFileError == .cacheFull
        ? "The restore image cache on macOS is full."
        : "macOS did not report the free space of the installer's volume."
    }

    static func updateArchiveSummary(version: String) -> String {
      "This Mac needs boot firmware from macOS \(version), which Apple ships only as an update "
        + "archive. This installer can't prepare that archive yet."
    }

    /// The disk or its partitions no longer match what the plan approved.
    private static func isLayoutChange(_ error: any Error) -> Bool {
      switch error {
      case NativeAPFSError.changedLayout, NativeAPFSError.changedTarget,
        NativeOSPartitionError.changedLayout, NativeHandoffValidationError.changedLayout,
        NativeInstallAdmissionError.existingInstallation, NativeInstallAdmissionError.deviceChanged,
        NativeInspectionError.invalidLayout:
        true
      default: false
      }
    }

    /// The approved plan, its files or its evidence failed a check.
    private static func isIntegrity(_ error: any Error) -> Bool {
      switch error {
      case is EngineHandoffImportError, is NativePayloadPreflightError,
        NativeAPFSError.invalidPlan, NativeAPFSError.invalidLabel,
        NativeStubFileError.invalidPlan, NativeStubFileError.changedFile,
        NativeStubFileError.invalidImage, NativeOSPartitionError.invalidMetadata,
        NativeHandoffValidationError.invalidEvidence, NativeHandoffValidationError.changedContent,
        NativeHandoffValidationError.invalidTarget, NativeHandoffValidationError.unsafePath,
        NativeInspectionError.invalidMetadata, NativeInspectionError.metadataChanged,
        NativeInspectionError.invalidPolicy, NativeRawImageError.invalidImage,
        NativeInstallAdmissionError.invalidJournal,
        PinnedAsahiEngineExecutionError.unsafeTranscript:
        true
      default: false
      }
    }

    private static func isOutOfSpace(_ error: any Error) -> Bool {
      let error = error as NSError
      return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
        || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
    }

    /// The error's type and, for an enum, its case. Associated values are
    /// left out: they can carry paths, which stay in the root-only
    /// diagnostics. Foundation errors keep their domain and code. A type that
    /// describes itself is named only, since its description is free text.
    static func errorName(_ error: any Error) -> String {
      let kind = String(describing: type(of: error))
      if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
      guard Mirror(reflecting: error).displayStyle == .enum, !(error is CustomStringConvertible)
      else {
        if type(of: error) is NSError.Type {
          let error = error as NSError
          return "\(kind) \(error.domain) \(error.code)"
        }
        return kind
      }
      let name = String(describing: error).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }
      )
      return name.isEmpty || name.count > 60 ? kind : "\(kind).\(name)"
    }

    /// The notice summary naming the macOS version this Mac must update to,
    /// or nil when the error is not that firmware refusal.
    static func macOSUpdateSummary(for error: any Error) -> String? {
      guard case NativeFirmwareSelectionError.macOSUpdateRequired(let version) = error else {
        return nil
      }
      return EngineFailureReason.macOSUpdateSummary(version: version)
    }

    /// Why a reset stopped, so its screen offers what helps: an unsupported Mac
    /// gets the unsupported-Mac screen, and an installation only erasing fixes
    /// gets Erase Linux rather than Check again.
    static func preservedReason(for error: any Error) -> EngineFailureReason {
      if let chain = error as? NativeBootChainError, chain.releaseLacksMachO {
        return .deviceUnsupported
      }
      if case NativePreservedInstallError.earlierStage1 = error { return .reinstallRequired }
      return .unclassified
    }

    private func updateStage1(
      _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization
    ) async throws -> Data {
      guard package.installationIntent == .reinstall else {
        throw PinnedAsahiEngineExecutionError.nativeReinstallUnavailable
      }
      do {
        return try await InstallerPerformance.measuring("stage1_update") {
          try await stage1Update.execute(package, authorization: authorization)
        }
      } catch {
        let failure = error as? NativeStage1UpdateFailure
        let underlying = failure?.underlying ?? error
        let network = TransientTransport.isTransient(underlying)
        let update = Self.macOSUpdateSummary(for: underlying)
        let summary =
          network
          ? Self.networkSummary : update ?? Self.stage1UpdateSummary(for: underlying)
        throw PinnedAsahiEngineExecutionError.engineFailed(
          EngineFailureReport(
            notice: EngineFailureNotice(
              reason: network
                ? .networkUnavailable
                : update == nil ? .bootLoaderUpdateRefused : .macOSUpdateRequired,
              exitStatus: 1, diskUnchanged: failure?.diskChanged == false, summary: summary),
            redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
              Data(String(describing: underlying).utf8), truncated: false,
              secrets: [authorization.password])))
      }
    }

    static func stage1UpdateSummary(for error: any Error) -> String {
      if let refusal = error as? NativeStage1UpdateError { return refusal.summary }
      if let chain = error as? NativeBootChainError, chain.releaseLacksMachO {
        return NativeBootChainError.releaseLacksMachOSummary
      }
      if error is NativeSourceOwnerRefusal { return sourceOwnerSummary(for: error) }
      switch error {
      case NativeHandoffValidationError.authorizationFailed:
        return "macOS didn't accept the password to choose this installation as the startup disk."
      case NativePreservedInstallError.changedLayout, NativePreservedInstallError.unavailable:
        return NativeStage1UpdateError.changedInstallation.summary
      case is NativeBootChainError:
        return "This release's boot loader didn't pass the installer's checks."
      default:
        return "The boot loader update didn't finish."
      }
    }

    static func preservedSummary(for error: any Error) -> String? {
      if let chain = error as? NativeBootChainError, chain.releaseLacksMachO {
        return NativeBootChainError.releaseLacksMachOSummary
      }
      if case NativePreservedInstallError.earlierStage1 = error {
        return "This installation's boot loader is from an earlier Aurora installer. "
          + "Update its boot loader first, then reset it."
      }
      guard
        case NativePreservedInstallError.espFull(let required, let available) = error
      else { return nil }
      func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
      }
      return "The EFI partition has \(megabytes(available)) free, but the new boot files need "
        + "\(megabytes(required)). Erase Linux and install it again to recreate the partition."
    }

    static let networkSummary =
      "The connection to Apple's servers was lost while the installer was downloading."

    static let sourceOwnerSummaryPrefix = "The current macOS volume owner could not be verified"

    /// The shown summary names the check that refused the owner, so one
    /// sentence no longer stands for every guard of the proof.
    static func sourceOwnerSummary(for error: any Error) -> String {
      switch error {
      case let refusal as NativeSourceOwnerRefusal:
        "\(sourceOwnerSummaryPrefix): \(refusal.summary)"
      case is CancellationError: "\(sourceOwnerSummaryPrefix): the check was canceled."
      default: "\(sourceOwnerSummaryPrefix)."
      }
    }

    private func preparationFailure(
      _ error: any Error, reason: EngineFailureReason, operation: EngineHandoffOperation,
      journal: URL, package: ImportedEngineHandoffPackage, password: Data,
      summary: String = "Native Recovery resources could not be verified."
    ) -> PinnedAsahiEngineExecutionError {
      let network = TransientTransport.isTransient(error)
      return .engineFailed(
        EngineFailureReport(
          notice: EngineFailureNotice(
            reason: network ? .networkUnavailable : reason, exitStatus: 1,
            diskUnchanged: operation == .install
              && journalProvesNoMutation(journal, identity: RecoveryRetryIdentity(package: package)),
            summary: network ? Self.networkSummary : summary),
          redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
            Data(String(describing: error).utf8), truncated: false, secrets: [password])))
    }

    /// True only when the persistent journal can be read in full and holds
    /// nothing but the read-only inspection, inventory and plan records.
    /// Every engine mutation stage appends its start event before touching
    /// the disk, so the absence of event, checkpoint and completion records
    /// proves no mutation began. Anything unreadable or unexpected makes no
    /// claim.
    private func journalProvesNoMutation(_ journal: URL, identity: RecoveryRetryIdentity?) -> Bool {
      guard let bytes = try? readAdmissionJournal(journal),
        NativeInstallAdmission.provesNoMutation(bytes)
      else { return false }
      if bytes.isEmpty { return true }
      guard let identity,
        let validated = try? AppleInstallerTrustCore().validateEngineTranscript(bytes),
        validated.deviceIdentifier == identity.deviceIdentifier,
        validated.inventory.map({ $0.systemStoreIdentifier == identity.storeIdentifier }) ?? true,
        validated.plan.map({ $0.planDigest == identity.planDigest }) ?? true
      else { return false }
      return true
    }

    private func readAdmissionJournal(_ journal: URL) throws -> Data {
      let descriptor = Darwin.open(
        journal.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard descriptor >= 0 else { throw PinnedAsahiEngineExecutionError.unsafeTranscript }
      defer { Darwin.close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size >= 0,
        status.st_size <= Self.maximumTranscriptBytes
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      if status.st_size == 0 { return Data() }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      guard let data = try? handle.readToEnd(),
        data.count == Int(status.st_size),
        data.last == 0x0A
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      return data
    }

    func canRetryRecoveryAuthorization(_ identity: InstallerJobPlanIdentity, in directory: URL)
      -> Bool
    {
      guard
        let journal = EngineJournalLocator.journalURL(
          workingDirectory: directory, bindingDigest: identity.bindingDigest)
      else { return false }
      let retryIdentity = RecoveryRetryIdentity(identity: identity)
      return preservedRetryEligible(journal: journal, identity: identity)
        || nativeDiskPreparationRetryEligible(journal: journal, identity: retryIdentity)
        || isRecoveryAuthorizationRetryEligible(journal: journal, identity: retryIdentity)
    }

    /// A failed job may be set aside only when its journal verifies as this
    /// plan's and no process still holds the journal lease. A reset's journal
    /// must also decode as a preserved reinstall. The journal itself is kept,
    /// and with it the evidence that lets removal undo a partial install.
    func canAbandonFailedJob(_ identity: InstallerJobPlanIdentity, in directory: URL) -> Bool {
      guard
        let journal = EngineJournalLocator.journalURL(
          workingDirectory: directory, bindingDigest: identity.bindingDigest),
        let transcript = try? readTranscript(journal),
        let validated = try? AppleInstallerTrustCore().validateEngineTranscript(transcript),
        let plan = validated.plan, plan.planDigest == identity.planDigest,
        validated.deviceIdentifier == identity.deviceIdentifier,
        plan.storeIdentifier == identity.storeIdentifier
      else { return false }
      if plan.candidateKind == "reinstall" {
        return preservedRetryEligible(journal: journal, identity: identity)
      }
      let descriptor = Darwin.open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { return false }
      defer { Darwin.close(descriptor) }
      var opened = stat()
      var named = stat()
      guard fstat(descriptor, &opened) == 0, lstat(journal.path, &named) == 0,
        opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == expectedFileOwnerID(),
        opened.st_mode & 0o077 == 0, opened.st_nlink == 1,
        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        flock(descriptor, LOCK_EX | LOCK_NB) == 0
      else { return false }
      defer { _ = flock(descriptor, LOCK_UN) }
      return true
    }

    /// A helper lost during Recovery can resume only after both disk stages
    /// have durable checkpoints and no prior child retains the journal lease.
    func canResumeInterruptedRecoveryAuthorization(
      _ identity: InstallerJobPlanIdentity, in directory: URL
    ) -> Bool {
      if let journal = EngineJournalLocator.journalURL(
        workingDirectory: directory, bindingDigest: identity.bindingDigest),
        preservedRetryEligible(journal: journal, identity: identity)
      {
        return true
      }
      guard
        let journal = EngineJournalLocator.journalURL(
          workingDirectory: directory, bindingDigest: identity.bindingDigest),
        let transcript = try? readTranscript(journal),
        let validated = try? AppleInstallerTrustCore().validateEngineTranscript(transcript),
        let plan = validated.plan,
        let snapshot = try? NativeRecoveryJournalSnapshot.decode(
          transcript, planDigest: identity.planDigest,
          deviceIdentifier: identity.deviceIdentifier,
          storeIdentifier: identity.storeIdentifier,
          intent: plan.candidateKind == "replace" ? .replace : .fresh,
          evidence: { try readCheckpointEvidence(journal: journal, identifier: $0) }),
        snapshot.state == .started
      else { return false }
      let fd = Darwin.open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { return false }
      defer { Darwin.close(fd) }
      var opened = stat()
      var named = stat()
      guard fstat(fd, &opened) == 0, lstat(journal.path, &named) == 0,
        opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == expectedFileOwnerID(),
        opened.st_mode & 0o077 == 0, opened.st_nlink == 1,
        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        flock(fd, LOCK_EX | LOCK_NB) == 0
      else { return false }
      defer { _ = flock(fd, LOCK_UN) }
      return true
    }

    private func preservedRetryEligible(
      journal: URL, identity: InstallerJobPlanIdentity
    ) -> Bool {
      guard let transcript = try? readTranscript(journal),
        let snapshot = try? NativePreservedInstallJournalSnapshot.decode(
          transcript, identity: identity,
          evidence: { try readCheckpointEvidence(journal: journal, identifier: $0) }),
        snapshot.state != .ready,
        let configuration = try? readCheckpointEvidence(
          journal: journal, identifier: "preserved-install-conf"),
        let parsed = try? InstallConf.parse(configuration),
        parsed.serializedData == configuration
      else { return false }
      let descriptor = Darwin.open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { return false }
      defer { Darwin.close(descriptor) }
      var opened = stat()
      var named = stat()
      guard fstat(descriptor, &opened) == 0, lstat(journal.path, &named) == 0,
        opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == expectedFileOwnerID(),
        opened.st_mode & 0o077 == 0, opened.st_nlink == 1,
        opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
        flock(descriptor, LOCK_EX | LOCK_NB) == 0
      else { return false }
      defer { _ = flock(descriptor, LOCK_UN) }
      return true
    }

    private func nativeDiskPreparationRetryEligible(journal: URL, identity: RecoveryRetryIdentity)
      -> Bool
    {
      guard let transcript = try? readTranscript(journal) else { return false }
      return Self.nativeDiskPreparationRetryEligible(
        transcript: transcript,
        planDigest: identity.planDigest, deviceIdentifier: identity.deviceIdentifier,
        storeIdentifier: identity.storeIdentifier,
        evidence: { try readCheckpointEvidence(journal: journal, identifier: $0) })
    }

    /// An intact APFS checkpoint can continue the original native operation.
    /// A start intent without that checkpoint is never eligible. Actual replay
    /// rechecks the owner, geometry, volumes and every existing file receipt.
    static func nativeDiskPreparationRetryEligible(
      transcript: Data, planDigest: String,
      deviceIdentifier: String, storeIdentifier: String, evidence: (String) throws -> Data
    ) -> Bool {
      do {
        let records = try EngineTranscriptDecoder().decode(transcript)
        let validated = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
        guard records.count == 5, validated.support == .supported,
          validated.deviceIdentifier == deviceIdentifier,
          let plan = validated.plan, plan.planDigest == planDigest,
          plan.deviceIdentifier == deviceIdentifier, plan.storeIdentifier == storeIdentifier,
          ["free", "resize"].contains(plan.candidateKind),
          case .event(let event) = records[3].message, event.name == "apfs_preparation_started",
          case .checkpoint(let checkpoint) = records[4].message,
          checkpoint.identifier == "apfs-target-prepared", checkpoint.phase == "apfs_preparation"
        else { return false }
        let bytes = try evidence(checkpoint.identifier)
        guard SHA256Digest(hashing: bytes).rawValue == checkpoint.evidenceDigest else {
          return false
        }
        let target = try NativeAPFSTargetEvidence.read(bytes)
        let volumes = try NativeStubVolumes.read(evidence(NativeStubVolumes.evidenceIdentifier))
        let source =
          try JSONSerialization.jsonObject(with: evidence("native-source-owner")) as? [String: Any]
        guard target.planDigest == planDigest, target.offsetBytes == plan.offsetBytes,
          target.sizeBytes > 0, target.sizeBytes <= plan.lengthBytes,
          volumes.planDigest == planDigest, volumes.partitionUUID == target.uuid,
          source?["plan_digest"] as? String == planDigest,
          let bootstrap = source?["bootstrap"] as? [String: Any]
        else { return false }
        _ = try NativeSourceBootstrap(bootstrap)
        return true
      } catch { return false }
    }

    private func isRecoveryAuthorizationRetryEligible(
      journal: URL,
      identity: RecoveryRetryIdentity
    ) -> Bool {
      guard let transcript = try? readTranscript(journal) else {
        return false
      }
      guard let validated = try? AppleInstallerTrustCore().validateEngineTranscript(transcript),
        let plan = validated.plan, ["free", "resize", "replace"].contains(plan.candidateKind),
        let snapshot = try? NativeRecoveryJournalSnapshot.decode(
          transcript,
          planDigest: identity.planDigest, deviceIdentifier: identity.deviceIdentifier,
          storeIdentifier: identity.storeIdentifier,
          intent: plan.candidateKind == "replace" ? .replace : .fresh,
          evidence: { try readCheckpointEvidence(journal: journal, identifier: $0) })
      else { return false }
      return snapshot.state == .ready || snapshot.state == .started || snapshot.state == .prepared
    }

    private func readCheckpointEvidence(
      journal: URL,
      identifier: String
    ) throws -> Data {
      let evidenceURL = URL(
        fileURLWithPath: "\(journal.path).\(identifier).evidence"
      )
      let descriptor = Darwin.open(
        evidenceURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size > 0,
        status.st_size <= 1_048_576
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size)
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      return data
    }

    private func preparePersistentJournal(
      for package: ImportedEngineHandoffPackage
    ) throws -> URL {
      guard
        let bindingDigest = SHA256Digest(
          rawValue: package.bindingDigest
        )
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let identifier = bindingDigest.hexadecimal

      let directory = package.packageURL
        .deletingLastPathComponent()
        .appendingPathComponent("execution-journals", isDirectory: true)
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      }
      try validateJournalDirectory(directory)

      let journal = directory.appendingPathComponent("\(identifier).jsonl")
      let descriptor = Darwin.open(
        journal.path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size <= Self.maximumTranscriptBytes
      else {
        Darwin.close(descriptor)
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      Darwin.close(descriptor)
      return journal
    }

    private func validateJournalDirectory(_ directory: URL) throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID()
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
    }

    private func readTranscript(_ journal: URL) throws -> Data {
      let descriptor = Darwin.open(
        journal.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size > 0,
        status.st_size <= Self.maximumTranscriptBytes
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size),
        data.last == 0x0A
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      return data
    }

    /// The six preflights, in the order they run.
    enum NativePreflightStage: String, Sendable {
      case apfs
      case stubFiles = "stub_files"
      case osPartitions = "os_partitions"
      case payloadImages = "payload_images"
      case espFiles = "esp_files"
      case finishing

      /// The step's name in a shown summary.
      var step: String {
        switch self {
        case .apfs: "disk preparation"
        case .stubFiles: "macOS boot files"
        case .osPartitions: "Linux partition"
        case .payloadImages: "Linux image"
        case .espFiles: "EFI partition"
        case .finishing: "firmware and Recovery"
        }
      }
    }

    enum NativePreflightRefusal: Error, Equatable {
      /// Only a fresh installation reaches the native disk stages.
      case notFreshInstallation
      /// The stage has nothing it can run for this plan.
      case stageUnavailable
    }

    private struct RecoveryRetryIdentity {
      let planDigest: String
      let deviceIdentifier: String
      let storeIdentifier: String

      init(package: ImportedEngineHandoffPackage) {
        planDigest = package.planDigest
        deviceIdentifier = package.deviceIdentifier
        storeIdentifier = package.storeIdentifier
      }

      init(identity: InstallerJobPlanIdentity) {
        planDigest = identity.planDigest
        deviceIdentifier = identity.deviceIdentifier
        storeIdentifier = identity.storeIdentifier
      }
    }
  }
#endif
