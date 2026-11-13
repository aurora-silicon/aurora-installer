#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// Where a firmware source keeps the files a stub needs. Both layouts
  /// carry the same files under the same names; an update archive keeps
  /// them under `AssetData`, selects its update identity, and stores its
  /// Recovery image as a whole-image patch stream.
  enum NativeRestoreSourceLayout: Equatable, Sendable {
    /// A full restore image, `UniversalMac_*_Restore.ipsw`.
    case restoreImage
    /// A full OTA update archive, `com_apple_MobileAsset_MacSoftwareUpdate/*.zip`.
    /// macOS 14.8.3, the firmware the M3 Macs use, ships only as one.
    case updateArchive

    /// The layout the sealed policy's source URL names, or nil for any
    /// other kind of file.
    init?(sourceURL: URL) {
      let path = sourceURL.path.lowercased()
      if path.hasSuffix(".ipsw") {
        self = .restoreImage
      } else if path.hasSuffix(".zip"),
        sourceURL.pathComponents.contains("com_apple_MobileAsset_MacSoftwareUpdate")
      {
        self = .updateArchive
      } else {
        return nil
      }
    }

    var variant: String {
      self == .restoreImage ? "macOS Customer" : "macOS Customer Software Update"
    }
    var restoreBehavior: String { self == .restoreImage ? "Erase" : "Update" }

    /// The archive member holding the restore file at `path`.
    func member(_ path: String) -> String {
      guard self == .updateArchive else { return path }
      return (path.hasPrefix("BootabilityBundle/") ? "AssetData/Restore/" : "AssetData/boot/")
        + path
    }

    /// The Recovery image an update archive keeps apart from its manifest,
    /// whose BaseSystem entry names a file the archive doesn't carry.
    static let updateRecoveryMember =
      "AssetData/payloadv2/basesystem_patches/arm64eBaseSystem.dmg"
  }

  struct NativeStubFilePlan: Sendable {
    struct Copy: Codable, Equatable, Sendable {
      let member: String
      let role: String
      let path: String
      let installerDataName: String?
    }
    let archive: IPSWArchive
    let source: NativeFirmwareSelection
    let deviceClass: String
    let manifest: Data
    let systemVersion: Data
    let stubInfo: Data
    let restorePath: String
    let layout: NativeRestoreSourceLayout
    let recoveryMember: IPSWArchiveMember
    /// How an update archive's Recovery member decodes to the image the stub
    /// keeps. Nil for a restore image, whose member is the image itself or
    /// an Apple Encrypted Archive of it.
    let recoveryImage: UpdateArchiveFullImage.Header?
    let copies: [Copy]
    let linkTargets: [String: String]

    /// `admitRecords` false selects the same files without reading each
    /// member's local record. Only a space estimate may skip that admission;
    /// the stub stage itself always admits every record before disk work.
    init(
      archive: IPSWArchive, source: NativeFirmwareSelection, deviceClass: String,
      boardID: UInt64, chipID: UInt64, admitRecords: Bool = true
    ) async throws {
      self.archive = archive
      self.source = source
      self.deviceClass = deviceClass
      // The policy's URL names the layout, and the archive must have it:
      // never read an update archive as a restore image, or the reverse.
      guard let layout = NativeRestoreSourceLayout(sourceURL: source.sourceURL) else {
        throw NativeFirmwareSelectionError.invalidSource
      }
      self.layout = layout
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      let otherManifest =
        layout == .restoreImage ? "AssetData/boot/BuildManifest.plist" : "BuildManifest.plist"
      guard members[otherManifest] == nil else { throw NativeStubFileError.invalidPlan }
      // An update archive must carry a whole Recovery image. Check that first,
      // so an archive that patches an earlier one is named as such, whatever
      // else it lacks.
      let update: (member: IPSWArchiveMember, header: UpdateArchiveFullImage.Header)?
      if layout == .updateArchive {
        guard let member = members[NativeRestoreSourceLayout.updateRecoveryMember],
          !member.isDirectory, member.sizeBytes > 0
        else { throw NativeFirmwareSelectionError.updateArchiveOnly(version: source.version) }
        do {
          let header = try await archive.readPrefix(
            member, maximumBytes: UpdateArchiveFullImage.headerBytes)
          update = (
            member, try UpdateArchiveFullImage.Header(header, memberBytes: member.sizeBytes)
          )
        } catch is UpdateArchiveImagePatchUnsupported {
          throw NativeFirmwareSelectionError.updateArchiveOnly(version: source.version)
        } catch is RestoreFailure {
          throw NativeStubFileError.invalidImage
        }
      } else {
        update = nil
      }
      guard members[layout.member("BuildManifest.plist")] != nil else {
        throw NativeStubFileError.invalidPlan
      }
      func read(_ name: String) async throws -> Data {
        guard let member = members[layout.member(name)] else {
          throw NativeStubFileError.invalidPlan
        }
        return try await archive.read(member, maximumBytes: 32 << 20)
      }
      func plist(_ data: Data) throws -> [String: Any] {
        guard
          let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { throw NativeStubFileError.invalidPlan }
        return object
      }
      try source.requirePinnedSource(bytes: archive.sizeBytes)
      let manifestBytes = try await read("BuildManifest.plist")
      var document = try plist(manifestBytes)
      let caches = try plist(await read("usr/standalone/bootcaches.plist"))
      var version = try plist(await read("SystemVersion.plist"))
      guard let bless = caches["bless2"] as? [String: Any],
        bless["RestoreBundlePath"] == nil || bless["RestoreBundlePath"] is String
      else { throw NativeStubFileError.invalidPlan }
      let rawRestore = bless["RestoreBundlePath"] as? String ?? "./Restore"
      let restore = rawRestore.hasPrefix("./") ? String(rawRestore.dropFirst(2)) : rawRestore
      guard let identities = document["BuildIdentities"] as? [[String: Any]],
        let identity = identities.first(where: {
          guard let board = $0["ApBoardID"] as? String, let chip = $0["ApChipID"] as? String,
            let info = $0["Info"] as? [String: Any]
          else { return false }
          return board.hasPrefix("0x") && chip.hasPrefix("0x")
            && UInt64(board.dropFirst(2), radix: 16) == boardID
            && UInt64(chip.dropFirst(2), radix: 16) == chipID
            && info["DeviceClass"] as? String == deviceClass
            && info["RestoreBehavior"] as? String == layout.restoreBehavior
            && info["Variant"] as? String == layout.variant
        }),
        let info = identity["Info"] as? [String: Any],
        let buildNumber = info["BuildNumber"] as? String,
        let board = identity["ApBoardID"] as? String, let chip = identity["ApChipID"] as? String,
        let components = identity["Manifest"] as? [String: [String: Any]],
        NativeHandoffEvidence.safeRelative(restore),
        let visible = version["ProductUserVisibleVersion"] as? String,
        version["ProductVersion"] as? String == source.version,
        let recovery = components["BaseSystem"]?["Info"] as? [String: Any],
        let recoveryName = recovery["Path"] as? String,
        let recoveryMember = update?.member ?? members[recoveryName],
        !recoveryMember.isDirectory, recoveryMember.sizeBytes > 0,
        recoveryMember.sizeBytes <= 8 << 30
      else { throw NativeStubFileError.invalidPlan }
      try source.requirePinnedManifest(manifestBytes, buildNumber: buildNumber)
      self.restorePath = restore
      self.recoveryMember = recoveryMember
      recoveryImage = update?.header
      document["BuildIdentities"] = [identity]
      manifest = try PropertyListSerialization.data(
        fromPropertyList: document, format: .xml, options: 0)
      version["ProductUserVisibleVersion"] = visible + " (stub)"
      systemVersion = try PropertyListSerialization.data(
        fromPropertyList: version, format: .xml, options: 0)
      let summary: [String: Any] = [
        "system_version": version,
        "manifest_info": [
          "build_number": buildNumber,
          "variant": layout.variant, "device_class": deviceClass,
          "board_id": board, "chip_id": chip,
        ],
      ]
      guard JSONSerialization.isValidJSONObject(summary) else {
        throw NativeStubFileError.invalidPlan
      }
      stubInfo = try JSONSerialization.data(
        withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])

      var copies = [Copy]()
      // `name` is the file's path in a restore image; `add` copies the
      // member that holds it in this layout.
      func add(_ name: String, _ role: String, _ path: String, data: String? = nil) throws {
        let member = layout.member(name)
        guard NativeHandoffEvidence.safeRelative(member), NativeHandoffEvidence.safeRelative(path),
          let entry = members[member], !entry.isDirectory, entry.sizeBytes > 0,
          entry.sizeBytes <= 8 << 30
        else { throw NativeStubFileError.invalidPlan }
        if let existing = copies.first(where: { $0.role == role && $0.path == path }) {
          guard existing.member == member else { throw NativeStubFileError.invalidPlan }
          return
        }
        copies.append(Copy(member: member, role: role, path: path, installerDataName: data))
      }
      try add("usr/standalone/bootcaches.plist", "System", "usr/standalone/bootcaches.plist")
      try add(
        "PlatformSupport.plist", "System", "System/Library/CoreServices/PlatformSupport.plist")
      for name in [
        "SystemVersion.plist", "RestoreVersion.plist", "usr/standalone/bootcaches.plist",
      ] {
        try add(
          name, "Preboot", restore + "/" + name,
          data: name == "RestoreVersion.plist" ? name : nil)
      }
      func tree(_ prefix: String, at destination: String) throws {
        let stored = layout.member(prefix) + "/"
        let files = archive.members.filter { $0.name.hasPrefix(stored) && !$0.isDirectory }
        guard !files.isEmpty else { throw NativeStubFileError.invalidPlan }
        for file in files.sorted(by: { $0.name < $1.name }) {
          let relative = String(file.name.dropFirst(stored.count))
          try add(prefix + "/" + relative, "Preboot", destination + "/" + relative)
        }
      }
      let bootability = "BootabilityBundle/Restore/Bootability"
      try tree(bootability, at: restore + "/Bootability")
      try add(
        "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", "Preboot",
        restore + "/Bootability/Bootability.trustcache")
      try tree("Firmware/Manifests/restore/" + layout.variant, at: restore)
      for key in components.keys.sorted() where Self.restores(component: key) {
        guard let value = components[key]?["Info"] as? [String: Any],
          let path = value["Path"] as? String
        else {
          throw NativeStubFileError.invalidPlan
        }
        try add(
          path, "Preboot", restore + "/" + path,
          data: path.hasPrefix("kernelcache.") ? URL(fileURLWithPath: path).lastPathComponent : nil)
      }
      guard copies.count <= 10000,
        copies.reduce(
          UInt64(recoveryImage?.outputBytes ?? recoveryMember.sizeBytes),
          { $0 + UInt64(members[$1.member]!.sizeBytes) }) <= 16 << 30
      else { throw NativeStubFileError.invalidPlan }
      // Admit every selected local record before disk preparation. Links are
      // confined to the selected framework tree and are never extraction paths.
      var links = [String: String]()
      let selected = Set(copies.map(\.member) + [recoveryMember.name])
      for name in selected.sorted() where admitRecords {
        let member = members[name]!
        if member.isSymbolicLink {
          guard name.hasPrefix(layout.member(bootability) + "/"),
            !selected.contains(where: { $0.hasPrefix(name + "/") })
          else { throw NativeStubFileError.invalidPlan }
          links[name] = try await archive.symbolicLinkTarget(member)
        } else {
          _ = try await archive.dataOffset(for: member)
        }
      }
      for name in links.keys {
        var target = name
        var visited = Set<String>()
        while true {
          let components = target.split(separator: "/").map(String.init)
          var replaced = false
          for count in 1...components.count {
            let prefix = components.prefix(count).joined(separator: "/")
            if let link = links[prefix] {
              guard visited.insert(prefix).inserted, visited.count <= 40 else {
                throw NativeStubFileError.invalidPlan
              }
              target =
                (Array(components.prefix(count - 1)) + link.split(separator: "/").map(String.init)
                + Array(components.dropFirst(count))).joined(separator: "/")
              replaced = true
              break
            }
          }
          if !replaced { break }
        }
        guard selected.contains(target) || selected.contains(where: { $0.hasPrefix(target + "/") })
        else { throw NativeStubFileError.invalidPlan }
      }
      self.copies = copies
      self.linkTargets = links
    }

    /// Whether the stub's restore directory gets a manifest component. The
    /// rest are images the stub doesn't boot; in an update archive some
    /// name files outside its boot directory, such as `../Restore/…dmg`.
    static func restores(component key: String) -> Bool {
      ![
        "BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "RestoreRamDisk",
        "RestoreTrustCache",
      ].contains(key) && !key.hasPrefix("Cryptex")
    }

    /// A file copied straight into the restore directory. Its member, like
    /// the Recovery image, is decoded on macOS first when it is an Apple
    /// Encrypted Archive.
    func isTopLevelRestore(_ copy: Copy) -> Bool {
      copy.role == "Preboot" && copy.path.hasPrefix(restorePath + "/")
        && !String(copy.path.dropFirst(restorePath.count + 1)).contains("/")
    }

    /// Every member the stub stage restores through `restore`, which decodes
    /// an Apple Encrypted Archive on macOS before copying it.
    var restoredMembers: [IPSWArchiveMember] {
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      var seen = Set<String>()
      return
        (copies.filter { linkTargets[$0.member] == nil && isTopLevelRestore($0) }.compactMap {
          members[$0.member]
        } + [recoveryMember]).filter { seen.insert($0.name).inserted }
    }

    /// Roughly what the stub keeps from the restore image: the members as the
    /// archive stores them, and the Recovery image as it is decoded, as the
    /// plan's own size limit counts it.
    var estimatedStubBytes: UInt64 {
      let sizes = Dictionary(
        archive.members.map { ($0.name, UInt64($0.sizeBytes)) },
        uniquingKeysWith: { first, _ in first })
      return copies.reduce(UInt64(recoveryImage?.outputBytes ?? recoveryMember.sizeBytes)) {
        $0 + (sizes[$1.member] ?? 0)
      }
    }

    /// Every member whose body the stub stage reads from the archive. Links
    /// were read while admitting the plan.
    var readMembers: [IPSWArchiveMember] {
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      var seen = Set<String>()
      return
        (copies.filter { linkTargets[$0.member] == nil }.compactMap { members[$0.member] }
        + [recoveryMember]).filter { seen.insert($0.name).inserted }
    }
  }
#endif
