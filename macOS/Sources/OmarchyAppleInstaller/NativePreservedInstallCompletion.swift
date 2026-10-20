#if os(macOS)
  import Darwin
  import Foundation

  /// Complete only after the preserved layout and all installed file identities
  /// are rechecked, then select the already enrolled Stage 1 boot target.
  struct NativePreservedInstallCompletion: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let prepared: NativePreservedInstallAdmission.Prepared
    let selectBoot:
      @Sendable (NativePreservedInstallTarget, MachineOwnerAuthorization) throws -> Void
    let verifySelection: @Sendable (NativePreservedInstallTarget) throws -> Void
    var platform: NativePayloadImagePlatform = .init()
    var verifyMount: @Sendable (Int32, URL, String) throws -> Void =
      NativeHandoffFileTree.verifyVolumeRoot
    var admitFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT

    func finish(
      journal: NativePreservedInstallJournal, espRoot: URL,
      boot: NativeRawImageReceipt, root: NativeRawImageReceipt,
      espFiles: [NativePreservedESPEntryReceipt], espDigest: String,
      installedStage1: NativeStubFileIdentity,
      authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) throws -> Data {
      let saved = try journal.snapshot()
      let target = prepared.target
      let baseline = prepared.diskSnapshot
      let calculatedESPDigest = NativePreservedESPExecution.digest(
        espFiles, approved: approved, target: target)
      guard package.installationIntent == .reinstall, saved.plan == approved,
        saved.targetIdentity == target.identityDigest,
        saved.state == .started || saved.state == .written || saved.state == .complete,
        installedStage1 == prepared.stage1,
        try journal.imageReceipt("boot") == boot,
        try journal.imageReceipt("root") == root,
        boot.partitionIdentifier == target.boot.identifier,
        root.partitionIdentifier == target.root.identifier,
        boot.partitionUUID == target.boot.uuid.lowercased(),
        root.partitionUUID == target.root.uuid.lowercased(),
        boot.partitionSizeBytes == target.boot.size,
        root.partitionSizeBytes == target.root.size,
        espFiles.count == prepared.esp.entries.count,
        zip(espFiles, prepared.esp.entries).allSatisfy({ pair in
          pair.0.member == pair.1.member.name && pair.0.path == pair.1.path
        }),
        espDigest == calculatedESPDigest
      else { throw NativePreservedInstallError.changedLayout }
      try platform.disks.verifySourceOwner(package, authorization, bootstrap)
      let store = try NativeESPFileStore(
        root: espRoot, volumeDevice: target.esp.identifier,
        namespace: approved.planDigest + "-preserve",
        verifyMount: verifyMount, admitFilesystem: admitFilesystem)
      func verifyCurrent(fullRaw: Bool, journalEvidence: Bool) throws {
        guard try platform.disks.snapshot() == baseline else {
          throw NativePreservedInstallError.changedLayout
        }
        for part in [target.esp, target.boot, target.root] {
          try platform.disks.verifyPartition(part, baseline.disk)
        }
        if fullRaw {
          guard
            try platform.digest(target.boot.identifier, boot.installedBytes)
              == boot.contentSHA256,
            try platform.digest(target.root.identifier, root.installedBytes)
              == root.contentSHA256
          else { throw NativeHandoffValidationError.changedContent }
        }
        for file in espFiles {
          if journalEvidence {
            guard try journal.espReceipt(file.path) == file else {
              throw NativeHandoffValidationError.changedContent
            }
          }
          guard
            try store.identity(file.path, maximum: file.installed.bytes) == file.installed
          else {
            throw NativeHandoffValidationError.changedContent
          }
          if let backup = file.backup {
            guard
              try store.identity(backup.backupPath, maximum: backup.previous.bytes)
                == backup.previous
            else { throw NativeHandoffValidationError.changedContent }
          } else {
            guard try store.tree.isAbsent(store.replacementPaths(file.path).backup) else {
              throw NativeHandoffValidationError.changedContent
            }
          }
        }
      }
      try verifyCurrent(fullRaw: true, journalEvidence: true)
      let receipt = NativePreservedInstallReceipt(
        planDigest: approved.planDigest, targetIdentity: target.identityDigest,
        espUUID: target.esp.uuid.lowercased(), boot: boot, root: root,
        espDigest: espDigest)
      try journal.recordWritten(receipt)
      if saved.state == .complete {
        try verifySelection(target)
        return try journal.snapshot().transcript
      }
      try selectBoot(target, authorization)
      try verifySelection(target)
      try journal.complete { recorded in
        guard recorded == receipt else { throw NativeRecoveryJournalError.evidenceChanged }
        try verifyCurrent(fullRaw: false, journalEvidence: false)
        try verifySelection(target)
      }
      return try journal.snapshot().transcript
    }
  }
#endif
