#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import RecoveryAccountCore

  struct NativeVendorFirmware: Sendable {
    struct Receipt: Codable, Equatable, Sendable {
      let plan: String
      let groupUUID: String
      let espUUID: String
      let sourceBinding: String
      let files: [String: NativeStubFileIdentity]
      let installerData: [String: NativeStubFileIdentity]
    }
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let plan: NativeStubFilePlan
    let peripherals: PreparedNativePeripheralInputs?
    var owner: uid_t = 0
    var environment: NativeHandoffEnvironment = .live
    var disks: NativeAPFSPlatform = .live
    var ambientLight: @Sendable () throws -> Data? = { try NativeAmbientLightInputs.live() }
    var openImage: @Sendable (URL, URL) throws -> NativeFirmwareMountedImage = {
      try NativeFirmwareMountedImage.open(image: $0, parent: $1)
    }
    var factoryFiles: @Sendable (String) throws -> [String: Data] = {
      try NativeFactoryCalibrationInput.snapshot(storeIdentifier: $0)
    }
    var admitESPFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization, bootstrap: NativeSourceBootstrap
    ) async throws -> Receipt {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let target = try NativeInstallationTarget(
        package: package, approved: approved, journal: file, authorization: authorization,
        bootstrap: bootstrap, owner: owner, environment: environment, disks: disks)
      let source = try NativeFirmwareSourcePlan(manifest: plan.manifest)
      guard source.machine == String(package.deviceIdentifier.dropFirst(6)) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let binding = try file.readEvidence("native-stub-file-binding")
      let espStore = try NativeESPFileStore(
        root: target.espRoot(), volumeDevice: target.esp.identifier,
        namespace: approved.planDigest + "-firmware", verifyMount: environment.verifyMount,
        admitFilesystem: admitESPFilesystem)
      if try file.containsEvidence("native-vendor-firmware") {
        let receipt = try JSONDecoder().decode(
          Receipt.self, from: file.readEvidence("native-vendor-firmware"))
        guard receipt.plan == approved.planDigest, receipt.groupUUID == target.group,
          receipt.espUUID == target.esp.uuid,
          receipt.sourceBinding == NativeStubFileStore.hash(binding)
        else { throw NativeFirmwareInputFailure.invalidSource }
        for (name, identity) in receipt.files.merging(
          receipt.installerData,
          uniquingKeysWith: { _, _ in
            NativeStubFileIdentity(bytes: -1, sha256: "")
          })
        {
          guard try espStore.identity(name, maximum: 256 << 20) == identity else {
            throw NativeStubFileError.changedFile
          }
        }
        return receipt
      }
      var outputs = [String: Data]()
      var lsci: Data?
      if package.deviceIdentifier == "apple,j700" {
        guard let peripherals else { throw NativeFirmwareInputFailure.invalidSource }
        let tree = try NativeHandoffFileTree(peripherals.directory, protected: true, owner: owner)
        let peripheralManifest = try JSONDecoder().decode(
          NativeNeoPeripheralPreparer.Manifest.self,
          from: tree.read("manifest.json", maximum: 1 << 20))
        guard peripheralManifest.schema == 1, peripheralManifest.converter == "neo-v1",
          peripheralManifest.deviceIdentifier == package.deviceIdentifier,
          peripheralManifest.bindingDigest == package.bindingDigest,
          peripheralManifest.planDigest == approved.planDigest,
          peripheralManifest.metadataDigest == approved.metadataDigest,
          peripheralManifest.payloadDigest == approved.payloadDigest,
          peripheralManifest.recipeSHA256 == peripherals.recipeSHA256,
          peripheralManifest.files.count <= 4096
        else { throw NativeFirmwareInputFailure.invalidSource }
        for (name, record) in peripheralManifest.files {
          let data = try tree.read("files/" + name, maximum: 64 << 20)
          guard data.count == record.bytes, NativeStubFileStore.hash(data) == record.sha256 else {
            throw NativeFirmwareInputFailure.invalidSource
          }
          if name == "fallback/lsci.bin" { lsci = data } else { outputs[name] = data }
        }
        guard NeoFirmwareConversions.requiredCameraNames.isSubset(of: Set(outputs.keys)),
          NeoFirmwareConversions.requiredRadioNames.isSubset(of: Set(outputs.keys)),
          outputs[NeoFirmwareConversions.alsName] != nil, lsci != nil
        else { throw NativeFirmwareInputFailure.invalidSource }
      } else if peripherals != nil {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let work = package.packageURL.deletingLastPathComponent().appendingPathComponent(
        "vendor-firmware-" + UUID().uuidString.lowercased())
      try FileManager.default.createDirectory(
        at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let cleanup = try PreparedNativePeripheralInputs(
        directory: work,
        recipeSHA256: peripherals?.recipeSHA256 ?? NativeStubFileStore.hash(plan.manifest),
        owner: owner)
      return try await PreparedNativePeripheralInputs.withCleanup(cleanup) {
        let sourceRecords = try InstallerPerformance.measure("vendor_source_records") {
          try self.sourceRecords(file, binding: binding, target: target)
        }
        let preboot = try target.tree("Preboot")
        let recovery = try target.tree("Recovery")
        var fallback = [String: Data]()
        var radioLinks = [String: String]()
        func read(_ role: String, _ path: String, maximum: Int) throws -> Data {
          guard let record = sourceRecords.first(where: { $0.role == role && $0.path == path })
          else {
            throw NativeFirmwareInputFailure.invalidSource
          }
          return try NativeFirmwareInputFiles.read(
            role == "Preboot" ? preboot : recovery,
            path: path, maximum: maximum, owner: owner, expected: record.identity)
        }
        let restore = target.group + "/" + plan.restorePath + "/"
        for item in source.fud {
          let data: Data
          if let existing = fallback["fud_firmware/" + item.member] {
            data = existing
          } else {
            data = try read("Preboot", restore + item.member, maximum: 64 << 20)
            fallback["fud_firmware/" + item.member] = data
          }
          if item.component == "Multitouch" {
            let converted = try MultitouchFirmware.convert(data, machine: source.machine)
            guard !converted.isEmpty else { throw NativeFirmwareInputFailure.invalidSource }
            try merge(converted, into: &outputs)
          }
        }
        if source.machine == "j700" {
          guard let trackpad = outputs[NeoFirmwareConversions.trackpadName], !trackpad.isEmpty
          else { throw NativeFirmwareInputFailure.invalidSource }
        }
        try InstallerPerformance.measure("vendor_kernel") {
          let kernel = try read("Preboot", restore + source.kernel, maximum: 256 << 20)
          let decoded = try FirmwareImage.decode(kernel)
          guard decoded.type == "krnl" else { throw NativeFirmwareInputFailure.invalidSource }
          try merge(FirmwareImage.controllerFirmware(in: decoded.bytes), into: &outputs)
        }
        let recoveryPath = target.group + "/usr/standalone/firmware/arm64eBaseSystem.dmg"
        guard
          let imageRecord = sourceRecords.first(where: {
            $0.role == "Recovery" && $0.path == recoveryPath
          })
        else { throw NativeFirmwareInputFailure.invalidSource }
        let recoveryStore = NativeStubFileStore(tree: recovery, owner: owner)
        guard try recoveryStore.identity(recoveryPath) == imageRecord.identity else {
          throw NativeFirmwareInputFailure.invalidSource
        }
        let image = try InstallerPerformance.measure("vendor_mount") {
          try openImage(
            target.root("Recovery").appendingPathComponent(recoveryPath),
            package.packageURL.deletingLastPathComponent())
        }
        try await NativeFirmwareMountedImage.withCleanup(image) {
          let imageTree = try InstallerPerformance.measure("vendor_image_tree") {
            try NativeHandoffFileTree(
              image.root, protected: true, owner: owner,
              volumeRoot: true, volumeDevice: image.device, readOnlyVolume: true,
              verifyMount: environment.verifyMount)
          }
          let radio = try InstallerPerformance.measure("vendor_radio_snapshot") {
            try NativeFirmwareInputFiles.snapshot(
              root: image.root, prefix: "usr/share/firmware", tree: imageTree, owner: owner)
          }
          for (name, data) in radio.files { fallback["firmware/" + name] = data }
          // The image's radio aliases stay links in the fallback archive.
          for (name, target) in radio.links {
            radioLinks["firmware/" + name] = String(target.split(separator: "/").last!)
          }
          let wifi = try BroadcomFirmware.wifi(
            subtree(radio.files, "wifi/"), links: sublinks(radio.links, "wifi/"))
          let bluetooth = try BroadcomFirmware.bluetooth(
            subtree(radio.files, "bluetooth/"), links: sublinks(radio.links, "bluetooth/"))
          guard package.deviceIdentifier == "apple,j700" || (!wifi.isEmpty && !bluetooth.isEmpty)
          else { throw NativeFirmwareInputFailure.invalidSource }
          try merge(wifi, into: &outputs)
          try merge(bluetooth, into: &outputs)
          try InstallerPerformance.measure("vendor_cameras") {
            for path in [
              "usr/sbin/appleh13camerad", "usr/sbin/appleh16camerad",
              "usr/libexec/appleh13camerad", "usr/libexec/appleh16camerad",
            ] {
              if try !imageTree.isAbsent(path) {
                let data = try imageTree.read(path, maximum: 16 << 20)
                let name = String(path.split(separator: "/").last!)
                try merge([name: data], into: &fallback)
                if package.deviceIdentifier != "apple,j700" {
                  try merge(
                    NeoFirmwareConversions.camera(data, requireNeoSet: false), into: &outputs)
                }
              }
            }
          }
        }
        let factory = try InstallerPerformance.measure("vendor_factory") {
          try factoryFiles(package.storeIdentifier)
        }
        for (name, data) in factory {
          fallback["com.apple.factorydata/" + name] = data
        }
        if package.deviceIdentifier == "apple,j700" {
          fallback[NeoFirmwareConversions.alsName] = outputs[NeoFirmwareConversions.alsName]
          fallback["j700-exbright-LSCI.bin"] = lsci
        } else {
          let calibration = try NativeAmbientLightInputs.files(
            calibration: ambientLight(), factory: factory)
          try merge(calibration, into: &outputs)
          try merge(calibration, into: &fallback)
        }
        let archives = try InstallerPerformance.measure("vendor_package") {
          try FirmwarePackageBuilder.build(
            outputs.keys.sorted().map { FirmwarePackageInput(name: $0, bytes: outputs[$0]!) })
        }
        let published: [String: Data] = [
          "vendorfw/firmware.tar": archives.tar, "vendorfw/firmware.cpio": archives.cpio,
          "vendorfw/manifest.txt": archives.manifest,
          "vendorfw/u-boot/asmedia/asm2214a-apple.bin": outputs["asmedia/asm2214a-apple.bin"]!,
        ]
        var files = [String: NativeStubFileIdentity]()
        try InstallerPerformance.measure("vendor_write") {
          for (name, bytes) in published {
            try NativeFirmwareInputFiles.write(bytes, to: work.appendingPathComponent(name))
            files[name] = NativeStubFileIdentity(
              bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
          }
        }
        let aliases = Dictionary(
          uniqueKeysWithValues: source.fud.map {
            ("fud_firmware/" + source.machine + "/" + $0.component + ".im4p", "../" + $0.member)
          }
        ).merging(radioLinks) { first, _ in first }
        try InstallerPerformance.measure("vendor_fallback") {
          let fallbackArchive = try FirmwarePackageBuilder.fallback(
            fallback.keys.sorted().map { FirmwarePackageInput(name: $0, bytes: fallback[$0]!) },
            symbolicLinks: aliases)
          try NativeFirmwareInputFiles.write(
            fallbackArchive, to: work.appendingPathComponent("asahi/all_firmware.tar.gz"))
        }
        let workTree = try InstallerPerformance.measure("vendor_work_tree") {
          try NativeHandoffFileTree(work, protected: true, owner: owner)
        }
        let workStore = NativeStubFileStore(tree: workTree, owner: owner)
        let fallbackIdentity = try InstallerPerformance.measure("vendor_fallback_identity") {
          try workStore.identity("asahi/all_firmware.tar.gz", maximum: 256 << 20)
        }
        var installerData = ["asahi/all_firmware.tar.gz": fallbackIdentity]
        try InstallerPerformance.measure("vendor_stub_info") {
          let sourceReceipt =
            try JSONSerialization.jsonObject(
              with: file.readEvidence("native-stub-files")) as! [String: Any]
          try NativeFirmwareInputFiles.write(
            JSONSerialization.data(
              withJSONObject: sourceReceipt["stub_info"]!, options: [.sortedKeys]),
            to: work.appendingPathComponent("asahi/stub_info.json"))
          installerData["asahi/stub_info.json"] = try workStore.identity(
            "asahi/stub_info.json", maximum: 1 << 20)
        }
        try await InstallerPerformance.measuring("vendor_installer_data") {
          for record in sourceRecords where record.installerDataName != nil {
            let name = record.installerDataName!
            guard NativeHandoffEvidence.safeRelative(name), !name.contains("/") else {
              throw NativeFirmwareInputFailure.invalidSource
            }
            let inputTree = try target.tree(record.role)
            let descriptor = try inputTree.fileDescriptor(record.path)
            defer { close(descriptor) }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
              throw NativeFirmwareInputFailure.invalidSource
            }
            let identity = try await workStore.local(
              URL(fileURLWithPath: String(cString: path)), at: "asahi/" + name, compressed: false)
            guard identity == record.identity else {
              throw NativeFirmwareInputFailure.invalidSource
            }
            installerData["asahi/" + name] = identity
          }
        }
        try await InstallerPerformance.measuring("vendor_esp_publish") {
          for (name, identity) in files.merging(
            installerData, uniquingKeysWith: { first, _ in first })
          {
            _ = try await espStore.file(
              workTree, path: name, identity: identity, owner: owner, at: name)
          }
        }
        try InstallerPerformance.measure("vendor_verify") { try target.verifyUnchanged() }
        let receipt = Receipt(
          plan: approved.planDigest, groupUUID: target.group, espUUID: target.esp.uuid,
          sourceBinding: NativeStubFileStore.hash(binding), files: files,
          installerData: installerData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try file.publishEvidence(encoder.encode(receipt), identifier: "native-vendor-firmware")
        return receipt
      }
    }

    private func sourceRecords(
      _ file: NativeInstallJournalFile, binding: Data, target: NativeInstallationTarget
    ) throws -> [NativeStubFilesExecution.Installed] {
      guard
        let receipt = try JSONSerialization.jsonObject(
          with: file.readEvidence("native-stub-files")) as? [String: Any],
        receipt["plan_digest"] as? String == approved.planDigest,
        receipt["binding_sha256"] as? String == NativeStubFileStore.hash(binding),
        receipt["group_uuid"] as? String == target.group,
        receipt["source_url"] as? String == plan.source.sourceURL.absoluteString,
        receipt["firmware_version"] as? String == plan.source.version,
        let records = receipt["files"]
      else { throw NativeFirmwareInputFailure.invalidSource }
      return try JSONDecoder().decode(
        [NativeStubFilesExecution.Installed].self,
        from: JSONSerialization.data(withJSONObject: records))
    }

    /// Links below `prefix`, with both names relative to it.
    private func sublinks(_ links: [String: String], _ prefix: String) -> [String: String] {
      Dictionary(
        uniqueKeysWithValues: links.filter {
          $0.key.hasPrefix(prefix) && $0.value.hasPrefix(prefix)
        }
        .map { (String($0.key.dropFirst(prefix.count)), String($0.value.dropFirst(prefix.count))) })
    }

    private func subtree(_ files: [String: Data], _ prefix: String) -> [String: Data] {
      Dictionary(
        uniqueKeysWithValues: files.filter { $0.key.hasPrefix(prefix) }.map {
          (String($0.key.dropFirst(prefix.count)), $0.value)
        })
    }

    private func merge(_ added: [String: Data], into outputs: inout [String: Data]) throws {
      for (name, data) in added {
        guard outputs[name] == nil || outputs[name] == data else {
          throw NativeFirmwareInputFailure.invalidSource
        }
        outputs[name] = data
      }
    }
  }
#endif
