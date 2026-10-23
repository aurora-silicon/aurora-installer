#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  protocol NativePreservedReinstallExecuting: Sendable {
    func execute(
      _ package: ImportedEngineHandoffPackage, journal: URL,
      authorization: MachineOwnerAuthorization, installConf: InstallConf
    ) async throws -> Data
  }

  /// Runs an approved reinstall against the existing partitions. The APFS
  /// Stage 1 group and GPT identities are admitted and then never rewritten.
  struct NativePreservedInstallCoordinator: NativePreservedReinstallExecuting {
    var owner: uid_t = 0
    var platform: NativePayloadImagePlatform = .init()
    var environment: NativeHandoffEnvironment = .live
    var validatePayload: @Sendable (ImportedEngineHandoffPackage) async throws -> Void = {
      try await NativePayloadPreflight.check($0)
    }
    var validateSourceOwner:
      @Sendable (ImportedEngineHandoffPackage, MachineOwnerAuthorization) throws ->
        NativeSourceBootstrap =
        { try NativeSourceOwnerAdmission().check(package: $0, authorization: $1) }

    func execute(
      _ package: ImportedEngineHandoffPackage, journal journalURL: URL,
      authorization: MachineOwnerAuthorization, installConf: InstallConf
    ) async throws -> Data {
      guard package.installationIntent == .reinstall else {
        throw NativePreservedInstallError.unavailable
      }
      let approved = try EngineHandoffPackageImporter().preservedExecutionPlan(
        package, owner: owner)
      try await validatePayload(package)
      let bootstrap = try validateSourceOwner(package, authorization)
      let packageTree = try NativeHandoffFileTree(
        package.packageURL, protected: true, owner: owner)
      let metadata = try packageTree.read(package.metadataURL.lastPathComponent, maximum: 65_536)
      guard SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest else {
        throw NativePreservedInstallError.unavailable
      }
      _ = try NativeInstallationMetadata(data: metadata).target()
      let facts = try platform.disks.collect()
      guard facts.deviceIdentifier == package.deviceIdentifier,
        facts.disk.snapshot.disk == approved.storeIdentifier
      else { throw NativePreservedInstallError.changedLayout }
      let firmware = try NativeFirmwareSelection.choose(
        deviceIdentifier: package.deviceIdentifier,
        facts: .init(deviceIdentifier: facts.deviceIdentifier, hardware: facts.hardware),
        metadata: NativeInstallationMetadata(data: metadata),
        policy: NativeInspectionPolicy.sealed())
      let snapshot = facts.disk.snapshot
      let stubs = snapshot.partitions.filter { $0.identifier == approved.sourceIdentifier }
      guard stubs.count == 1, let stub = stubs.first,
        stub.type == "Apple_APFS",
        let container = snapshot.containers.first(where: { $0.storeUUID == stub.uuid }),
        snapshot.containers.filter({ $0.storeUUID == stub.uuid }).count == 1,
        let system = container.volumes.first(where: {
          $0.roles == ["System"] && NativeKnownInstallations.recognizedTitles.contains($0.name)
        }),
        container.volumes.filter({
          $0.roles == ["System"] && $0.name == system.name
        }).count == 1
      else { throw NativePreservedInstallError.changedLayout }
      func readStage1() throws -> Data {
        let systemMounts = NativeHandoffMounts(environment)
        let systemURL = try systemMounts.mounted(system.identifier, uuid: system.uuid)
        let systemTree = try NativeHandoffFileTree(
          systemURL, protected: true, owner: owner,
          volumeRoot: true, volumeDevice: system.identifier,
          verifyMount: environment.verifyMount)
        return try systemTree.read(
          "Finish Installation.app/Contents/Resources/boot.bin", maximum: 64 << 20)
      }
      func stage1Identity() throws -> NativeStubFileIdentity {
        let bytes = try readStage1()
        return NativeStubFileIdentity(
          bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
      }
      let installedStage1 = try readStage1()
      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: owner))
      let prepared = try await NativePreservedInstallAdmission.check(
        approved: approved, metadata: metadata, archive: archive, disk: facts.disk,
        stubBytes: firmware.stubBytes,
        firmwareVersion: firmware.version.components(separatedBy: " ")[0],
        installedStage1: installedStage1)
      let nativeJournal = try NativePreservedInstallJournal(
        url: journalURL, package: package, transcript: prepared.transcript, owner: owner)
      try nativeJournal.bindInstallConf(installConf)
      let state = try nativeJournal.snapshot()
      let currentStage1 = try stage1Identity()
      guard currentStage1 == prepared.stage1 else { throw NativeBootChainError.invalidStage1 }
      let images: (boot: NativeRawImageReceipt, root: NativeRawImageReceipt)
      let espFiles: [NativePreservedESPEntryReceipt]
      let espDigest: String
      if state.state == .ready || state.state == .started {
        // The ESP keeps its file system, so it takes the payload's volume
        // serial through the raw device while it is still unmounted. Its boot
        // sectors are admitted before the first image write.
        let espVolumeID = NativePreservedESPVolumeIDExecution(
          package: package, approved: approved, prepared: prepared,
          disks: platform.disks, device: .live(environment))
        try espVolumeID.admit(journal: nativeJournal)
        let imageWriter = NativePreservedPayloadImagesExecution(
          package: package, approved: approved, prepared: prepared, platform: platform)
        images = try await imageWriter.prepare(
          journal: nativeJournal, authorization: authorization, bootstrap: bootstrap)
        try espVolumeID.prepare(
          journal: nativeJournal, authorization: authorization, bootstrap: bootstrap)
      } else {
        guard let receipt = state.receipt else { throw NativeRecoveryJournalError.invalidState }
        images = (receipt.boot, receipt.root)
      }
      let mounts = NativeHandoffMounts(environment)
      let espURL = try mounts.mounted(
        prepared.target.esp.identifier, uuid: prepared.target.esp.uuid,
        key: "DiskUUID", writable: true)
      if state.state == .ready || state.state == .started {
        let espWriter = NativePreservedESPExecution(
          package: package, approved: approved, prepared: prepared,
          disks: platform.disks, verifyMount: environment.verifyMount)
        let published = try await espWriter.prepare(
          journal: nativeJournal, espRoot: espURL, boot: images.boot, root: images.root,
          installedStage1: try stage1Identity(),
          authorization: authorization, bootstrap: bootstrap,
          installConf: installConf)
        espFiles = published.files
        espDigest = published.digest
      } else {
        guard let receipt = state.receipt else { throw NativeRecoveryJournalError.invalidState }
        let paths = prepared.esp.entries.map(\.path) + [InstallConf.relativePath]
        espFiles = try paths.map { path in
          guard let saved = try nativeJournal.espReceipt(path) else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
          return saved
        }
        espDigest = receipt.espDigest
      }
      let selector = NativePreservedBootSelector(
        baseline: prepared.diskSnapshot, expectedStage1: prepared.stage1,
        environment: environment, owner: owner)
      var completion = NativePreservedInstallCompletion(
        package: package, approved: approved, prepared: prepared,
        selectBoot: { try selector.select($0, authorization: $1) },
        verifySelection: { try selector.verify($0) })
      completion.platform = platform
      completion.verifyMount = environment.verifyMount
      return try completion.finish(
        journal: nativeJournal, espRoot: espURL,
        boot: images.boot, root: images.root,
        espFiles: espFiles, espDigest: espDigest,
        installedStage1: try stage1Identity(),
        authorization: authorization, bootstrap: bootstrap,
        installConf: installConf)
    }
  }
#endif
