#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  protocol NativeInstallationFinishing: Sendable {
    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap, recovery: PreparedNativeRecoveryTemplate
    ) async throws
  }

  protocol NativeInstallationFinishingPreparing: Sendable {
    var requiresNativePath: Bool { get }
    func preflight(
      package: ImportedEngineHandoffPackage, stub: NativeStubFilePlan?,
      peripherals: PreparedNativePeripheralInputs?
    ) throws -> (any NativeInstallationFinishing)?
  }

  struct NativeInstallationFinisher: NativeInstallationFinishingPreparing {
    // This isolated candidate exercises native finishing before release.
    // Keep publication gated on device qualification.
    var enabled = true
    var requiresNativePath: Bool { enabled }
    var owner: uid_t = 0
    var environment: NativeHandoffEnvironment = .live
    var disks: NativeAPFSPlatform = .live
    var collectAmbientLight: @Sendable () throws -> Data? = { try NativeAmbientLightInputs.live() }

    func preflight(
      package: ImportedEngineHandoffPackage, stub: NativeStubFilePlan?,
      peripherals: PreparedNativePeripheralInputs?
    ) throws -> (any NativeInstallationFinishing)? {
      guard enabled, package.installationIntent == .fresh, let stub
      else { return nil }
      let approved = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let source = try NativeFirmwareSourcePlan(manifest: stub.manifest)
      guard "apple," + source.machine == package.deviceIdentifier
      else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      if source.machine == "j700" {
        guard let peripherals, source.fud.contains(where: { $0.component == "Multitouch" })
        else { throw NativeFirmwareInputFailure.invalidSource }
        try Self.admitPeripheralPrivacy(
          peripherals, package: package, approved: approved, owner: owner)
      } else if peripherals != nil {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let ambientLight = try source.machine == "j700" ? nil : collectAmbientLight()
      return NativeInstallationFinishingExecution(
        package: package, approved: approved, stub: stub, peripherals: peripherals,
        owner: owner, environment: environment, disks: disks, ambientLight: ambientLight)
    }

    static func admitPeripheralPrivacy(
      _ peripherals: PreparedNativePeripheralInputs, package: ImportedEngineHandoffPackage,
      approved: ValidatedEnginePlan, owner: uid_t
    ) throws {
      let tree = try NativeHandoffFileTree(peripherals.directory, protected: true, owner: owner)
      let manifest = try JSONDecoder().decode(
        NativeNeoPeripheralPreparer.Manifest.self,
        from: tree.read("manifest.json", maximum: 1 << 20))
      guard manifest.deviceIdentifier == package.deviceIdentifier,
        manifest.bindingDigest == package.bindingDigest,
        manifest.planDigest == approved.planDigest,
        manifest.metadataDigest == approved.metadataDigest,
        manifest.payloadDigest == approved.payloadDigest,
        manifest.recipeSHA256 == peripherals.recipeSHA256,
        manifest.localInputs["sensorRootKey"] == nil,
        manifest.files["apple/msrk-j700.bin"] == nil,
        manifest.files["apple/mesacal-j700.bin"] == nil
      else { throw NativeFirmwareInputFailure.invalidSource }
    }
  }

  struct NativeInstallationFinishingExecution: NativeInstallationFinishing {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let stub: NativeStubFilePlan
    let peripherals: PreparedNativePeripheralInputs?
    let owner: uid_t
    let environment: NativeHandoffEnvironment
    let disks: NativeAPFSPlatform
    let ambientLight: Data?

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap, recovery: PreparedNativeRecoveryTemplate
    ) async throws {
      _ = try await NativeVendorFirmware(
        package: package, approved: approved, plan: stub, peripherals: peripherals,
        owner: owner, environment: environment, disks: disks, ambientLight: { self.ambientLight }
      ).prepare(journal: journal, authorization: authorization, bootstrap: sourceBootstrap)
      try await NativeRecoveryInstallation(
        package: package, approved: approved, template: recovery,
        owner: owner, environment: environment, disks: disks
      ).prepare(journal: journal, authorization: authorization, bootstrap: sourceBootstrap)
      try await NativeInstallationCompletion(
        package: package, approved: approved,
        owner: owner, environment: environment, disks: disks
      ).prepare(journal: journal, authorization: authorization, bootstrap: sourceBootstrap)
    }
  }

  struct NativeInstallationCompletion: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    var owner: uid_t = 0
    var environment: NativeHandoffEnvironment = .live
    var disks: NativeAPFSPlatform = .live
    var admitESPFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) async throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let before = try file.readJournal()
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(before)
      guard transcript.plan == approved else { throw NativeHandoffValidationError.invalidEvidence }
      if transcript.checkpoints.contains(where: { $0.identifier == "stub-and-esp-installed" }) {
        return
      }
      guard try file.diskPreparationCanResume() else {
        throw NativeRecoveryJournalError.invalidState
      }
      let target = try NativeInstallationTarget(
        package: package, approved: approved, journal: file, authorization: authorization,
        bootstrap: bootstrap, owner: owner, environment: environment, disks: disks)
      guard
        let staged = try JSONSerialization.jsonObject(
          with: file.readEvidence("native-recovery-staged")) as? [String: Any],
        staged["plan_digest"] as? String == approved.planDigest,
        staged["publication_sha256"] as? String
          == (try NativeStubFileStore.hash(
            file.readEvidence("native-recovery-publication")))
      else { throw NativeHandoffValidationError.invalidEvidence }
      let esp = try NativeESPFileStore(
        root: target.espRoot(), volumeDevice: target.esp.identifier,
        namespace: approved.planDigest + "-completion", verifyMount: environment.verifyMount,
        admitFilesystem: admitESPFilesystem)
      let receipt = try JSONDecoder().decode(
        NativeESPFilesExecution.Receipt.self, from: file.readEvidence("native-esp-files"))
      let packageTree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try packageTree.read(package.metadataURL.lastPathComponent, maximum: 65536)
      guard SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest,
        let icon = try NativePayloadPreflight.target(metadata)["icon"] as? String
      else { throw NativeHandoffValidationError.invalidEvidence }
      let systemStore = NativeStubFileStore(tree: try target.tree("System"), owner: owner)
      guard try systemStore.identity(".VolumeIcon.icns", maximum: 64 << 20) == receipt.icon else {
        throw NativeHandoffValidationError.changedContent
      }
      var digest = SHA256()
      var total = 0
      for entry in receipt.files.sorted(by: {
        $0.member.utf8.lexicographicallyPrecedes($1.member.utf8)
      }) {
        guard try esp.identity(entry.path) == entry.identity,
          let hash = SHA256Digest(hexadecimal: entry.identity.sha256)
        else { throw NativeHandoffValidationError.changedContent }
        let name = Data(entry.member.utf8)
        var length = UInt64(name.count).bigEndian
        digest.update(data: withUnsafeBytes(of: &length) { Data($0) })
        digest.update(data: name)
        digest.update(
          data: Data(
            stride(from: 0, to: 64, by: 2).map { index in
              UInt8(hash.hexadecimal.dropFirst(index).prefix(2), radix: 16)!
            }))
        total += entry.identity.bytes
      }
      var parts: [[String: Any]] = [
        [
          "name": "EFI", "partition_identifier": target.esp.identifier,
          "partition_uuid": target.esp.uuid.lowercased(), "partition_size_bytes": target.esp.size,
          "population": "esp", "installed_bytes": total, "verification": "copied-tree-sha256",
          "content_sha256": digest.finalize().map { String(format: "%02x", $0) }.joined(),
        ]
      ]
      for (index, name) in ["boot", "root"].enumerated() {
        let image = try JSONDecoder().decode(
          NativeRawImageReceipt.self, from: file.readEvidence("native-image-" + name))
        let partition = target.partitions.partitions[index + 1]
        guard image.partitionIdentifier == partition.identifier,
          image.partitionUUID == partition.uuid.lowercased(),
          image.partitionSizeBytes == partition.size,
          image.installedBytes > 0, image.installedBytes <= partition.size,
          image.verification == "source-sha256-write-flushed-v1"
        else { throw NativeHandoffValidationError.invalidEvidence }
        if index == 0 {
          guard
            try environment.rawDigest(partition.identifier, image.installedBytes)
              == image.contentSHA256
          else {
            throw NativeHandoffValidationError.changedContent
          }
        }
        parts.append([
          "name": index == 0 ? "Boot" : "Root", "partition_identifier": partition.identifier,
          "partition_uuid": partition.uuid.lowercased(), "partition_size_bytes": partition.size,
          "population": name + ".img", "installed_bytes": image.installedBytes,
          "verification": index == 0 ? "raw-prefix-sha256" : image.verification,
          "content_sha256": image.contentSHA256,
        ])
      }
      let installed = try JSONSerialization.data(
        withJSONObject: [
          "plan_digest": approved.planDigest, "apfs_vgid": target.group,
          "system_volume": target.system.identifier, "efi_partition": target.esp.uuid.lowercased(),
          "startup_volume_icon": [
            "member": icon, "installed_bytes": receipt.icon.bytes,
            "verification": "stub-file-sha256", "content_sha256": receipt.icon.sha256,
          ] as [String: Any],
          "populated_partitions": parts,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
      try target.verifyUnchanged()
      if before.split(separator: 10).count == 5 {
        try file.append(
          type: "event",
          payload: [
            "plan_digest": approved.planDigest, "name": "stub_and_esp_started",
          ], before: before)
      }
      try file.publishEvidence(installed, identifier: "stub-and-esp-installed")
      try file.append(
        type: "checkpoint",
        payload: [
          "plan_digest": approved.planDigest, "identifier": "stub-and-esp-installed",
          "phase": "stub_and_esp", "evidence_digest": SHA256Digest(hashing: installed).rawValue,
        ], before: file.readJournal())
      let saved = try NativeRecoveryJournalSnapshot.decode(
        file.readJournal(), package: package, evidence: file.readEvidence)
      _ = try NativeHandoffEvidence(snapshot: saved, metadata: metadata)
    }
  }
#endif
