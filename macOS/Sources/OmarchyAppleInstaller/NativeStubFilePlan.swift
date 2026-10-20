#if os(macOS)
  import AuroraFirmware
  import Foundation

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
    let recoveryMember: IPSWArchiveMember
    let copies: [Copy]
    let linkTargets: [String: String]

    init(
      archive: IPSWArchive, source: NativeFirmwareSelection, deviceClass: String,
      boardID: UInt64, chipID: UInt64
    ) async throws {
      self.archive = archive
      self.source = source
      self.deviceClass = deviceClass
      let members = Dictionary(uniqueKeysWithValues: archive.members.map { ($0.name, $0) })
      func read(_ name: String) async throws -> Data {
        guard let member = members[name] else { throw NativeStubFileError.invalidPlan }
        return try await archive.read(member, maximumBytes: 32 << 20)
      }
      func plist(_ data: Data) throws -> [String: Any] {
        guard
          let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { throw NativeStubFileError.invalidPlan }
        return object
      }
      var document = try plist(await read("BuildManifest.plist"))
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
            && info["RestoreBehavior"] as? String == "Erase"
            && info["Variant"] as? String == "macOS Customer"
        }),
        let info = identity["Info"] as? [String: Any],
        let buildNumber = info["BuildNumber"] as? String,
        let board = identity["ApBoardID"] as? String, let chip = identity["ApChipID"] as? String,
        let components = identity["Manifest"] as? [String: [String: Any]],
        NativeHandoffEvidence.safeRelative(restore),
        let visible = version["ProductUserVisibleVersion"] as? String,
        version["ProductVersion"] as? String == source.version,
        let recovery = components["BaseSystem"]?["Info"] as? [String: Any],
        let recoveryName = recovery["Path"] as? String, let recoveryMember = members[recoveryName],
        recoveryMember.sizeBytes > 0, recoveryMember.sizeBytes <= 8 << 30
      else { throw NativeStubFileError.invalidPlan }
      self.restorePath = restore
      self.recoveryMember = recoveryMember
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
          "variant": "macOS Customer", "device_class": deviceClass,
          "board_id": board, "chip_id": chip,
        ],
      ]
      guard JSONSerialization.isValidJSONObject(summary) else {
        throw NativeStubFileError.invalidPlan
      }
      stubInfo = try JSONSerialization.data(
        withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])

      var copies = [Copy]()
      func add(_ member: String, _ role: String, _ path: String, data: String? = nil) throws {
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
        let files = archive.members.filter { $0.name.hasPrefix(prefix + "/") && !$0.isDirectory }
        guard !files.isEmpty else { throw NativeStubFileError.invalidPlan }
        for file in files.sorted(by: { $0.name < $1.name }) {
          try add(
            file.name, "Preboot", destination + "/" + String(file.name.dropFirst(prefix.count + 1)))
        }
      }
      try tree("BootabilityBundle/Restore/Bootability", at: restore + "/Bootability")
      try add(
        "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", "Preboot",
        restore + "/Bootability/Bootability.trustcache")
      try tree("Firmware/Manifests/restore/macOS Customer", at: restore)
      let excluded: Set<String> = [
        "BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "RestoreRamDisk",
        "RestoreTrustCache",
      ]
      for key in components.keys.sorted() where !excluded.contains(key) && !key.hasPrefix("Cryptex")
      {
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
          UInt64(recoveryMember.sizeBytes), { $0 + UInt64(members[$1.member]!.sizeBytes) }) <= 16
          << 30
      else { throw NativeStubFileError.invalidPlan }
      // Admit every selected local record before disk preparation. Links are
      // confined to the selected framework tree and are never extraction paths.
      var links = [String: String]()
      let selected = Set(copies.map(\.member) + [recoveryMember.name])
      for name in selected.sorted() {
        let member = members[name]!
        if member.isSymbolicLink {
          guard name.hasPrefix("BootabilityBundle/Restore/Bootability/"),
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
  }
#endif
