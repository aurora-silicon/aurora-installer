#if os(macOS)
  import Darwin
  import Foundation
  import RecoveryAccountCore

  struct NativeRecoveryInstallation: Sendable {
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let template: PreparedNativeRecoveryTemplate
    var owner: uid_t = 0
    var environment: NativeHandoffEnvironment = .live
    var disks: NativeAPFSPlatform = .live
    var verifyApp: @Sendable (URL, String) throws -> Void = NativeRecoveryTemplate.verify
    var admitESPFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) async throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let target = try NativeInstallationTarget(
        package: package, approved: approved, journal: file, authorization: authorization,
        bootstrap: bootstrap, owner: owner, environment: environment, disks: disks)
      let systemRoot = try target.root("System", writable: true)
      let system = try target.tree("System", writable: true)
      let espRoot = try target.espRoot()
      let esp = try NativeESPFileStore(
        root: espRoot, volumeDevice: target.esp.identifier,
        namespace: approved.planDigest + "-recovery", verifyMount: environment.verifyMount,
        admitFilesystem: admitESPFilesystem)
      let vendor = try JSONDecoder().decode(
        NativeVendorFirmware.Receipt.self, from: file.readEvidence("native-vendor-firmware"))
      let espReceipt = try JSONDecoder().decode(
        NativeESPFilesExecution.Receipt.self, from: file.readEvidence("native-esp-files"))
      let required: Set<String> = [
        "vendorfw/firmware.tar", "vendorfw/firmware.cpio", "vendorfw/manifest.txt",
        "vendorfw/u-boot/asmedia/asm2214a-apple.bin",
      ]
      guard vendor.plan == approved.planDigest, vendor.groupUUID == target.group,
        vendor.espUUID == target.esp.uuid,
        vendor.sourceBinding
          == NativeStubFileStore.hash(try file.readEvidence("native-stub-file-binding")),
        Set(vendor.files.keys) == required,
        espReceipt.stage1.bytes > 0,
        try NativeStubFileStore(tree: system, owner: owner).identity(
          "Finish Installation.app/Contents/Resources/boot.bin", maximum: 64 << 20)
          == espReceipt.stage1
      else { throw NativeHandoffValidationError.invalidEvidence }
      let stage2 = try esp.identity("m1n1/boot.bin")
      guard let stage2Entry = espReceipt.files.first(where: { $0.path == "m1n1/boot.bin" }),
        stage2 == stage2Entry.identity
      else { throw NativeHandoffValidationError.changedContent }
      for (path, identity) in vendor.files {
        guard try esp.identity(path, maximum: 256 << 20) == identity else {
          throw NativeHandoffValidationError.changedContent
        }
      }
      let info = try environment.disk(target.system.identifier)
      guard let name = info["VolumeName"] as? String, (1...80).contains(name.count),
        !name.contains("/"), name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
        (info["VolumeUUID"] as? String)?.uppercased() == target.system.uuid.uppercased(),
        (info["APFSVolumeGroupID"] as? String)?.uppercased() == target.group.uppercased(),
        info["MountPoint"] as? String == systemRoot.path
      else { throw NativeHandoffValidationError.invalidTarget }
      let config: [String: Any] = [
        "schema": 2, "volumeName": name,
        "systemUUID": try NativeSourceBootstrap.uuid(target.system.uuid),
        "groupUUID": try NativeSourceBootstrap.uuid(target.group),
        "prebootUUID": try NativeSourceBootstrap.uuid(target.volume("Preboot").uuid),
        "espUUID": try NativeSourceBootstrap.uuid(target.esp.uuid),
        "bootMode": "raw", "stage2Path": "m1n1/boot.bin",
        "bootstrap": bootstrap.configuration,
        "allowCustomBootArguments": package.deviceIdentifier == "apple,j700",
      ]
      var files = vendor.files
      files["raw/aura-raw.bin"] = espReceipt.stage1
      files["raw/boot.bin"] = stage2
      let manifest: [String: Any] = [
        "schema": 2, "defaultMode": "raw", "nestedVirtualization": false,
        "modes": ["raw": ["espPath": "m1n1/boot.bin"]],
        "vendorFirmware": vendor.files.keys.sorted(),
        "files": files.mapValues { ["sha256": $0.sha256, "bytes": $0.bytes] as [String: Any] },
      ]
      let configuration = try json(config)
      let payloadManifest = try json(manifest)
      let templateIdentity = try NativeRecoveryTemplate.templateIdentity(template, owner: owner)
      let publication = try json([
        "plan_digest": approved.planDigest, "binding_digest": package.bindingDigest,
        "configuration": config, "manifest": manifest,
        "template_sha256": NativeStubFileStore.hash(templateIdentity),
      ])
      // This durable identity authorizes retry of either publication. An app
      // and its separate data become launchable only after the final checkpoint.
      try file.publishEvidence(publication, identifier: "native-recovery-publication")
      try system.createDirectory("Aurora/Recovery")
      let relative = "Aurora/Recovery/InstallData"
      let destination = systemRoot.appendingPathComponent(relative)
      var expected = files.mapKeys { "AuraPayloads/" + $0 }
      expected["install-config.json"] = identity(configuration)
      expected["AuraPayloads/manifest.json"] = identity(payloadManifest)
      if try system.isAbsent(relative) {
        let candidateName = ".native-install-data-" + String(approved.planDigest.dropFirst(7))
        let candidateRelative = "Aurora/Recovery/" + candidateName
        try system.createDirectory(candidateRelative)
        let candidate = systemRoot.appendingPathComponent(candidateRelative)
        let candidateTree = try NativeHandoffFileTree(candidate, protected: true, owner: owner)
        let store = NativeStubFileStore(
          tree: candidateTree, owner: owner, namespace: approved.planDigest)
        _ = try await store.data(configuration, at: "install-config.json", mode: 0o600)
        _ = try await store.data(payloadManifest, at: "AuraPayloads/manifest.json", mode: 0o600)
        for (path, identity) in files {
          if path == "raw/aura-raw.bin" {
            _ = try await store.file(
              system, path: "Finish Installation.app/Contents/Resources/boot.bin",
              identity: identity, at: "AuraPayloads/" + path)
          } else {
            _ = try await store.file(
              esp.tree, path: path == "raw/boot.bin" ? "m1n1/boot.bin" : path,
              identity: identity, at: "AuraPayloads/" + path)
          }
        }
        try verifyData(candidate, expected: expected)
        try RecoveryFileTransaction.flushTree(candidate)
        let (parent, leaf) = try system.writableParent(relative)
        defer { close(parent) }
        guard renameatx_np(parent, candidateName, parent, leaf, UInt32(RENAME_EXCL)) == 0,
          fsync(parent) == 0
        else { throw NativeStubFileError.writeFailed }
      }
      try verifyData(destination, expected: expected)
      try NativeRecoveryTemplate.publishApp(
        template,
        to: systemRoot.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName),
        owner: owner, verify: { try verifyApp($0, template.requirement) })
      let launcher = try system.read(
        "Finish Installation.app/Contents/Resources/step2.sh", maximum: 65536)
      guard
        String(data: launcher, encoding: .utf8)?.contains(
          "../../../Aurora Installer.app/Contents/MacOS/OmarchyRecovery") == true,
        let marker = try PropertyListSerialization.propertyList(
          from: system.read(".IAPhysicalMedia", maximum: 65536), format: nil) as? [String: Any],
        marker["AppName"] as? String == InstallerProductIdentity.recoveryAppBundleName
      else { throw NativeHandoffValidationError.changedContent }
      try target.verifyUnchanged()
      try file.publishEvidence(
        json([
          "plan_digest": approved.planDigest,
          "publication_sha256": NativeStubFileStore.hash(publication),
        ]),
        identifier: "native-recovery-staged")
    }

    private func verifyData(_ root: URL, expected: [String: NativeStubFileIdentity]) throws {
      let root = root.resolvingSymlinksInPath()
      let tree = try NativeHandoffFileTree(root, protected: true, owner: owner)
      let store = NativeStubFileStore(tree: tree, owner: owner)
      var actual = Set<String>()
      for name in try NativeFirmwareInputFiles.relativeEntries(root: root, maximum: 1024) {
        let url = root.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeHandoffValidationError.unsafePath }
        if info.st_mode & S_IFMT == S_IFDIR { continue }
        guard let identity = expected[name],
          try store.identity(name, maximum: 256 << 20) == identity
        else { throw NativeHandoffValidationError.changedContent }
        actual.insert(name)
      }
      guard actual == Set(expected.keys) else { throw NativeHandoffValidationError.changedContent }
    }

    private func json(_ value: [String: Any]) throws -> Data {
      try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func identity(_ data: Data) -> NativeStubFileIdentity {
      NativeStubFileIdentity(bytes: data.count, sha256: NativeStubFileStore.hash(data))
    }
  }

  extension Dictionary where Key == String {
    fileprivate func mapKeys(_ transform: (String) -> String) -> [String: Value] {
      Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
  }
#endif
