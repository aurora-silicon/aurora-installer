#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  struct NativeESPPayloadPlan: Sendable {
    struct Entry: Sendable {
      let member: IPSWArchiveMember
      let path: String
    }
    let archive: IPSWArchive
    let entries: [Entry]
    let icon: IPSWArchiveMember
    let stage1: Data
    let windowMilliseconds: UInt32
    let firmware: String
    let usesLegacyStage1: Bool
    /// Files an experimental install adds to the ESP: the aura-proxy marker
    /// (Bootloader only), the experimental record, and a Stage 2 rebuilt from
    /// a same-chip board's. Empty on every supported Mac.
    var extraFiles: [String: Data] = [:]

    static func make(
      metadata: Data, archive: IPSWArchive, device: String, firmware: String,
      legacyStage1: (@Sendable () throws -> Data)? = nil,
      experimental: NativeExperimentalAssessment? = nil
    )
      async throws -> Self?
    {
      let template = try NativePayloadPreflight.target(metadata)
      if let value = template["extras"] {
        guard let extras = value as? [String] else {
          throw NativePayloadPreflightError.invalidMetadata
        }
        // Legacy extra downloads retain their existing execution contract.
        if !extras.isEmpty { return nil }
      }
      var extraFiles = [String: Data]()
      let boot: NativeBootChainAdmission
      if let experimental {
        guard experimental.deviceIdentifier == device,
          experimental.firmwareVersion == firmware
        else { throw ExperimentalAdmissionError.decisionChanged }
        let chain = try await NativeExperimentalBootChain.admit(
          metadata: metadata, archive: archive, assessment: experimental)
        var layout = chain.espLayout
        if let rebuilt = chain.stage2Override {
          // The sibling board file itself is not copied; its rebuilt bytes are.
          layout = layout.filter { $0.value != "m1n1/boot.bin" }
          extraFiles["m1n1/boot.bin"] = rebuilt
        }
        try extraFiles.merge(chain.extraFiles) { _, _ in
          throw NativeHandoffValidationError.changedContent
        }
        boot = NativeBootChainAdmission(
          stage1Member: chain.stage1Member, windowMilliseconds: 0, espLayout: layout)
      } else {
        boot = try await NativeBootChain.admit(
          metadata: metadata, archive: archive,
          deviceIdentifier: device, firmware: firmware)
      }
      let bytes: Data
      let legacy: Bool
      if let source = boot.stage1Member {
        guard let stage = archive.members.first(where: { $0.name == source }) else {
          throw NativeBootChainError.missingStage1
        }
        bytes = try await archive.read(stage, maximumBytes: 64 << 20)
        legacy = false
      } else {
        guard let legacyStage1 else { return nil }
        bytes = try legacyStage1()
        try NativeLegacyStage1.validate(bytes)
        legacy = true
      }
      guard let name = template["icon"] as? String,
        let icon = archive.members.first(where: { $0.name == name && !$0.isDirectory }),
        let rows = template["partitions"] as? [[String: Any]],
        let row = rows.first, let size = row["size"] as? String
      else { throw NativeBootChainError.invalidQualification }
      try await archive.validateEntries()
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      var entries = [Entry]()
      var names = Set<String>()
      var total: UInt64 = 0
      for (source, path) in boot.espLayout.sorted(by: {
        $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
      }) {
        guard let member = members[source], !member.isDirectory, member.sizeBytes <= 64 << 20,
          member.compressedSize <= 64 << 20,
          safeFATPath(path)
        else { throw NativeHandoffValidationError.unsafePath }
        let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
        guard !names.contains(canonical),
          !names.contains(where: {
            canonical.hasPrefix($0 + "/") || $0.hasPrefix(canonical + "/")
          })
        else { throw NativeHandoffValidationError.unsafePath }
        names.insert(canonical)
        total = try NativeInspectionMath.add(total, UInt64(member.sizeBytes))
        entries.append(Entry(member: member, path: path))
      }
      for (path, data) in extraFiles {
        let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
        guard safeFATPath(path), data.count <= 64 << 20, !names.contains(canonical),
          !names.contains(where: {
            canonical.hasPrefix($0 + "/") || $0.hasPrefix(canonical + "/")
          })
        else { throw NativeHandoffValidationError.unsafePath }
        names.insert(canonical)
        total = try NativeInspectionMath.add(total, UInt64(data.count))
      }
      guard entries.count <= 10000, total > 0,
        total < (try NativeInstallationMetadata.bytes(size)), icon.sizeBytes > 0,
        icon.sizeBytes <= 64 << 20
      else { throw NativePayloadPreflightError.invalidPartitions }
      return Self(
        archive: archive, entries: entries, icon: icon, stage1: bytes,
        windowMilliseconds: boot.windowMilliseconds, firmware: firmware, usesLegacyStage1: legacy,
        extraFiles: extraFiles)
    }

    static func safeFATPath(_ path: String) -> Bool {
      let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*")
      return NativeHandoffEvidence.safeRelative(path)
        && path.split(separator: "/").allSatisfy { part in
          part.utf16.count <= 255 && part.last != "." && part.last != " "
            && part.unicodeScalars.allSatisfy {
              $0.isASCII && $0.value >= 32 && $0.value != 127 && !forbidden.contains($0)
            }
        }
    }

    /// Reuse the existing boot-policy target only when its installed Stage 1
    /// exactly matches the selected authenticated payload after ESP binding.
    func admitPreservedStage1(
      _ installed: Data, espUUID: String, allowDifferentStage1Code: Bool = false
    ) throws
      -> NativeStubFileIdentity
    {
      guard !installed.isEmpty, installed.count <= 64 << 20,
        UUID(uuidString: espUUID) != nil
      else { throw NativeBootChainError.invalidStage1 }
      let expected =
        usesLegacyStage1
        ? try NativeLegacyStage1.fill(
          stage1, uuid: espUUID.lowercased(), path: "m1n1/boot.bin")
        : try NativeBootChain.fillStage1(
          stage1, uuid: espUUID.lowercased(), path: "m1n1/boot.bin",
          windowMilliseconds: windowMilliseconds)
      if installed != expected {
        guard allowDifferentStage1Code, !usesLegacyStage1 else {
          throw NativeBootChainError.invalidStage1
        }
        try NativeBootChain.validateInstalledStage1(
          installed, uuid: espUUID.lowercased(), path: "m1n1/boot.bin")
      }
      return NativeStubFileIdentity(
        bytes: installed.count, sha256: NativeStubFileStore.hash(installed))
    }
  }

  protocol NativeESPFilesExecuting: Sendable {
    var requiresNativeFinishing: Bool { get }
    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) async throws
  }
  extension NativeESPFilesExecuting {
    var requiresNativeFinishing: Bool { false }
  }
  protocol NativeESPFilesPreparing: Sendable {
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeESPFilesExecuting
    )?
  }

  struct NativeESPFilesPreparer: NativeESPFilesPreparing {
    var owner: uid_t = 0
    var environment: NativeHandoffEnvironment = .live
    var disks: NativeAPFSPlatform = .live
    var facts: @Sendable () throws -> NativeFirmwareSelection.Facts = { try .live() }
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeESPFilesExecuting
    )? {
      guard package.installationIntent == .fresh else { return nil }
      let approved = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try tree.read(package.metadataURL.lastPathComponent, maximum: 65536)
      guard SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest else {
        throw NativeStubFileError.invalidPlan
      }
      let liveFacts = try facts()
      let installation = try NativeInstallationMetadata(data: metadata)
      let firmware = try NativeFirmwareSelection.choose(
        package: package, facts: liveFacts, metadata: installation)
      let experimental = try package.experimentalAdmission.map {
        try NativeDeviceAdmission.verify(
          $0, deviceIdentifier: package.deviceIdentifier, hardware: liveFacts.hardware,
          policy: NativeInspectionPolicy.sealed(), metadata: installation)
      }
      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: owner))
      guard
        let plan = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive,
          device: package.deviceIdentifier,
          firmware: firmware.version.components(separatedBy: " ")[0],
          experimental: experimental)
      else { return nil }
      return NativeESPFilesExecution(
        package: package, approved: approved, plan: plan,
        owner: owner, environment: environment, disks: disks)
    }
  }

  struct NativeESPFilesExecution: NativeESPFilesExecuting {
    struct Entry: Codable {
      let member: String
      let path: String
      let identity: NativeStubFileIdentity
    }
    struct Receipt: Codable {
      let plan: String
      let firmware: String
      let groupUUID: String
      let espUUID: String
      let files: [Entry]
      let icon: NativeStubFileIdentity
      let stage1: NativeStubFileIdentity
      var legacyStage1: NativeLegacyStage1.Receipt? = nil
      /// Experimental installs only; absent, so unchanged, everywhere else.
      var extraFiles: [Entry]? = nil
    }
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let plan: NativeESPPayloadPlan
    let owner: uid_t
    let environment: NativeHandoffEnvironment
    let disks: NativeAPFSPlatform
    var admitESPFilesystem: @Sendable (Int32) throws -> Void = {
      try NativeESPFileStore.requireFAT($0)
    }
    var requiresNativeFinishing: Bool { plan.usesLegacyStage1 }

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap
    ) async throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(file.readJournal())
      guard transcript.plan == approved else { throw NativeOSPartitionError.changedLayout }
      if transcript.checkpoints.contains(where: { $0.identifier == "stub-and-esp-installed" }) {
        return
      }
      guard transcript.checkpoints.map(\.identifier) == ["apfs-target-prepared"],
        try file.diskPreparationCanResume()
      else { throw NativeOSPartitionError.changedLayout }
      let parts = try JSONDecoder().decode(
        NativeOSPartitionsExecution.Receipt.self,
        from: file.readEvidence("native-os-partitions"))
      let snapshot = try disks.snapshot()
      _ = try NativeDiskInventory.extents(snapshot)
      var expected = try JSONDecoder().decode(
        RemovalSnapshot.self,
        from: file.readEvidence("native-os-partition-baseline"))
      expected.partitions.append(contentsOf: parts.partitions)
      expected.partitions.sort { $0.offset < $1.offset }
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
      else { throw NativeOSPartitionError.changedLayout }
      let volumes = try NativeStubVolumes.read(
        file.readEvidence(NativeStubVolumes.evidenceIdentifier))
      try volumes.validate(plan: approved.planDigest, target: stub, snapshot: snapshot)
      for (index, name) in ["boot", "root"].enumerated() {
        let saved = try JSONDecoder().decode(
          NativeRawImageReceipt.self,
          from: file.readEvidence("native-image-" + name))
        guard saved.partitionUUID == parts.partitions[index + 1].uuid.lowercased(),
          saved.partitionSizeBytes == parts.partitions[index + 1].size,
          saved.verification == "source-sha256-write-flushed-v1"
        else { throw NativeRawImageError.invalidTarget }
      }
      // The owner is resolved from this pass's layout, read again right after.
      try disks.verifySourceOwner(package, authorization, sourceBootstrap, snapshot)
      try disks.verifyPartition(esp, snapshot.disk)
      guard
        NativeESPLabelAdmission.matches(
          try disks.snapshot(), recorded: snapshot, espUUID: esp.uuid,
          label: parts.layout.parts[0].fatLabel)
      else { throw NativeOSPartitionError.changedLayout }
      let mounts = NativeHandoffMounts(environment)
      let espURL = try mounts.mounted(
        esp.identifier, uuid: esp.uuid, key: "DiskUUID", writable: true, browsable: false)
      let systemURL = try mounts.mounted(system.identifier, uuid: system.uuid, writable: true)
      func store(_ root: URL, device: String) throws -> NativeStubFileStore {
        try NativeStubFileStore(
          tree: NativeHandoffFileTree(
            root, protected: true, owner: owner,
            volumeRoot: true, volumeDevice: device, verifyMount: environment.verifyMount),
          owner: owner, namespace: approved.planDigest + "-esp")
      }
      let espStore = try NativeESPFileStore(
        root: espURL, volumeDevice: esp.identifier,
        namespace: approved.planDigest, verifyMount: environment.verifyMount,
        admitFilesystem: admitESPFilesystem)
      let systemStore = try store(systemURL, device: system.identifier)
      var entries = [Entry]()
      for entry in plan.entries {
        let receiptName =
          "native-esp-member-" + NativeStubFileStore.hash(Data(entry.member.name.utf8))
        let identity: NativeStubFileIdentity
        if try file.containsEvidence(receiptName) {
          identity = try JSONDecoder().decode(
            NativeStubFileIdentity.self, from: file.readEvidence(receiptName))
          guard identity.bytes == entry.member.sizeBytes,
            try espStore.identity(entry.path, maximum: entry.member.sizeBytes) == identity
          else { throw NativeHandoffValidationError.changedContent }
        } else {
          identity = try await espStore.member(entry.member, archive: plan.archive, at: entry.path)
          try file.publishEvidence(encode(identity), identifier: receiptName)
        }
        entries.append(Entry(member: entry.member.name, path: entry.path, identity: identity))
      }
      var extras = [Entry]()
      for (path, data) in plan.extraFiles.sorted(by: { $0.key < $1.key }) {
        let receiptName = "native-esp-extra-" + NativeStubFileStore.hash(Data(path.utf8))
        let expected = NativeStubFileIdentity(
          bytes: data.count, sha256: NativeStubFileStore.hash(data))
        if try file.containsEvidence(receiptName) {
          let identity = try JSONDecoder().decode(
            NativeStubFileIdentity.self, from: file.readEvidence(receiptName))
          guard identity == expected,
            try espStore.identity(path, maximum: max(data.count, 1)) == identity
          else { throw NativeHandoffValidationError.changedContent }
        } else {
          let identity = try await espStore.data(data, at: path)
          guard identity == expected else { throw NativeHandoffValidationError.changedContent }
          try file.publishEvidence(encode(identity), identifier: receiptName)
        }
        extras.append(Entry(member: "experimental:" + path, path: path, identity: expected))
      }
      let icon = try await systemStore.member(
        plan.icon, archive: plan.archive, at: ".VolumeIcon.icns")
      let stage1: Data
      let legacy: NativeLegacyStage1.Receipt?
      if plan.usesLegacyStage1 {
        stage1 = try NativeLegacyStage1.fill(
          plan.stage1, uuid: esp.uuid.lowercased(), path: "m1n1/boot.bin")
        legacy = NativeLegacyStage1.Receipt(
          configuration: "legacy-text-v1",
          base: NativeStubFileIdentity(
            bytes: plan.stage1.count, sha256: NativeStubFileStore.hash(plan.stage1)))
      } else {
        stage1 = try NativeBootChain.fillStage1(
          plan.stage1, uuid: esp.uuid.lowercased(),
          path: "m1n1/boot.bin", windowMilliseconds: plan.windowMilliseconds)
        legacy = nil
      }
      let stage1Identity = try await systemStore.data(
        stage1,
        at: "Finish Installation.app/Contents/Resources/boot.bin")
      guard
        NativeESPLabelAdmission.matches(
          try disks.snapshot(), recorded: snapshot, espUUID: esp.uuid,
          label: parts.layout.parts[0].fatLabel)
      else { throw NativeOSPartitionError.changedLayout }
      try disks.verifyPartition(esp, snapshot.disk)
      try file.publishEvidence(
        encode(
          Receipt(
            plan: approved.planDigest, firmware: plan.firmware,
            groupUUID: group, espUUID: esp.uuid, files: entries, icon: icon, stage1: stage1Identity,
            legacyStage1: legacy, extraFiles: plan.extraFiles.isEmpty ? nil : extras)
        ),
        identifier: "native-esp-files")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(value)
    }
  }
#endif
