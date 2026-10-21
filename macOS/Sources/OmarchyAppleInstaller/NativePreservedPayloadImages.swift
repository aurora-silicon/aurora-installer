#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// Rewrite only the existing Linux image partitions. Stage 1, the APFS
  /// container and the partition map are read-only throughout this stage.
  struct NativePreservedPayloadImagesExecution: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let prepared: NativePreservedInstallAdmission.Prepared
    var platform: NativePayloadImagePlatform = .init()

    func prepare(
      journal: NativePreservedInstallJournal,
      authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) async throws -> (boot: NativeRawImageReceipt, root: NativeRawImageReceipt) {
      let saved = try journal.snapshot()
      let target = prepared.target
      let baseline = prepared.diskSnapshot
      let planned = try AppleInstallerTrustCore().validateEngineTranscript(prepared.transcript)
      guard package.installationIntent == .reinstall, approved.candidateKind == "reinstall",
        saved.plan == approved, planned.plan == approved,
        saved.targetIdentity == target.identityDigest,
        planned.inventory?.candidates.contains(where: {
          $0.kind == "reinstall" && $0.sourceIdentifier == target.stub.identifier
            && $0.identityDigest == target.identityDigest
        }) == true,
        saved.transcript.starts(with: prepared.transcript),
        saved.state == .ready || saved.state == .started,
        baseline.disk == approved.storeIdentifier, target.disk == baseline.disk,
        approved.offsetBytes == target.stub.offset,
        approved.lengthBytes == target.root.end - target.stub.offset,
        baseline.containers.filter({ $0.storeUUID == target.stub.uuid }).count == 1,
        baseline.containers.contains(where: { container in
          container.storeUUID == target.stub.uuid
            && container.volumes.filter({
              $0.roles == ["System"] && $0.group == target.group && $0.name == target.title
            }).count == 1
        }),
        [target.stub, target.esp, target.boot, target.root].allSatisfy({ part in
          baseline.partitions.contains {
            $0.identifier == part.identifier && $0.uuid == part.uuid && $0 == part
          }
        })
      else { throw NativePreservedInstallError.changedLayout }
      try platform.disks.verifySourceOwner(package, authorization, bootstrap)
      let disks = platform.disks
      let verify: @Sendable (RemovalPartition) throws -> Void = { partition in
        guard try disks.snapshot() == baseline else {
          throw NativePreservedInstallError.changedLayout
        }
        try disks.verifyPartition(partition, baseline.disk)
      }
      try verify(target.boot)
      try verify(target.root)
      try journal.begin()
      let boot = try await image(
        prepared.boot, partition: target.boot, name: "boot", journal: journal,
        verify: verify)
      let root = try await image(
        prepared.root, partition: target.root, name: "root", journal: journal,
        verify: verify)
      return (boot, root)
    }

    private func image(
      _ member: IPSWArchiveMember, partition: RemovalPartition, name: String,
      journal: NativePreservedInstallJournal,
      verify: @escaping @Sendable (RemovalPartition) throws -> Void
    ) async throws -> NativeRawImageReceipt {
      if let saved = try journal.imageReceipt(name) {
        guard saved.partitionIdentifier == partition.identifier,
          saved.partitionUUID == partition.uuid.lowercased(),
          saved.partitionSizeBytes == partition.size,
          saved.installedBytes == UInt64(member.sizeBytes),
          saved.verification == "source-sha256-write-flushed-v1"
        else { throw NativeRawImageError.invalidTarget }
        try verify(partition)
        guard
          try platform.digest(partition.identifier, saved.installedBytes)
            == saved.contentSHA256
        else { throw NativeHandoffValidationError.changedContent }
        try verify(partition)
        return saved
      }
      let receipt = try await NativeRawImageWriter.write(
        archive: prepared.archive, member: member, partition: partition,
        platform: platform.writer, verify: verify)
      try journal.recordImage(receipt, name: name)
      return receipt
    }
  }
#endif
