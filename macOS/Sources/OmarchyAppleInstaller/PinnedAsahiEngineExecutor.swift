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
            error, reason: update == nil ? .unclassified : .macOSUpdateRequired,
            operation: operation, journal: journal, package: package,
            password: authorization.password,
            summary: update ?? Self.preservedSummary(for: error)
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
          summary: "The current macOS volume owner could not be verified.")
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
        do {
          // Every stage must preflight before the first disk change. A fresh
          // installation that any stage cannot take stops here.
          guard
            let apfs = try await InstallerPerformance.measuring(
              "apfs_preflight", { try await apfsPreparer.preflight(package) }),
            let stubFiles = try await InstallerPerformance.measuring(
              "stub_files_preflight", { try await stubFilesPreparer.preflight(package) })
          else { throw NativeHandoffValidationError.invalidTarget }
          let osPartitions = try InstallerPerformance.measure("os_partitions_preflight") {
            try osPartitionsPreparer.preflight(package)
          }
          let payloadImages = try await InstallerPerformance.measuring(
            "payload_images_preflight"
          ) {
            try await payloadImagesPreparer.preflight(package)
          }
          guard
            let espFiles = try await InstallerPerformance.measuring(
              "esp_files_preflight", { try await espFilesPreparer.preflight(package) }),
            let finishing = try InstallerPerformance.measure(
              "finishing_preflight",
              {
                try installationFinisher.preflight(
                  package: package, stub: stubFiles.firmwarePlan,
                  peripherals: preparedPeripherals)
              }),
            package.installationIntent == .fresh
          else { throw NativeHandoffValidationError.invalidTarget }
          preparedAPFS = apfs
          preparedStubFiles = stubFiles
          preparedOSPartitions = osPartitions
          preparedPayloadImages = payloadImages
          preparedESPFiles = espFiles
          preparedFinishing = finishing
        } catch {
          throw preparationFailure(
            error, reason: .planIntegrity, operation: operation,
            journal: journal, package: package, password: authorization.password,
            summary: "Native disk preparation could not be verified.")
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
          throw PinnedAsahiEngineExecutionError.engineFailed(
            EngineFailureReport(
              notice: EngineFailureNotice(
                reason: network
                  ? .networkUnavailable
                  : error is NativeRawImageError
                    ? .unclassified
                    : error is RestoreFailure
                      ? .recoveryPreparation
                      : error as? NativeInstallAdmissionError == .invalidJournal
                        ? .planIntegrity : .diskLayoutChanged,
                exitStatus: 1,
                diskUnchanged: journalProvesNoMutation(
                  journal, identity: RecoveryRetryIdentity(package: package)),
                summary: network
                  ? Self.networkSummary
                  : error is NativeRawImageError
                    ? "The Linux image could not be written."
                    : error is RestoreFailure
                      ? "The Recovery archive could not be prepared."
                      : "The current disk could not be admitted for a fresh installation."),
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
          throw preparationFailure(
            error, reason: .recoveryPreparation, operation: operation,
            journal: journal, package: package, password: authorization.password,
            summary: "Native firmware and Recovery publication did not complete. (\(type(of: error)): \(error))")
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
      return error is NativeFirmwareSelectionError
        ? (.firmwarePreparation, "Compatible boot firmware could not be selected.")
        : (.planIntegrity, "The installation images could not be verified.")
    }

    /// The notice summary naming the macOS version this Mac must update to,
    /// or nil when the error is not that firmware refusal.
    static func macOSUpdateSummary(for error: any Error) -> String? {
      guard case NativeFirmwareSelectionError.macOSUpdateRequired(let version) = error else {
        return nil
      }
      return EngineFailureReason.macOSUpdateSummary(version: version)
    }

    static func preservedSummary(for error: any Error) -> String? {
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
          || nativeDiskPreparationRetryEligible(
            journal: journal, identity: RecoveryRetryIdentity(identity: identity))
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
