#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  enum NativePayloadPreflightError: Error, Equatable {
    case invalidMetadata
    case invalidPartitions
    case invalidPayload
    case invalidFilesystem
    case unsupportedRecovery
  }

  /// Read-only payload, firmware-selection and boot-chain admission. Source
  /// ownership, firmware conversion and live disk geometry remain separate
  /// execution gates; this check does not authorize a disk operation.
  enum NativePayloadPreflight {
    static func check(
      _ package: ImportedEngineHandoffPackage, owner: uid_t = 0,
      firmwareFacts: @Sendable () throws -> NativeFirmwareSelection.Facts = {
        try NativeFirmwareSelection.Facts.live()
      }
    ) async throws {
      guard package.metadataURL.deletingLastPathComponent().path == package.packageURL.path,
        package.payloadURL.deletingLastPathComponent().path == package.packageURL.path
      else { throw NativePayloadPreflightError.invalidPayload }
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try tree.read(package.metadataURL.lastPathComponent, maximum: 65_536)
      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: owner))
      try await validate(
        metadata: metadata, payloadName: package.payloadURL.lastPathComponent, archive: archive)
      let firmware = try NativeFirmwareSelection.choose(
        deviceIdentifier: package.deviceIdentifier, facts: firmwareFacts(),
        metadata: NativeInstallationMetadata(data: metadata),
        policy: NativeInspectionPolicy.sealed())
      _ = try await NativeBootChain.admit(
        metadata: metadata, archive: archive, deviceIdentifier: package.deviceIdentifier,
        firmware: firmware.version.components(separatedBy: " ")[0])
    }

    /// The caller has already authenticated the archive and supplied the
    /// helper's signed native Recovery template. Embedded legacy Recovery apps
    /// are never used by this execution path.
    static func validate(metadata: Data, payloadName: String, archive: IPSWArchive) async throws {
      let template = try target(metadata)
      let contracts = [
        "fedora-btrfs-v1": ("fedora", "btrfs"), "alarm-ext4-v1": ("arch", "ext4"),
        "alarm-btrfs-v1": ("arch", "btrfs"), "nixos-ext4-v1": ("nixos", "ext4"),
        "nixos-btrfs-v1": ("nixos", "btrfs"),
      ]
      var icon = PublishedContractNames.legacyVolumeIcon
      var filesystem: String?
      if let layout = template["layout_kind"], !(layout is NSNull) {
        guard let layout = layout as? String, let contract = contracts[layout],
          let profile = template["installation_profile"] as? String,
          ["kde", "gnome", "minimal"].map({ contract.0 + "-" + $0 }).contains(profile)
        else { throw NativePayloadPreflightError.invalidMetadata }
        icon = "aurora-volume.icns"
        filesystem = contract.1
      }
      guard template["package"] as? String == payloadName,
        template["boot_object"] as? String == "m1n1.bin",
        template["next_object"] as? String == "m1n1/boot.bin",
        template["icon"] as? String == icon
      else { throw NativePayloadPreflightError.invalidMetadata }
      if let mode = template["recovery_gui"], !(mode is NSNull),
        mode as? String != PublishedContractNames.nativeRecoveryGUI
      {
        throw NativePayloadPreflightError.unsupportedRecovery
      }
      guard let partitions = template["partitions"] as? [[String: Any]], partitions.count == 3
      else { throw NativePayloadPreflightError.invalidPartitions }
      for (index, partition) in partitions.enumerated() {
        let source = partition["source"]
        let image = partition["image"]
        guard partition["name"] as? String == ["EFI", "Boot", "Root"][index],
          partition["type"] as? String == (index == 0 ? "EFI" : "Linux"),
          index == 0 ? source as? String == "esp" : absent(source),
          index == 0 ? absent(image) : image as? String == ["", "boot.img", "root.img"][index],
          try flag(partition["expand"], default: false) == (index == 2)
        else { throw NativePayloadPreflightError.invalidPartitions }
      }
      guard partitions[0]["format"] as? String == "fat",
        try flag(partitions[0]["copy_firmware"]) == true,
        try flag(partitions[0]["copy_installer_data"]) == true
      else { throw NativePayloadPreflightError.invalidPartitions }
      try await archive.validateEntries()
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      for name in ["boot.img", "root.img", "esp/m1n1/boot.bin", "esp/EFI/BOOT/BOOTAA64.EFI", icon] {
        guard let member = members[name], !member.isDirectory, member.sizeBytes > 0 else {
          throw NativePayloadPreflightError.invalidPayload
        }
      }
      var bootHeader: Data?
      for (index, name) in ["boot.img", "root.img"].enumerated() {
        guard let size = partitions[index + 1]["size"] as? String,
          let capacity = try? NativeInstallationMetadata.bytes(size),
          let member = members[name], UInt64(member.sizeBytes) <= capacity,
          member.sizeBytes % 4096 == 0
        else { throw NativePayloadPreflightError.invalidPartitions }
        if let filesystem {
          let header = try await archive.readPrefix(member, maximumBytes: 0x11000)
          let offset = index == 0 || filesystem == "ext4" ? 0x438 : 0x10040
          let magic = offset == 0x438 ? Data([0x53, 0xef]) : Data("_BHRfS_M".utf8)
          guard header.count >= offset + magic.count,
            header.subdata(in: offset..<(offset + magic.count)) == magic
          else { throw NativePayloadPreflightError.invalidFilesystem }
          if index == 0 { bootHeader = header }
        }
      }
      if (template["installation_profile"] as? String)?.hasPrefix("nixos-") == true {
        // Installation moves Boot to another GPT slot. Its EFI loader must
        // locate the filesystem by UUID, not the source image's slot number.
        guard let bootHeader, let member = members["esp/EFI/BOOT/BOOTAA64.EFI"],
          member.sizeBytes <= 16 << 20
        else { throw NativePayloadPreflightError.invalidPayload }
        // GRUB without a built-in prefix reads grub.cfg beside itself.
        var config: Data?
        if let entry = members["esp/EFI/BOOT/grub.cfg"], !entry.isDirectory,
          entry.sizeBytes <= 64 << 10
        {
          config = try await archive.read(entry, maximumBytes: 64 << 10)
        }
        guard
          portableGRUB(
            bootHeader: bootHeader,
            efi: try await archive.read(member, maximumBytes: 16 << 20), config: config)
        else { throw NativePayloadPreflightError.invalidPayload }
      }
    }

    /// GRUB finds Boot by its filesystem UUID, never by a GPT slot number:
    /// either through the script built into the EFI image, or, when the
    /// image has no built-in prefix, through the grub.cfg beside it that
    /// searches for that UUID and takes its prefix from the result.
    static func portableGRUB(bootHeader: Data, efi: Data, config: Data? = nil) -> Bool {
      let uuidOffset = 0x468
      guard bootHeader.count >= uuidOffset + 16,
        efi.starts(with: Data([0x4d, 0x5a]))
      else { return false }
      let bytes = bootHeader[uuidOffset..<(uuidOffset + 16)]
      guard bytes.contains(where: { $0 != 0 }) else { return false }
      let hex = bytes.map { String(format: "%02x", $0) }.joined()
      let first = String(hex.prefix(8))
      let second = String(hex.dropFirst(8).prefix(4))
      let third = String(hex.dropFirst(12).prefix(4))
      let fourth = String(hex.dropFirst(16).prefix(4))
      let fifth = String(hex.dropFirst(20))
      let uuid = [first, second, third, fourth, fifth].joined(separator: "-")
      let script = Data("search.fs_uuid \(uuid) root\nset prefix=($root)/grub\n".utf8)
      if efi.range(of: script) != nil { return true }
      guard let config, let text = String(data: config, encoding: .utf8),
        efi.range(of: Data("search.fs_uuid ".utf8)) == nil,
        String(decoding: efi, as: UTF8.self).range(
          of: #"\([A-Za-z0-9]*,(gpt|msdos)[0-9]+\)"#, options: .regularExpression) == nil
      else { return false }
      let searches = text.split(separator: "\n").contains { line in
        let words = line.split(separator: " ")
        return words.first == "search" && words.contains("--fs-uuid")
          && words.contains("--set=root") && words.last.map(String.init) == uuid
      }
      return searches && text.contains("set prefix=($root)/grub")
    }

    static func target(_ metadata: Data) throws -> [String: Any] {
      guard !metadata.isEmpty, metadata.count <= 65_536,
        let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
        Set(document.keys) == ["os_list"], let templates = document["os_list"] as? [[String: Any]]
      else { throw NativePayloadPreflightError.invalidMetadata }
      let matches = templates.filter {
        $0[PublishedContractNames.osTargetKey] as? String == PublishedContractNames.fullOSTarget
      }
      guard matches.count == 1, let template = matches.first else {
        throw NativePayloadPreflightError.invalidMetadata
      }
      return template
    }

    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func flag(_ value: Any?, default fallback: Bool? = nil) throws -> Bool {
      if value == nil, let fallback { return fallback }
      guard let number = value as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID()
      else { throw NativePayloadPreflightError.invalidPartitions }
      return number.boolValue
    }
  }
#endif
