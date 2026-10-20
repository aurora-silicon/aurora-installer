#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  public enum PinnedAsahiEngineExecutionError:
    Error, Equatable, Sendable
  {
    case privilegeRequired
    case invalidArchiveIdentity
    case unsafeArchive
    case archiveSizeMismatch
    case archiveDigestMismatch
    case unsafeArchiveEntry
    case extractionFailed(Int32)
    case invalidBundle
    case launchFailed
    /// The engine exited non-zero. The report's notice is the only part that
    /// may leave the privileged helper; the redacted stderr tail stays in its
    /// root-only diagnostics.
    case engineFailed(EngineFailureReport)
    case recoveryAuthorizationFailed
    case recoveryTemplateRejected
    case restoreImageUnavailable
    case restoreImageRejected
    case restoreImageUnsupported
    case recoveryTemplateUnsupported
    case unsafeTranscript
  }

  public struct PinnedAsahiEngineArchive: Equatable, Sendable {
    public let fileURL: URL
    public let expectedDigest: String
    public let expectedSizeBytes: UInt64

    public init(
      fileURL: URL,
      expectedDigest: String,
      expectedSizeBytes: UInt64
    ) throws {
      guard fileURL.isFileURL,
        SHA256Digest(rawValue: expectedDigest) != nil,
        expectedSizeBytes > 0,
        expectedSizeBytes <= UInt64(PinnedAsahiEngineExecutor.maximumArchiveBytes)
      else {
        throw PinnedAsahiEngineExecutionError.invalidArchiveIdentity
      }
      self.fileURL = fileURL
      self.expectedDigest = expectedDigest
      self.expectedSizeBytes = expectedSizeBytes
    }
  }

  public struct PinnedAsahiEngineExecutor:
    ImportedEngineHandoffExecuting, Sendable
  {
    public static let maximumArchiveBytes: Int64 = 67_108_864
    public static let maximumTranscriptBytes: Int64 = 8_388_608

    private let effectiveUserID: @Sendable () -> uid_t
    private let expectedFileOwnerID: @Sendable () -> uid_t
    private let extractionOptions: [String]
    private let restoreImageRequirement: String?
    private let verifyRestoreImage: @Sendable (URL, String) throws -> Void
    private let firmwarePreparer: any NativeFirmwarePreparing
    private let peripheralPreparer: any NativePeripheralPreparing
    private let apfsPreparer: any NativeAPFSPreparing
    private let stubFilesPreparer: any NativeStubFilesPreparing
    private let nativeHandoff: any NativeRecoveryHandoffExecuting
    private let collectInstallAdmission: @Sendable () throws -> NativeInstallAdmissionFacts
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
      extractionOptions = []
      firmwarePreparer = NativeFirmwarePreparer()
      peripheralPreparer = NativeNeoPeripheralPreparer()
      apfsPreparer = NativeAPFSPreparer()
      stubFilesPreparer = NativeStubFilesPreparer()
      nativeHandoff = NativeRecoveryHandoffExecutor()
      collectInstallAdmission = { try NativeInstallAdmissionFacts.live() }
      validatePayload = { try await NativePayloadPreflight.check($0) }
      validateSourceOwner = {
        try NativeSourceOwnerAdmission().check(package: $0, authorization: $1)
      }
      prepareRecoveryTemplate = { try NativeRecoveryTemplate.prepare(package: $0) }
    }

    init(
      effectiveUserID: @escaping @Sendable () -> uid_t,
      expectedFileOwnerID: @escaping @Sendable () -> uid_t = { geteuid() },
      extractionOptions: [String] = [],
      restoreImageRequirement: String? = nil,
      verifyRestoreImage: @escaping @Sendable (URL, String) throws -> Void = {
        try RestoreImageHelper.verify($0, requirement: $1)
      },
      firmwarePreparer: any NativeFirmwarePreparing = NativeFirmwarePreparer(),
      peripheralPreparer: any NativePeripheralPreparing = NativeNeoPeripheralPreparer(),
      apfsPreparer: any NativeAPFSPreparing = NativeAPFSPreparer(),
      stubFilesPreparer: any NativeStubFilesPreparing = NativeStubFilesPreparer(),
      nativeHandoff: any NativeRecoveryHandoffExecuting = NativeRecoveryHandoffExecutor(),
      collectInstallAdmission: @escaping @Sendable () throws -> NativeInstallAdmissionFacts = {
        try NativeInstallAdmissionFacts.live()
      },
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
      self.extractionOptions = extractionOptions
      self.firmwarePreparer = firmwarePreparer
      self.peripheralPreparer = peripheralPreparer
      self.apfsPreparer = apfsPreparer
      self.stubFilesPreparer = stubFilesPreparer
      self.nativeHandoff = nativeHandoff
      self.collectInstallAdmission = collectInstallAdmission
      self.validatePayload = validatePayload
      self.validateSourceOwner = validateSourceOwner
      self.prepareRecoveryTemplate = prepareRecoveryTemplate
    }

    public func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install
    ) async throws -> Data {
      guard effectiveUserID() == 0 else {
        throw PinnedAsahiEngineExecutionError.privilegeRequired
      }
      let journal = try preparePersistentJournal(for: package)
      let recovery: PreparedNativeRecoveryTemplate
      do { recovery = try prepareRecoveryTemplate(package) } catch {
        throw preparationFailure(
          error, reason: .recoveryPreparation, operation: operation,
          journal: journal, package: package, password: authorization.password)
      }
      defer { recovery.remove() }
      if operation == .retryRecoveryAuthorization, package.installationIntent != .repair {
        return try await finalizeNativeHandoff(
          package, journal: journal, authorization: authorization,
          requirement: recovery.requirement, fullReadback: true)
      }
      do {
        guard let restoreImageRequirement, let restoreImage = package.restoreImageURL else {
          throw PinnedAsahiEngineExecutionError.restoreImageUnavailable
        }
        try verifyRestoreImage(restoreImage, restoreImageRequirement)
      } catch {
        throw preparationFailure(
          error, reason: .recoveryPreparation, operation: operation,
          journal: journal, package: package, password: authorization.password)
      }
      let nativeFinalization = package.installationIntent != .repair
      let sourceBootstrap: NativeSourceBootstrap?
      if operation == .install, nativeFinalization {
        do { sourceBootstrap = try validateSourceOwner(package, authorization) } catch {
          throw preparationFailure(
            error, reason: .recoveryPreparation, operation: operation, journal: journal,
            package: package, password: authorization.password,
            summary: "The current macOS volume owner could not be verified.")
        }
        do { try await validatePayload(package) } catch {
          let firmwareFailure = error is NativeFirmwareSelectionError
          throw preparationFailure(
            error, reason: firmwareFailure ? .firmwarePreparation : .planIntegrity,
            operation: operation, journal: journal,
            package: package, password: authorization.password,
            summary: firmwareFailure
              ? "Compatible boot firmware could not be selected."
              : "The installation images could not be verified.")
        }
      } else {
        sourceBootstrap = nil
      }
      let hadDiskWrites = !journalProvesNoMutation(
        journal, identity: RecoveryRetryIdentity(package: package))
      var environment = installEnvironment(
        package: package, authorization: authorization, operation: operation)
      environment.merge(recovery.environment) { _, new in new }
      if nativeFinalization { environment["OMARCHY_ENGINE_MODE"] = "prepare-native-handoff" }
      environment[RestoreImageHelper.pathEnvironmentVariable] = package.restoreImageURL!.path
      environment[RestoreImageHelper.requirementEnvironmentVariable] = restoreImageRequirement!
      var preparedPeripherals: PreparedNativePeripheralInputs?
      defer { preparedPeripherals?.remove() }
      if operation == .install {
        do {
          if let raw = try await firmwarePreparer.prepare(
            deviceIdentifier: package.deviceIdentifier,
            in: package.packageURL.deletingLastPathComponent())
          {
            environment["OMARCHY_NATIVE_FIRMWARE_ROOT"] = raw.path
            if nativeFinalization {
              let prepared = try await peripheralPreparer.prepare(
                package: package, rawDirectory: raw)
              preparedPeripherals = prepared
              environment.merge(prepared.environment) { _, new in new }
            }
          }
        } catch {
          throw PinnedAsahiEngineExecutionError.engineFailed(
            EngineFailureReport(
              notice: EngineFailureNotice(
                reason: .firmwarePreparation, exitStatus: 1,
                diskUnchanged: journalProvesNoMutation(
                  journal, identity: RecoveryRetryIdentity(package: package)),
                summary: "Native firmware preparation did not complete."),
              redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
                Data(String(describing: error).utf8), truncated: false,
                secrets: [authorization.password])))
        }
      }
      let preparedAPFS: (any NativeAPFSExecuting)?
      let preparedStubFiles: (any NativeStubFilesExecuting)?
      do {
        preparedAPFS =
          operation == .install && nativeFinalization
          ? try await apfsPreparer.preflight(package) : nil
        preparedStubFiles =
          preparedAPFS == nil ? nil : try await stubFilesPreparer.preflight(package)
        if preparedStubFiles != nil { environment["OMARCHY_NATIVE_STUB_FILES"] = "helper-files-v1" }
        if preparedAPFS != nil {
          guard let sourceBootstrap else { throw NativeHandoffValidationError.invalidOwner }
          environment["OMARCHY_NATIVE_APFS_TARGET"] = "helper-target-v1"
          environment["OMARCHY_NATIVE_STUB_VOLUMES"] = "helper-volumes-v1"
          environment["OMARCHY_NATIVE_SOURCE_BOOTSTRAP"] = String(
            decoding:
              try JSONSerialization.data(
                withJSONObject: sourceBootstrap.configuration,
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
      } catch {
        throw preparationFailure(
          error, reason: .planIntegrity, operation: operation,
          journal: journal, package: package, password: authorization.password,
          summary: "Native disk preparation could not be verified.")
      }
      do {
        let result = try await run(
          archive: package.engineURL,
          executionParent: package.packageURL.deletingLastPathComponent(),
          journal: journal,
          additionalEnvironment: environment,
          standardInput: nativeFinalization ? nil : authorization.password + Data([10]),
          secrets: [authorization.password],
          retryIdentity: RecoveryRetryIdentity(package: package),
          beforeLaunch: {
            guard operation == .install else { return }
            do {
              if let preparedAPFS {
                guard let sourceBootstrap else { throw NativeHandoffValidationError.invalidOwner }
                try preparedAPFS.prepareTarget(
                  journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
                try await preparedStubFiles?.prepare(
                  journal: journal, authorization: authorization,
                  sourceBootstrap: sourceBootstrap)
              } else {
                let bytes = try self.readAdmissionJournal(journal)
                try NativeInstallAdmission.check(
                  package: package, journal: bytes, collect: self.collectInstallAdmission,
                  readEvidence: {
                    try self.readCheckpointEvidence(journal: journal, identifier: $0)
                  })
              }
            } catch {
              throw PinnedAsahiEngineExecutionError.engineFailed(
                EngineFailureReport(
                  notice: EngineFailureNotice(
                    reason: error as? NativeInstallAdmissionError == .invalidJournal
                      ? .planIntegrity : .diskLayoutChanged,
                    exitStatus: 1,
                    diskUnchanged: self.journalProvesNoMutation(
                      journal, identity: RecoveryRetryIdentity(package: package)),
                    summary: "The current disk could not be admitted for a fresh installation."),
                  redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
                    Data(String(describing: error).utf8), truncated: false,
                    secrets: [authorization.password])))
            }
          }
        )
        if nativeFinalization {
          return try await finalizeNativeHandoff(
            package, journal: journal, authorization: authorization,
            requirement: recovery.requirement, fullReadback: hadDiskWrites)
        }
        return result
      } catch PinnedAsahiEngineExecutionError.launchFailed where preparedAPFS != nil {
        throw preparationFailure(
          PinnedAsahiEngineExecutionError.launchFailed,
          reason: .unclassified, operation: operation, journal: journal, package: package,
          password: authorization.password,
          summary: "The installation backend could not be started.")
      } catch PinnedAsahiEngineExecutionError.restoreImageUnsupported {
        throw preparationFailure(
          PinnedAsahiEngineExecutionError.restoreImageUnsupported,
          reason: .recoveryPreparation, operation: operation, journal: journal, package: package,
          password: authorization.password)
      } catch PinnedAsahiEngineExecutionError.recoveryTemplateUnsupported {
        throw preparationFailure(
          PinnedAsahiEngineExecutionError.recoveryTemplateUnsupported,
          reason: .recoveryPreparation, operation: operation,
          journal: journal, package: package, password: authorization.password)
      }
    }

    private func finalizeNativeHandoff(
      _ package: ImportedEngineHandoffPackage, journal: URL,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool
    ) async throws -> Data {
      do {
        return try await nativeHandoff.execute(
          package: package, journal: journal,
          authorization: authorization, requirement: requirement, fullReadback: fullReadback)
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

    private func preparationFailure(
      _ error: any Error, reason: EngineFailureReason, operation: EngineHandoffOperation,
      journal: URL, package: ImportedEngineHandoffPackage, password: Data,
      summary: String = "Native Recovery resources could not be verified."
    ) -> PinnedAsahiEngineExecutionError {
      .engineFailed(
        EngineFailureReport(
          notice: EngineFailureNotice(
            reason: reason, exitStatus: 1,
            diskUnchanged: operation == .install
              && journalProvesNoMutation(journal, identity: RecoveryRetryIdentity(package: package)),
            summary: summary),
          redactedStandardErrorTail: EngineStandardErrorRedactor.redact(
            Data(String(describing: error).utf8), truncated: false, secrets: [password])))
    }

    public func inspect(
      _ archive: PinnedAsahiEngineArchive,
      repairManifestURL: URL? = nil,
      in scratchDirectory: URL
    ) async throws -> Data {
      try validateJournalDirectory(scratchDirectory)
      return try await run(
        archive: archive.fileURL,
        expectedDigest: archive.expectedDigest,
        expectedSizeBytes: archive.expectedSizeBytes,
        executionParent: scratchDirectory,
        journal: nil,
        additionalEnvironment: repairEnvironment(
          mode: "inspect",
          repairManifestURL: repairManifestURL
        )
      )
    }

    public func plan(
      _ archive: PinnedAsahiEngineArchive,
      request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity,
      repairManifestURL: URL? = nil,
      in scratchDirectory: URL
    ) async throws -> Data {
      try validateJournalDirectory(scratchDirectory)
      let inputDirectory = scratchDirectory.appendingPathComponent(
        "engine-plan-input-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: inputDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: inputDirectory) }

      let requestURL = inputDirectory.appendingPathComponent("request.json")
      let identityURL = inputDirectory.appendingPathComponent("identity.json")
      try writePrivateJSON(request, to: requestURL)
      try writePrivateJSON(identity, to: identityURL)
      return try await run(
        archive: archive.fileURL,
        expectedDigest: archive.expectedDigest,
        expectedSizeBytes: archive.expectedSizeBytes,
        executionParent: scratchDirectory,
        journal: nil,
        additionalEnvironment: repairEnvironment(
          mode: "plan",
          repairManifestURL: repairManifestURL,
          additional: [
            "OMARCHY_ENGINE_MODE": "plan",
            "OMARCHY_ENGINE_REQUEST": requestURL.path,
            "OMARCHY_ENGINE_IDENTITY": identityURL.path,
          ]
        )
      )
    }

    private func run(
      archive: URL,
      expectedDigest: String? = nil,
      expectedSizeBytes: UInt64? = nil,
      executionParent: URL,
      journal: URL?,
      additionalEnvironment: [String: String],
      standardInput: Data? = nil,
      secrets: [Data] = [],
      retryIdentity: RecoveryRetryIdentity? = nil,
      beforeLaunch: (() async throws -> Void)? = nil
    ) async throws -> Data {
      try validateArchive(
        archive,
        expectedDigest: expectedDigest,
        expectedSizeBytes: expectedSizeBytes
      )

      let executionRoot =
        executionParent
        .appendingPathComponent(
          "engine-execution-\(UUID().uuidString.lowercased())",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: executionRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: executionRoot) }

      let bundle = executionRoot.appendingPathComponent(
        "bundle",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: bundle,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try validateArchiveEntries(archive)
      try extract(archive, into: bundle)
      try validateExtractedBundle(bundle)
      if additionalEnvironment[RestoreImageHelper.pathEnvironmentVariable] != nil {
        let capability = bundle.appendingPathComponent("engine-capabilities.json")
        guard let bytes = try? Data(contentsOf: capability), bytes.count <= 65536,
          let values = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          values["schema"] as? Int == 1,
          values["signedHelperInput"] as? String == "helper-executable-v1"
        else { throw PinnedAsahiEngineExecutionError.restoreImageUnsupported }
      }
      if additionalEnvironment["OMARCHY_RECOVERY_APP"] != nil {
        do {
          let capabilities = bundle.appendingPathComponent("engine-capabilities.json")
          try requireRegularFile(capabilities, executable: false)
          guard
            let values = try JSONSerialization.jsonObject(with: Data(contentsOf: capabilities))
              as? [String: Any],
            values["schema"] as? Int == 1,
            values["nativeRecoveryInput"] as? String == "helper-template-v1",
            additionalEnvironment["OMARCHY_ENGINE_MODE"] != "prepare-native-handoff"
              || values["nativeHandoff"] as? String == "helper-finalize-v1",
            additionalEnvironment["OMARCHY_NATIVE_FIRMWARE_ROOT"] == nil
              || values["nativeFirmwareInput"] as? String == "helper-raw-v1",
            additionalEnvironment["OMARCHY_NATIVE_PERIPHERALS"] == nil
              || values["nativePeripheralInput"] as? String == "helper-converted-v1",
            additionalEnvironment["OMARCHY_NATIVE_APFS_TARGET"] == nil
              || values["nativeAPFSInput"] as? String == "helper-target-v1",
            additionalEnvironment["OMARCHY_NATIVE_STUB_VOLUMES"] == nil
              || values["nativeStubInput"] as? String == "helper-volumes-v1",
            additionalEnvironment["OMARCHY_NATIVE_STUB_FILES"] == nil
              || values["nativeStubFiles"] as? String == "helper-files-v1"
          else { throw PinnedAsahiEngineExecutionError.recoveryTemplateUnsupported }
        } catch {
          throw PinnedAsahiEngineExecutionError.recoveryTemplateUnsupported
        }
      }

      let transcriptURL =
        journal
        ?? executionRoot.appendingPathComponent(
          "transcript.jsonl",
          isDirectory: false
        )
      let process = Process()
      process.executableURL = Self.pythonURL(in: bundle)
      process.arguments = [bundle.appendingPathComponent("main.py").path]
      process.environment = environment(
        bundle: bundle,
        executionRoot: executionRoot,
        journal: transcriptURL,
        additional: additionalEnvironment
      )
      process.environment?["OMARCHY_PERFORMANCE_LOG"] = transcriptURL.path + ".performance.jsonl"
      process.currentDirectoryURL = bundle
      let inputPipe = standardInput == nil ? nil : Pipe()
      process.standardInput = inputPipe ?? FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      // stderr is drained concurrently into a bounded tail so a chatty engine
      // can neither block on a full pipe nor grow the helper's memory.
      let errorPipe = Pipe()
      process.standardError = errorPipe
      let errorCollector = BoundedStandardErrorCollector()
      do {
        try errorCollector.start(reading: errorPipe.fileHandleForReading)
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      // Every exit from here, including a failed stdin write, stops the reader.
      defer { errorCollector.cancel() }
      try await beforeLaunch?()
      do {
        try process.run()
        if let standardInput, let inputPipe {
          try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
          try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      let capturedError = errorCollector.finish()
      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        if let journal, let retryIdentity,
          isRecoveryAuthorizationRetryEligible(
            journal: journal,
            identity: retryIdentity
          )
        {
          throw PinnedAsahiEngineExecutionError
            .recoveryAuthorizationFailed
        }
        throw PinnedAsahiEngineExecutionError.engineFailed(
          failureReport(
            standardError: capturedError,
            secrets: secrets,
            exitStatus: process.terminationStatus,
            journal: journal,
            identity: retryIdentity
          )
        )
      }
      return try readTranscript(transcriptURL)
    }

    private func failureReport(
      standardError: (data: Data, truncated: Bool),
      secrets: [Data],
      exitStatus: Int32,
      journal: URL?,
      identity: RecoveryRetryIdentity?
    ) -> EngineFailureReport {
      let redacted = EngineStandardErrorRedactor.redact(
        standardError.data,
        truncated: standardError.truncated,
        secrets: secrets
      )
      let final = EngineStandardErrorRedactor.finalException(in: redacted)
      let reason =
        final.map {
          EngineFailureReason.classify(exception: $0.exception, message: $0.message)
        } ?? .unclassified
      return EngineFailureReport(
        notice: EngineFailureNotice(
          reason: reason,
          exitStatus: exitStatus,
          diskUnchanged: journal.map { journalProvesNoMutation($0, identity: identity) } ?? false,
          summary: final.map {
            EngineStandardErrorRedactor.summary(from: $0.line, secrets: secrets)
          } ?? ""
        ),
        redactedStandardErrorTail: redacted
      )
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
      return isRecoveryAuthorizationRetryEligible(
        journal: journal, identity: RecoveryRetryIdentity(identity: identity))
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

    private func installEnvironment(
      package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) -> [String: String] {
      var environment = [
        "OMARCHY_ENGINE_MODE": operation.rawValue,
        "OMARCHY_ENGINE_REQUEST": package.requestURL.path,
        "OMARCHY_ENGINE_IDENTITY": package.identityURL.path,
        "OMARCHY_ENGINE_METADATA": package.metadataURL.path,
        "OMARCHY_ENGINE_PAYLOAD": package.payloadURL.path,
        "OMARCHY_ENGINE_BINDING_DIGEST": package.bindingDigest,
        "OMARCHY_ENGINE_PLAN_DIGEST": package.planDigest,
        "OMARCHY_MACHINE_OWNER": authorization.username,
        "DISTRO": "Aurora",
        "OMARCHY_INSTALLER_NAME": InstallerProductIdentity.appName,
        "DISTRO_DOCS": "https://omarchy.org/manual/",
      ]
      if let repairManifestURL = package.repairManifestURL {
        environment["OMARCHY_ENGINE_REPAIR_MANIFEST"] =
          repairManifestURL.path
      }
      return environment
    }

    private func repairEnvironment(
      mode: String,
      repairManifestURL: URL?,
      additional: [String: String] = [:]
    ) -> [String: String] {
      var environment = additional
      environment["OMARCHY_ENGINE_MODE"] = mode
      if let repairManifestURL {
        environment["OMARCHY_ENGINE_REPAIR_MANIFEST"] =
          repairManifestURL.path
      }
      return environment
    }

    private func environment(
      bundle: URL,
      executionRoot: URL,
      journal: URL,
      additional: [String: String]
    ) -> [String: String] {
      var values = [
        "HOME": executionRoot.path,
        "TMPDIR": executionRoot.path,
        "PATH": [
          bundle.appendingPathComponent("bin").path,
          "/usr/bin",
          "/bin",
          "/usr/sbin",
          "/sbin",
        ].joined(separator: ":"),
        "LC_ALL": "C",
        "LANG": "C",
        "DYLD_LIBRARY_PATH": bundle.appendingPathComponent(
          "Frameworks/Python.framework/Versions/Current/lib"
        ).path,
        "DYLD_FRAMEWORK_PATH": bundle.appendingPathComponent(
          "Frameworks"
        ).path,
        "SSL_CERT_FILE": bundle.appendingPathComponent(
          "Frameworks/Python.framework/Versions/Current/etc/openssl/cert.pem"
        ).path,
        "OMARCHY_ENGINE_JOURNAL": journal.path,
      ]
      values.merge(additional) { _, new in new }
      return values
    }

    private func validateArchive(
      _ archive: URL,
      expectedDigest: String?,
      expectedSizeBytes: UInt64?
    ) throws {
      let descriptor = Darwin.open(
        archive.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeArchive
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumArchiveBytes
      else {
        throw PinnedAsahiEngineExecutionError.unsafeArchive
      }

      if let expectedSizeBytes {
        guard UInt64(status.st_size) == expectedSizeBytes else {
          throw PinnedAsahiEngineExecutionError.archiveSizeMismatch
        }
      }
      if let expectedDigest {
        let handle = FileHandle(
          fileDescriptor: descriptor,
          closeOnDealloc: false
        )
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576),
          !chunk.isEmpty
        {
          hasher.update(data: chunk)
          bytesRead += UInt64(chunk.count)
        }
        guard bytesRead == UInt64(status.st_size) else {
          throw PinnedAsahiEngineExecutionError.unsafeArchive
        }
        let digest = SHA256Digest.prefixedHex(hasher.finalize())
        guard digest == expectedDigest else {
          throw PinnedAsahiEngineExecutionError.archiveDigestMismatch
        }
      }
    }

    private func validateArchiveEntries(_ archive: URL) throws {
      let output = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-tzf", archive.path]
      process.environment = Self.systemEnvironment
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      let listing = try output.fileHandleForReading.readToEnd() ?? Data()
      process.waitUntilExit()
      guard process.terminationReason == .exit,
        process.terminationStatus == 0,
        !listing.isEmpty,
        listing.count <= 8_388_608,
        let names = String(data: listing, encoding: .utf8)
      else {
        throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
      }

      for name in names.split(
        separator: "\n",
        omittingEmptySubsequences: true
      ) {
        guard !name.isEmpty,
          name.utf8.count <= 1_024,
          !name.hasPrefix("/")
        else {
          throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
        }
        let components = name.split(
          separator: "/",
          omittingEmptySubsequences: false
        )
        guard !components.contains("..") else {
          throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
        }
      }
    }

    private func extract(_ archive: URL, into bundle: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments =
        extractionOptions + [
          "-xzf", archive.path, "-C", bundle.path, "--no-same-owner",
          "--no-same-permissions",
        ]
      process.environment = Self.systemEnvironment
      process.currentDirectoryURL = bundle
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        throw PinnedAsahiEngineExecutionError.extractionFailed(
          process.terminationStatus
        )
      }
    }

    private func validateExtractedBundle(_ bundle: URL) throws {
      guard
        let enumerator = FileManager.default.enumerator(
          at: bundle,
          includingPropertiesForKeys: nil,
          options: [],
          errorHandler: { _, _ in false }
        )
      else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }

      while let url = enumerator.nextObject() as? URL {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
          throw PinnedAsahiEngineExecutionError.invalidBundle
        }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFREG || kind == S_IFDIR {
          guard status.st_mode & 0o022 == 0 else {
            throw PinnedAsahiEngineExecutionError.invalidBundle
          }
        } else if kind == S_IFLNK {
          try validateSymlink(url, beneath: bundle)
        } else {
          throw PinnedAsahiEngineExecutionError.invalidBundle
        }
      }

      try requireRegularFile(
        bundle.appendingPathComponent("main.py"),
        executable: false
      )
      try requireRegularFile(Self.pythonURL(in: bundle), executable: true)
    }

    private func validateSymlink(_ url: URL, beneath bundle: URL) throws {
      let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: url.path
      )
      guard !target.isEmpty, !target.hasPrefix("/") else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }
      var depth =
        url.deletingLastPathComponent().pathComponents.count
        - bundle.pathComponents.count
      for component in target.split(
        separator: "/",
        omittingEmptySubsequences: false
      ) {
        if component == ".." {
          depth -= 1
          guard depth >= 0 else {
            throw PinnedAsahiEngineExecutionError.invalidBundle
          }
        } else if component != "." && !component.isEmpty {
          depth += 1
        }
      }
    }

    private func requireRegularFile(
      _ url: URL,
      executable: Bool
    ) throws {
      var status = stat()
      guard lstat(url.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        !executable || status.st_mode & 0o111 != 0
      else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }
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

    private func writePrivateJSON<T: Encodable>(
      _ value: T,
      to destination: URL
    ) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(value)
      try data.write(to: destination, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: destination.path
      )
    }

    private static func pythonURL(in bundle: URL) -> URL {
      bundle.appendingPathComponent(
        "Frameworks/Python.framework/Versions/3.13/bin/python3.13"
      )
    }

    private static let systemEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LC_ALL": "C",
      "LANG": "C",
    ]

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
