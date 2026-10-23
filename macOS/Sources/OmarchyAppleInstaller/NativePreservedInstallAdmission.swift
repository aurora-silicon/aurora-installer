#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// Reconstructs the owner-reviewed plan from the current disk and selected
  /// payload before a preserved reinstall may open any writable target.
  enum NativePreservedInstallAdmission {
    struct Prepared: Sendable {
      let target: NativePreservedInstallTarget
      let diskSnapshot: RemovalSnapshot
      let transcript: Data
      let archive: IPSWArchive
      let boot: IPSWArchiveMember
      let root: IPSWArchiveMember
      let esp: NativeESPPayloadPlan
      /// The FAT volume serial a fresh install would format the ESP with.
      let espVolumeID: UInt32?
      let stage1: NativeStubFileIdentity
    }

    /// The caller authenticates the complete payload bytes before opening the
    /// archive and derives stubBytes/firmwareVersion from the selected firmware.
    static func check(
      approved: ValidatedEnginePlan, metadata: Data, archive: IPSWArchive,
      disk: NativeCollectedDisk, stubBytes: UInt64, firmwareVersion: String,
      installedStage1: Data, legacyStage1: (@Sendable () throws -> Data)? = nil
    ) async throws -> Prepared {
      guard approved.candidateKind == "reinstall",
        SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest,
        disk.snapshot.disk == approved.storeIdentifier
      else { throw NativePreservedInstallError.unavailable }
      let selected = try NativeInstallationMetadata(data: metadata).target()
      let target = try NativePreservedInstallTarget.recognize(
        disk, sourceIdentifier: approved.sourceIdentifier)
      guard approved.offsetBytes == target.stub.offset,
        approved.lengthBytes == target.root.end - target.stub.offset
      else { throw NativePreservedInstallError.changedLayout }
      let minimum = try selected.partitions.reduce(UInt64(0)) { total, part in
        try NativeInspectionMath.add(
          total, NativeInspectionMath.alignUp(NativeInstallationMetadata.bytes(part.size)))
      }
      let layout = try NativeOSPartitionPlan(metadata: metadata, available: minimum)
      // The existing ESP is kept and only its payload files are replaced, so
      // the image's ESP size doesn't apply; NativePreservedESPCapacity checks
      // its free space before the first write.
      guard layout.parts.count == 3,
        layout.parts[1].bytes <= target.boot.size,
        layout.parts[2].bytes <= target.root.size
      else { throw NativePreservedInstallError.imageTooLarge }
      let espVolumeID: UInt32? = try layout.parts[0].volumeID.map { text in
        guard let serial = NativeFATBootSectors.serial(volumeID: text) else {
          throw NativePreservedInstallError.unavailable
        }
        return serial
      }
      let names = ["boot.img", "root.img"]
      let members = try names.map { name in
        let matches = archive.members.filter { $0.name == name && !$0.isDirectory }
        guard matches.count == 1, matches[0].sizeBytes > 0,
          matches[0].sizeBytes % 4096 == 0
        else { throw NativeRawImageError.invalidImage }
        return matches[0]
      }
      try target.admitImages(
        bootImageBytes: UInt64(members[0].sizeBytes),
        rootImageBytes: UInt64(members[1].sizeBytes))
      guard
        let esp = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive, device: approved.deviceIdentifier,
          firmware: firmwareVersion, legacyStage1: legacyStage1)
      else { throw NativePreservedInstallError.unavailable }
      let configurationPath = InstallConf.relativePath.precomposedStringWithCanonicalMapping
        .lowercased()
      let signedPaths = Set(
        esp.entries.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
      guard !signedPaths.contains(configurationPath) else {
        throw NativeHandoffValidationError.unsafePath
      }
      let stage1 = try esp.admitPreservedStage1(
        installedStage1, espUUID: target.esp.uuid,
        allowDifferentStage1Code: target.title != selected.name)

      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: approved.deviceIdentifier, snapshot: disk.snapshot,
          containers: disk.containers, metadata: NativeInstallationMetadata(data: metadata),
          stubBytes: stubBytes))
      guard let inventory = inspection.inventory,
        inventory.layoutDigest == approved.layoutDigest,
        let candidate = inventory.candidates.first(where: {
          $0.kind == "reinstall" && $0.sourceIdentifier == approved.sourceIdentifier
        }),
        candidate.identityDigest == target.identityDigest
      else { throw NativePreservedInstallError.changedLayout }
      let request = try PinnedAsahiPlanRequest(
        inventory: inventory, candidate: candidate,
        requestedLengthBytes: approved.lengthBytes)
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: approved.engineVersion, engineDigest: approved.engineDigest,
        metadataDigest: approved.metadataDigest, payloadDigest: approved.payloadDigest)
      let transcript = try NativeInstallerPlanner.transcript(
        inspection: inspection, request: request, identity: identity)
      guard try AppleInstallerTrustCore().validateEngineTranscript(transcript).plan == approved
      else { throw NativePreservedInstallError.changedLayout }
      return Prepared(
        target: target, diskSnapshot: disk.snapshot, transcript: transcript, archive: archive,
        boot: members[0], root: members[1], esp: esp, espVolumeID: espVolumeID,
        stage1: stage1)
    }
  }
#endif
