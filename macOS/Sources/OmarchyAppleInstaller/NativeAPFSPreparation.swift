#if os(macOS)
  import AuroraFirmware
  import CoreFoundation
  import Darwin
  import Foundation

  enum NativeAPFSError: Error, Equatable {
    case invalidPlan, changedLayout, changedTarget, ambiguousMutation, invalidLabel
  }

  struct NativeAPFSFacts: Sendable {
    let deviceIdentifier: String
    let hardware: NativeInspectionHardware
    let disk: NativeCollectedDisk
  }

  struct NativeAPFSPlatform: Sendable {
    var collect: @Sendable () throws -> NativeAPFSFacts
    var snapshot: @Sendable () throws -> RemovalSnapshot
    var verifyPartition: @Sendable (RemovalPartition, String) throws -> Void
    var verifySourceOwner:
      @Sendable (ImportedEngineHandoffPackage, MachineOwnerAuthorization, NativeSourceBootstrap)
        throws -> Void
    var command: @Sendable ([String]) throws -> Void

    static var live: Self {
      let disks = NativeDiskCollector().disks
      return Self(
        collect: {
          let host = try AppleSiliconHostInspector().inspect()
          return NativeAPFSFacts(
            deviceIdentifier: host.identity.deviceIdentifier,
            hardware: try NativeInspectionHardware.live(),
            disk: try NativeDiskCollector().collect(host: host))
        }, snapshot: { try disks.snapshot(maximumPartitions: 4096) },
        verifyPartition: { part, disk in
          guard
            let info = try PropertyListSerialization.propertyList(
              from: disks.commands(["info", "-plist", part.identifier]), format: nil)
              as? [String: Any],
            info["DeviceIdentifier"] as? String == part.identifier,
            (info["DiskUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString == part.uuid,
            info["ParentWholeDisk"] as? String == disk, info["Content"] as? String == part.type,
            try number(info, "PartitionMapPartitionOffset") == part.offset,
            try number(info, "Size") == part.size
          else { throw NativeAPFSError.changedLayout }
        },
        verifySourceOwner: { package, authorization, expected in
          guard
            try NativeSourceOwnerAdmission().check(package: package, authorization: authorization)
              == expected
          else {
            throw NativeHandoffValidationError.invalidOwner
          }
        },
        command: { arguments in
          _ = try MacRemovalDiskOperator.systemRun("/usr/sbin/diskutil", arguments)
        })
    }

    private static func number(_ object: [String: Any], _ key: String) throws -> UInt64 {
      guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        ["Q", "q", "I", "i", "L", "l", "S", "s", "C", "c"].contains(
          String(cString: number.objCType)),
        !number.stringValue.hasPrefix("-")
      else { throw NativeAPFSError.changedLayout }
      return number.uint64Value
    }
  }

  protocol NativeAPFSExecuting: Sendable {
    func prepareTarget(
      journal: URL, authorization: MachineOwnerAuthorization, sourceBootstrap: NativeSourceBootstrap
    ) throws
  }

  protocol NativeAPFSPreparing: Sendable {
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeAPFSExecuting
    )?
  }

  struct NativeAPFSPreparer: NativeAPFSPreparing {
    let owner: uid_t
    let platform: NativeAPFSPlatform
    let firmwareFacts: @Sendable () throws -> NativeFirmwareSelection.Facts
    let admitRestore: @Sendable (URL) async throws -> Void

    init(
      owner: uid_t = 0, platform: NativeAPFSPlatform = .live,
      firmwareFacts: @escaping @Sendable () throws -> NativeFirmwareSelection.Facts = {
        try NativeFirmwareSelection.Facts.live()
      },
      admitRestore: @escaping @Sendable (URL) async throws -> Void = { url in
        _ = try await IPSWArchive.open(IPSWHTTPRangeReader.discover(url: url))
      }
    ) {
      self.owner = owner
      self.platform = platform
      self.firmwareFacts = firmwareFacts
      self.admitRestore = admitRestore
    }

    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeAPFSExecuting
    )? {
      // Replacement and repair retain their existing execution contracts until
      // their separate native ports; never reinterpret either as fresh space.
      guard package.installationIntent == .fresh else { return nil }
      try Task.checkCancellation()
      let plan = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let bytes = try tree.read(package.metadataURL.lastPathComponent, maximum: 65536)
      guard SHA256Digest(hashing: bytes).rawValue == plan.metadataDigest else {
        throw NativeAPFSError.invalidPlan
      }
      let metadata = try NativeInstallationMetadata(data: bytes)
      let selection = try NativeFirmwareSelection.choose(
        deviceIdentifier: package.deviceIdentifier,
        facts: firmwareFacts(), metadata: metadata, policy: NativeInspectionPolicy.sealed())
      // Preserve the early archive-opening gate that preceded APFS work in the
      // backend. This is a bounded ZIP index read, never a whole restore fetch.
      try await admitRestore(selection.sourceURL)
      try Task.checkCancellation()
      return NativeAPFSExecution(
        package: package, owner: owner, approved: plan,
        metadata: metadata, firmware: selection, platform: platform)
    }
  }

  struct NativeAPFSTargetEvidence: Codable, Equatable, Sendable {
    let planDigest: String
    let partitionIdentifier: String
    let offsetBytes: UInt64
    let sizeBytes: UInt64
    let uuid: String
    enum CodingKeys: String, CodingKey {
      case planDigest = "plan_digest"
      case partitionIdentifier = "partition_identifier"
      case offsetBytes = "offset_bytes"
      case sizeBytes = "size_bytes"
      case uuid
    }
    var bytes: Data {
      get throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
      }
    }
    init(plan: String, partition: RemovalPartition) {
      planDigest = plan
      partitionIdentifier = partition.identifier
      offsetBytes = partition.offset
      sizeBytes = partition.size
      uuid = partition.uuid
    }
    static func read(_ bytes: Data) throws -> Self {
      let result = try JSONDecoder().decode(Self.self, from: bytes)
      guard try result.bytes == bytes else { throw NativeAPFSError.changedTarget }
      return result
    }
  }

  /// Only this object can cross from complete native preflight into APFS work.
  /// Its caller first admits the authenticated backend continuation capability.
  struct NativeAPFSExecution: NativeAPFSExecuting {
    let package: ImportedEngineHandoffPackage
    let owner: uid_t
    let approved: ValidatedEnginePlan
    let metadata: NativeInstallationMetadata
    let firmware: NativeFirmwareSelection
    let platform: NativeAPFSPlatform

    func prepareTarget(
      journal: URL, authorization: MachineOwnerAuthorization, sourceBootstrap: NativeSourceBootstrap
    ) throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      try file.transaction {
        let saved = try file.readJournal()
        if let validated = try? AppleInstallerTrustCore().validateEngineTranscript(saved),
          validated.plan == approved, saved.split(separator: 10).count > 3
        {
          try requireSourceOwner(
            file: file, authorization: authorization, bootstrap: sourceBootstrap, existing: true)
          try resume(file: file, transcript: saved)
          return
        }
        let facts = try platform.collect()
        let currentPlan = try freshPlan(facts)
        let transcript: Data
        if let validated = try? AppleInstallerTrustCore().validateEngineTranscript(saved),
          validated.plan == approved, saved.split(separator: 10).count == 3
        {
          // Fresh bounds must still admit the allocation, but bounds are not
          // part of the layout/plan digest. Preserve the original header when
          // ordinary source-volume usage changes the minimum between attempts.
          transcript = saved
        } else {
          transcript = currentPlan
          try file.initialize(transcript)
        }
        // A changed or partially written disk intent cannot match this header.
        let before = facts.disk.snapshot
        let label = try metadata.target().name
        guard (1...80).contains(label.unicodeScalars.count), !label.contains("/"),
          !label.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw NativeAPFSError.invalidLabel }
        var source: RemovalPartition?
        if approved.candidateKind == "resize" {
          let end = try NativeInspectionMath.add(approved.offsetBytes, approved.lengthBytes)
          let matching = before.partitions.filter { $0.identifier == approved.sourceIdentifier }
          guard matching.count == 1, let part = matching.first, part.type == "Apple_APFS",
            part.size > approved.lengthBytes,
            part.end == end
          else { throw NativeAPFSError.changedLayout }
          source = part
          try platform.verifyPartition(part, before.disk)
        } else {
          _ = try freeExtent(before)
        }
        try Task.checkCancellation()
        try requireSourceOwner(
          file: file, authorization: authorization, bootstrap: sourceBootstrap, existing: false)
        guard try platform.snapshot() == before else { throw NativeAPFSError.changedLayout }
        try file.append(
          type: "event",
          payload: [
            "plan_digest": approved.planDigest, "name": "apfs_preparation_started",
          ], before: transcript)
        var available = before
        if let source {
          try Task.checkCancellation()
          try platform.verifyPartition(source, before.disk)
          let size = source.size - approved.lengthBytes
          try platform.command(["apfs", "resizeContainer", source.identifier, String(size)])
          available = try platform.snapshot()
          var expected = before
          guard let index = expected.partitions.firstIndex(where: { $0.uuid == source.uuid }) else {
            throw NativeAPFSError.changedLayout
          }
          expected.partitions[index].size = size
          guard available == expected else { throw NativeAPFSError.changedLayout }
        }
        let free = try freeExtent(available)
        guard let predecessor = available.partitions.first(where: { $0.identifier == free.source })
        else {
          throw NativeAPFSError.changedLayout
        }
        try Task.checkCancellation()
        try platform.verifyPartition(predecessor, available.disk)
        try platform.command([
          "addPartition", predecessor.identifier, "apfs", label, String(firmware.stubBytes),
        ])
        let after = try platform.snapshot()
        let target = try createdTarget(before: available, after: after, label: label)
        try platform.verifyPartition(target, after.disk)
        let evidence = try NativeAPFSTargetEvidence(plan: approved.planDigest, partition: target)
          .bytes
        try file.publishEvidence(evidence, identifier: "apfs-target-prepared")
        try file.append(
          type: "checkpoint",
          payload: [
            "plan_digest": approved.planDigest, "identifier": "apfs-target-prepared",
            "phase": "apfs_preparation",
            "evidence_digest": SHA256Digest(hashing: evidence).rawValue,
          ], before: file.readJournal())
      }
    }

    private func requireSourceOwner(
      file: NativeInstallJournalFile, authorization: MachineOwnerAuthorization,
      bootstrap: NativeSourceBootstrap, existing: Bool
    ) throws {
      let bytes = try JSONSerialization.data(
        withJSONObject: [
          "plan_digest": approved.planDigest, "bootstrap": bootstrap.configuration,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
      if existing {
        guard try file.readEvidence("native-source-owner") == bytes else {
          throw NativeHandoffValidationError.invalidOwner
        }
      }
      try platform.verifySourceOwner(package, authorization, bootstrap)
      if !existing { try file.publishEvidence(bytes, identifier: "native-source-owner") }
    }

    private func freshPlan(_ facts: NativeAPFSFacts) throws -> Data {
      guard facts.deviceIdentifier == approved.deviceIdentifier,
        facts.disk.snapshot.disk == approved.storeIdentifier,
        try NativeKnownInstallations.recognize(facts.disk).isEmpty,
        try NativeFirmwareSelection.choose(
          deviceIdentifier: approved.deviceIdentifier,
          facts: .init(deviceIdentifier: facts.deviceIdentifier, hardware: facts.hardware),
          metadata: metadata, policy: NativeInspectionPolicy.sealed()) == firmware
      else { throw NativeAPFSError.changedLayout }
      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeDiskInventory.transcript(
          device: facts.deviceIdentifier, snapshot: facts.disk.snapshot,
          containers: facts.disk.containers, metadata: metadata, stubBytes: firmware.stubBytes))
      guard let inventory = inspection.inventory,
        inventory.layoutDigest == approved.layoutDigest,
        let candidate = inventory.candidates.first(where: {
          $0.kind == approved.candidateKind && $0.sourceIdentifier == approved.sourceIdentifier
        })
      else { throw NativeAPFSError.changedLayout }
      let request = try PinnedAsahiPlanRequest(
        inventory: inventory, candidate: candidate,
        requestedLengthBytes: approved.lengthBytes)
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: approved.engineVersion,
        engineDigest: approved.engineDigest, metadataDigest: approved.metadataDigest,
        payloadDigest: approved.payloadDigest)
      let transcript = try NativeInstallerPlanner.transcript(
        inspection: inspection, request: request, identity: identity)
      guard try AppleInstallerTrustCore().validateEngineTranscript(transcript).plan == approved
      else {
        throw NativeAPFSError.invalidPlan
      }
      return transcript
    }

    private func freeExtent(_ snapshot: RemovalSnapshot) throws -> NativeDiskInventory.Extent {
      let matching = try NativeDiskInventory.extents(snapshot).filter {
        $0.partition == nil && $0.offset == approved.offsetBytes
          && $0.length >= approved.lengthBytes
      }
      guard matching.count == 1, let extent = matching.first,
        firmware.stubBytes < approved.lengthBytes
      else { throw NativeAPFSError.changedLayout }
      return extent
    }

    private func createdTarget(before: RemovalSnapshot, after: RemovalSnapshot, label: String)
      throws -> RemovalPartition
    {
      let known = Set(before.partitions.map(\.uuid))
      let added = after.partitions.filter { !known.contains($0.uuid) }
      guard added.count == 1, let target = added.first, target.type == "Apple_APFS",
        target.offset == approved.offsetBytes, target.size == firmware.stubBytes,
        let container = after.containers.first(where: { $0.storeUUID == target.uuid }),
        !before.containers.contains(where: { $0.uuid == container.uuid }),
        container.volumes.filter({ $0.roles.isEmpty && $0.name == label }).count == 1,
        container.volumes.allSatisfy({
          $0.group == nil && [[], ["Preboot"], ["Recovery"], ["VM"]].contains($0.roles)
        })
      else { throw NativeAPFSError.changedTarget }
      var remainder = after
      remainder.partitions.removeAll { $0.uuid == target.uuid }
      remainder.containers.removeAll { $0.storeUUID == target.uuid }
      guard remainder == before else { throw NativeAPFSError.changedLayout }
      return target
    }

    private func resume(file: NativeInstallJournalFile, transcript: Data) throws {
      do {
        try NativeInstallAdmission.check(
          package: package, journal: transcript,
          collect: { throw NativeAPFSError.ambiguousMutation }, readEvidence: file.readEvidence)
      } catch { throw NativeAPFSError.ambiguousMutation }
      let evidence = try NativeAPFSTargetEvidence.read(file.readEvidence("apfs-target-prepared"))
      let snapshot = try platform.snapshot()
      let matching = snapshot.partitions.filter {
        $0.identifier == evidence.partitionIdentifier && $0.uuid == evidence.uuid
          && $0.type == "Apple_APFS" && $0.offset == approved.offsetBytes
          && $0.size == firmware.stubBytes
      }
      guard snapshot.disk == approved.storeIdentifier, evidence.planDigest == approved.planDigest,
        evidence.offsetBytes == approved.offsetBytes, evidence.sizeBytes == firmware.stubBytes,
        matching.count == 1
      else { throw NativeAPFSError.changedTarget }
      try platform.verifyPartition(matching[0], snapshot.disk)
    }
  }
#endif
