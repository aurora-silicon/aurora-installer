#if os(macOS)
  import Darwin
  import Foundation

  /// The shared, receipt-bound target for firmware and Recovery publication.
  /// Keep this value alive while using any of its verified mounted roots.
  struct NativeInstallationTarget: Sendable {
    let snapshot: RemovalSnapshot
    let partitions: NativeOSPartitionsExecution.Receipt
    let esp: RemovalPartition
    let system: RemovalVolume
    let volumes: [RemovalVolume]
    let group: String
    let mounts: NativeHandoffMounts
    let environment: NativeHandoffEnvironment
    let disks: NativeAPFSPlatform
    let owner: uid_t

    init(
      package: ImportedEngineHandoffPackage, approved: ValidatedEnginePlan,
      journal: NativeInstallJournalFile, authorization: MachineOwnerAuthorization,
      bootstrap: NativeSourceBootstrap, owner: uid_t,
      environment: NativeHandoffEnvironment, disks: NativeAPFSPlatform
    ) throws {
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(journal.readJournal())
      guard transcript.plan == approved,
        transcript.checkpoints.first?.identifier == "apfs-target-prepared"
      else { throw NativeHandoffValidationError.invalidEvidence }
      let decoder = JSONDecoder()
      let parts = try decoder.decode(
        NativeOSPartitionsExecution.Receipt.self,
        from: journal.readEvidence("native-os-partitions"))
      let snapshot = try disks.snapshot()
      _ = try NativeDiskInventory.extents(snapshot)
      var expected = try decoder.decode(
        RemovalSnapshot.self, from: journal.readEvidence("native-os-partition-baseline"))
      expected.partitions.append(contentsOf: parts.partitions)
      expected.partitions.sort { $0.offset < $1.offset }
      // Disk Arbitration reports the new ESP's FAT label only after the partition
      // receipt was recorded, as the ESP and image stages already admit.
      guard parts.plan == approved.planDigest, parts.partitions.count == 3,
        parts.layout.parts.count == 3,
        NativeESPLabelAdmission.matches(
          snapshot, recorded: expected, espUUID: parts.partitions[0].uuid,
          label: parts.layout.parts[0].fatLabel),
        snapshot.disk == approved.storeIdentifier,
        let stub = snapshot.partitions.first(where: { $0.uuid == parts.stubUUID }),
        let esp = snapshot.partitions.first(where: { $0.uuid == parts.partitions[0].uuid }),
        esp.type == "EFI", esp.offset == stub.end,
        let container = snapshot.containers.first(where: { $0.storeUUID == stub.uuid }),
        let system = container.volumes.first(where: { $0.roles == ["System"] }),
        let group = system.group
      else { throw NativeHandoffValidationError.changedLayout }
      let volumes = try NativeStubVolumes.read(
        journal.readEvidence(NativeStubVolumes.evidenceIdentifier))
      try volumes.validate(plan: approved.planDigest, target: stub, snapshot: snapshot)
      let espReceipt = try decoder.decode(
        NativeESPFilesExecution.Receipt.self, from: journal.readEvidence("native-esp-files"))
      guard espReceipt.plan == approved.planDigest, espReceipt.groupUUID == group,
        espReceipt.espUUID == esp.uuid
      else { throw NativeHandoffValidationError.invalidEvidence }
      try disks.verifySourceOwner(package, authorization, bootstrap)
      try disks.verifyPartition(esp, snapshot.disk)
      guard try disks.snapshot() == snapshot else {
        throw NativeHandoffValidationError.changedLayout
      }
      self.snapshot = snapshot
      partitions = parts
      self.esp = esp
      self.system = system
      self.volumes = container.volumes
      self.group = group
      self.owner = owner
      self.environment = environment
      self.disks = disks
      mounts = NativeHandoffMounts(environment)
    }

    func volume(_ role: String) throws -> RemovalVolume {
      let matches = volumes.filter { $0.roles == [role] }
      guard matches.count == 1 else { throw NativeHandoffValidationError.invalidTarget }
      return matches[0]
    }

    func root(_ role: String, writable: Bool = false) throws -> URL {
      let volume = try volume(role)
      return try mounts.mounted(volume.identifier, uuid: volume.uuid, writable: writable)
    }

    func tree(_ role: String, writable: Bool = false) throws -> NativeHandoffFileTree {
      let volume = try volume(role)
      return try NativeHandoffFileTree(
        root(role, writable: writable), protected: true, owner: owner,
        volumeRoot: true, volumeDevice: volume.identifier, verifyMount: environment.verifyMount)
    }

    func espRoot() throws -> URL {
      try mounts.mounted(esp.identifier, uuid: esp.uuid, key: "DiskUUID", writable: true)
    }

    func verifyUnchanged() throws {
      guard try disks.snapshot() == snapshot else {
        throw NativeHandoffValidationError.changedLayout
      }
      try disks.verifyPartition(esp, snapshot.disk)
    }
  }
#endif
