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

  /// Read-only admission of the full-OS image contract. Source ownership,
  /// firmware conversion, board boot objects and live disk geometry are separate
  /// execution gates; this check does not authorize a disk operation.
  enum NativePayloadPreflight {
    static func check(_ package: ImportedEngineHandoffPackage, owner: uid_t = 0) async throws {
      guard package.metadataURL.deletingLastPathComponent().path == package.packageURL.path,
        package.payloadURL.deletingLastPathComponent().path == package.packageURL.path
      else { throw NativePayloadPreflightError.invalidPayload }
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try tree.read(package.metadataURL.lastPathComponent, maximum: 65_536)
      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: owner))
      try await validate(
        metadata: metadata, payloadName: package.payloadURL.lastPathComponent, archive: archive)
    }

    /// The caller has already authenticated the archive and supplied the
    /// helper's signed native Recovery template. Embedded legacy Recovery apps
    /// are never used by this execution path.
    static func validate(metadata: Data, payloadName: String, archive: IPSWArchive) async throws {
      guard !metadata.isEmpty, metadata.count <= 65_536,
        let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
        Set(document.keys) == ["os_list"], let templates = document["os_list"] as? [[String: Any]]
      else { throw NativePayloadPreflightError.invalidMetadata }
      let matches = templates.filter { $0["omarchy_target"] as? String == "apple-silicon-full-os" }
      guard matches.count == 1, let template = matches.first else {
        throw NativePayloadPreflightError.invalidMetadata
      }
      let contracts = [
        "fedora-btrfs-v1": ("fedora", "btrfs"), "alarm-ext4-v1": ("arch", "ext4"),
        "alarm-btrfs-v1": ("arch", "btrfs"), "nixos-ext4-v1": ("nixos", "ext4"),
        "nixos-btrfs-v1": ("nixos", "btrfs"),
      ]
      var icon = "omarchy-volume.icns"
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
        mode as? String != "omarchy-native-v1"
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
        }
      }
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
