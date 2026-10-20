#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// Replaces only signed ESP payload members on the existing EFI partition.
  /// The original files remain as verified rollback names until completion.
  struct NativePreservedESPExecution: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let prepared: NativePreservedInstallAdmission.Prepared
    var disks: NativeAPFSPlatform = .live
    var verifyMount: @Sendable (Int32, URL, String) throws -> Void =
      NativeHandoffFileTree.verifyVolumeRoot
    var admitFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT

    func prepare(
      journal: NativePreservedInstallJournal, espRoot: URL,
      boot: NativeRawImageReceipt, root: NativeRawImageReceipt,
      installedStage1: NativeStubFileIdentity,
      authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) async throws -> (files: [NativePreservedESPEntryReceipt], digest: String) {
      let state = try journal.snapshot()
      let target = prepared.target
      let baseline = prepared.diskSnapshot
      guard package.installationIntent == .reinstall, state.plan == approved,
        state.targetIdentity == target.identityDigest, state.state == .started,
        state.transcript.starts(with: prepared.transcript),
        target.disk == baseline.disk, baseline.disk == approved.storeIdentifier,
        installedStage1 == prepared.stage1,
        try journal.imageReceipt("boot") == boot,
        try journal.imageReceipt("root") == root,
        boot.partitionIdentifier == target.boot.identifier,
        root.partitionIdentifier == target.root.identifier,
        boot.partitionUUID == target.boot.uuid.lowercased(),
        root.partitionUUID == target.root.uuid.lowercased(),
        boot.partitionSizeBytes == target.boot.size,
        root.partitionSizeBytes == target.root.size
      else { throw NativePreservedInstallError.changedLayout }
      try disks.verifySourceOwner(package, authorization, bootstrap)
      let verify: @Sendable () throws -> Void = {
        guard try disks.snapshot() == baseline else {
          throw NativePreservedInstallError.changedLayout
        }
        try disks.verifyPartition(target.esp, baseline.disk)
      }
      try verify()
      let store = try NativeESPFileStore(
        root: espRoot, volumeDevice: target.esp.identifier,
        namespace: approved.planDigest + "-preserve",
        verifyMount: verifyMount, admitFilesystem: admitFilesystem)
      var receipts = [NativePreservedESPEntryReceipt]()
      for entry in prepared.esp.entries {
        try Task.checkCancellation()
        try verify()
        let bytes = try await prepared.esp.archive.read(
          entry.member, maximumBytes: 64 << 20)
        let installed = NativeStubFileIdentity(
          bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
        let baselineEntry: NativePreservedESPBaseline
        if let existing = try journal.espBaseline(entry.path) {
          guard existing.member == entry.member.name, existing.installed == installed else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
          baselineEntry = existing
        } else {
          let previous: NativeStubFileIdentity?
          if try store.tree.isAbsent(entry.path) {
            previous = nil
          } else {
            previous = try store.identity(entry.path, maximum: 64 << 20)
          }
          baselineEntry = NativePreservedESPBaseline(
            member: entry.member.name, path: entry.path,
            previous: previous, installed: installed)
          try journal.recordESPBaseline(baselineEntry)
        }
        if let recorded = try journal.espReceipt(entry.path) {
          guard recorded.member == entry.member.name, recorded.installed == installed,
            try store.identity(entry.path, maximum: bytes.count) == installed
          else { throw NativeHandoffValidationError.changedContent }
          if let backup = recorded.backup {
            guard try store.identity(backup.backupPath, maximum: backup.previous.bytes)
              == backup.previous
            else { throw NativeHandoffValidationError.changedContent }
          } else {
            guard try store.tree.isAbsent(store.replacementPaths(entry.path).backup) else {
              throw NativeHandoffValidationError.changedContent
            }
          }
          receipts.append(recorded)
          continue
        }
        let backup: NativeESPFileStore.ReplacementReceipt?
        if let previous = baselineEntry.previous, previous != installed {
          backup = try await store.replaceData(bytes, replacing: previous, at: entry.path)
        } else if baselineEntry.previous == installed {
          guard try store.tree.isAbsent(store.replacementPaths(entry.path).backup) else {
            throw NativeHandoffValidationError.changedContent
          }
          guard try store.identity(entry.path, maximum: bytes.count) == installed else {
            throw NativeHandoffValidationError.changedContent
          }
          backup = nil
        } else {
          guard try store.tree.isAbsent(store.replacementPaths(entry.path).backup) else {
            throw NativeHandoffValidationError.changedContent
          }
          guard try await store.data(bytes, at: entry.path) == installed else {
            throw NativeStubFileError.changedFile
          }
          backup = nil
        }
        let receipt = NativePreservedESPEntryReceipt(
          member: entry.member.name, path: entry.path,
          installed: installed, backup: backup)
        try journal.recordESP(receipt)
        receipts.append(receipt)
      }
      try verify()
      var fields = [approved.planDigest, target.identityDigest, target.esp.uuid.lowercased()]
      for receipt in receipts.sorted(by: { $0.path < $1.path }) {
        fields += [
          receipt.member, receipt.path, String(receipt.installed.bytes), receipt.installed.sha256,
          receipt.backup?.previous.sha256 ?? "",
        ]
      }
      return (receipts, InstallerDigest.lengthPrefixedSHA256(fields).hexadecimal)
    }
  }
#endif
