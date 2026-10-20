#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  protocol NativePayloadImagesExecuting: Sendable {
    func prepare(journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) async throws
  }
  protocol NativePayloadImagesPreparing: Sendable {
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> any NativePayloadImagesExecuting
  }

  struct NativePayloadImagePlatform: Sendable {
    var disks: NativeAPFSPlatform = .live
    var writer: NativeRawImagePlatform = .live
    var digest: @Sendable (String, UInt64) throws -> String = NativeHandoffRawReader.digest
  }

  struct NativePayloadImagesPreparer: NativePayloadImagesPreparing {
    var owner: uid_t = 0
    var platform = NativePayloadImagePlatform()
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> any NativePayloadImagesExecuting {
      let approved = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let archive = try await IPSWArchive.open(NativePayloadRangeReader(package.payloadURL, owner: owner))
      let names = ["boot.img", "root.img"]
      let members = try names.map { name in
        let found = archive.members.filter { $0.name == name && !$0.isDirectory }
        guard found.count == 1, found[0].sizeBytes > 0, found[0].sizeBytes % 4096 == 0 else {
          throw NativeRawImageError.invalidImage
        }
        return found[0]
      }
      return NativePayloadImagesExecution(package: package, approved: approved,
        archive: archive, members: members, owner: owner, platform: platform)
    }
  }

  struct NativePayloadImagesExecution: NativePayloadImagesExecuting {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let archive: IPSWArchive
    let members: [IPSWArchiveMember]
    let owner: uid_t
    let platform: NativePayloadImagePlatform

    func prepare(journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) async throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(file.readJournal())
      guard transcript.plan == approved else { throw NativeOSPartitionError.changedLayout }
      if transcript.checkpoints.contains(where: { $0.identifier == "stub-and-esp-installed" }) { return }
      guard transcript.checkpoints.map(\.identifier) == ["apfs-target-prepared"],
        try file.readJournal().split(separator: 10).count == 5, members.map(\.name) == ["boot.img", "root.img"]
      else { throw NativeOSPartitionError.changedLayout }
      let receipt = try JSONDecoder().decode(NativeOSPartitionsExecution.Receipt.self,
        from: file.readEvidence("native-os-partitions"))
      let baseline = try platform.disks.snapshot()
      _ = try NativeDiskInventory.extents(baseline)
      let end = try NativeInspectionMath.add(approved.offsetBytes, approved.lengthBytes)
      guard receipt.plan == approved.planDigest, receipt.partitions.count == 3,
        receipt.layout.parts.count == 3, baseline.disk == approved.storeIdentifier,
        let stub = baseline.partitions.first(where: { $0.uuid == receipt.stubUUID }),
        stub.type == "Apple_APFS", stub.offset == approved.offsetBytes
      else { throw NativeOSPartitionError.changedLayout }
      var offset = stub.end
      var liveParts = [RemovalPartition]()
      for (index, saved) in receipt.partitions.enumerated() {
        guard let live = baseline.partitions.first(where: { $0.uuid == saved.uuid }), live == saved,
          live.offset == offset, live.size == receipt.layout.parts[index].bytes,
          live.type == (index == 0 ? "EFI" : "Linux Filesystem"), live.end <= end
        else { throw NativeOSPartitionError.changedLayout }
        liveParts.append(live)
        offset = live.end
      }
      guard offset == end else { throw NativeOSPartitionError.changedLayout }
      try platform.disks.verifySourceOwner(package, authorization, sourceBootstrap)
      let verify: @Sendable (RemovalPartition) throws -> Void = { partition in
        guard try self.platform.disks.snapshot() == baseline else { throw NativeOSPartitionError.changedLayout }
        try self.platform.disks.verifyPartition(partition, baseline.disk)
      }
      for (member, partition) in zip(members, liveParts.dropFirst()) {
        let name = "native-image-" + String(member.name.dropLast(4))
        let identity: NativeRawImageReceipt
        if try file.containsEvidence(name) {
          identity = try JSONDecoder().decode(NativeRawImageReceipt.self, from: file.readEvidence(name))
          guard identity.partitionUUID == partition.uuid.lowercased(),
            identity.partitionSizeBytes == partition.size, identity.installedBytes == UInt64(member.sizeBytes),
            identity.verification == "source-sha256-write-flushed-v1"
          else { throw NativeRawImageError.invalidTarget }
          try verify(partition)
          guard try platform.digest(partition.identifier, identity.installedBytes) == identity.contentSHA256 else {
            throw NativeHandoffValidationError.changedContent
          }
          try verify(partition)
        } else {
          identity = try await NativeRawImageWriter.write(archive: archive, member: member,
            partition: partition, platform: platform.writer, verify: verify)
          try file.publishEvidence(encode(identity), identifier: name)
        }
      }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(value)
    }
  }
#endif
