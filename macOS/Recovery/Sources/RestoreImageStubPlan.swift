import Foundation

/// Which members of a restore image go into a new macOS stub and where, for
/// recoveryOS: the pure part of the main installer's NativeStubFilePlan for
/// a full restore image (`UniversalMac_*_Restore.ipsw`), on
/// RestoreImageDirectory instead of IPSWArchive. Same selection, same paths,
/// same limits: the build identity for this Mac's board, chip and device
/// class, the Bootability tree and trust cache, the restore manifests, the
/// manifest components the stub boots, and the Recovery image (BaseSystem).
/// Links are kept only inside the Bootability tree and must resolve to a
/// selected file or directory.
///
/// A full OTA update archive (`AssetData/...`, the only form of macOS 14.8.3)
/// is refused here: its Recovery image is a whole-image patch stream that
/// recoveryOS has no decoder for yet.
public struct RestoreImageStubPlan {
  public struct Copy: Codable, Equatable {
    public let member: String
    public let role: String
    public let path: String
    public let installerDataName: String?
  }

  /// The restore image the installation was sealed to.
  public struct Pin: Equatable {
    public let sourceBytes: Int
    public let manifestSHA256: String
    public let build: String
    public init(sourceBytes: Int, manifestSHA256: String, build: String) {
      self.sourceBytes = sourceBytes
      self.manifestSHA256 = manifestSHA256
      self.build = build
    }
  }

  public enum Failure: Error, Equatable {
    /// The image lacks a file the stub needs, holds one it may not, or its
    /// property lists don't describe this Mac's build.
    case invalidPlan
    /// An update archive, not a restore image.
    case updateArchive
    /// Not the image, manifest or build the installation was sealed to.
    case pinMismatch
  }

  public static let variant = "macOS Customer"
  public static let restoreBehavior = "Erase"

  public let manifest: Data
  public let systemVersion: Data
  public let stubInfo: Data
  public let restorePath: String
  public let recoveryMember: RestoreImageDirectory.Entry
  public let copies: [Copy]
  public let linkTargets: [String: String]
  let entries: [String: RestoreImageDirectory.Entry]

  public init(
    directory: RestoreImageDirectory, read: RestoreImageDirectory.Read, productVersion: String,
    deviceClass: String, boardID: UInt64, chipID: UInt64, pin: Pin,
    sha256: (Data) -> String
  ) throws {
    let members = Dictionary(uniqueKeysWithValues: directory.entries.map { ($0.name, $0) })
    entries = members
    guard members["AssetData/boot/BuildManifest.plist"] == nil else {
      throw Failure.updateArchive
    }
    guard members["BuildManifest.plist"] != nil else { throw Failure.invalidPlan }
    guard directory.archiveSize == pin.sourceBytes else { throw Failure.pinMismatch }
    func contents(_ name: String) throws -> Data {
      guard let entry = members[name] else { throw Failure.invalidPlan }
      return try directory.contents(entry, read: read)
    }
    func plist(_ data: Data) throws -> [String: Any] {
      guard
        let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else { throw Failure.invalidPlan }
      return object
    }
    let manifestBytes = try contents("BuildManifest.plist")
    var document = try plist(manifestBytes)
    let caches = try plist(contents("usr/standalone/bootcaches.plist"))
    var version = try plist(contents("SystemVersion.plist"))
    guard let bless = caches["bless2"] as? [String: Any],
      bless["RestoreBundlePath"] == nil || bless["RestoreBundlePath"] is String
    else { throw Failure.invalidPlan }
    let rawRestore = bless["RestoreBundlePath"] as? String ?? "./Restore"
    let restore = rawRestore.hasPrefix("./") ? String(rawRestore.dropFirst(2)) : rawRestore
    func hex(_ value: String) -> UInt64? {
      guard value.utf8.starts(with: "0x".utf8) else { return nil }
      return UInt64(String(decoding: value.utf8.dropFirst(2), as: UTF8.self), radix: 16)
    }
    guard let identities = document["BuildIdentities"] as? [[String: Any]],
      let identity = identities.first(where: {
        guard let board = $0["ApBoardID"] as? String, let chip = $0["ApChipID"] as? String,
          let info = $0["Info"] as? [String: Any]
        else { return false }
        return hex(board) == boardID && hex(chip) == chipID
          && info["DeviceClass"] as? String == deviceClass
          && info["RestoreBehavior"] as? String == Self.restoreBehavior
          && info["Variant"] as? String == Self.variant
      }),
      let info = identity["Info"] as? [String: Any],
      let buildNumber = info["BuildNumber"] as? String,
      let board = identity["ApBoardID"] as? String, let chip = identity["ApChipID"] as? String,
      let components = identity["Manifest"] as? [String: [String: Any]],
      RestoreImageDirectory.safeRelative(Array(restore.utf8)),
      let visible = version["ProductUserVisibleVersion"] as? String,
      version["ProductVersion"] as? String == productVersion,
      let recovery = components["BaseSystem"]?["Info"] as? [String: Any],
      let recoveryName = recovery["Path"] as? String,
      let recoveryMember = members[recoveryName],
      !recoveryMember.isDirectory, recoveryMember.size > 0, recoveryMember.size <= 8 << 30
    else { throw Failure.invalidPlan }
    guard sha256(manifestBytes) == pin.manifestSHA256, buildNumber == pin.build else {
      throw Failure.pinMismatch
    }
    restorePath = restore
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
        "variant": Self.variant, "device_class": deviceClass,
        "board_id": board, "chip_id": chip,
      ],
    ]
    guard JSONSerialization.isValidJSONObject(summary) else { throw Failure.invalidPlan }
    stubInfo = try JSONSerialization.data(
      withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])

    var copies = [Copy]()
    func add(_ member: String, _ role: String, _ path: String, data: String? = nil) throws {
      guard RestoreImageDirectory.safeRelative(Array(member.utf8)),
        RestoreImageDirectory.safeRelative(Array(path.utf8)),
        let entry = members[member], !entry.isDirectory, entry.size > 0, entry.size <= 8 << 30
      else { throw Failure.invalidPlan }
      if let existing = copies.first(where: { $0.role == role && $0.path == path }) {
        guard existing.member == member else { throw Failure.invalidPlan }
        return
      }
      copies.append(Copy(member: member, role: role, path: path, installerDataName: data))
    }
    try add("usr/standalone/bootcaches.plist", "System", "usr/standalone/bootcaches.plist")
    try add("PlatformSupport.plist", "System", "System/Library/CoreServices/PlatformSupport.plist")
    for name in ["SystemVersion.plist", "RestoreVersion.plist", "usr/standalone/bootcaches.plist"] {
      try add(
        name, "Preboot", restore + "/" + name,
        data: name == "RestoreVersion.plist" ? name : nil)
    }
    func tree(_ prefix: String, at destination: String) throws {
      let stored = Array((prefix + "/").utf8)
      let files = directory.entries.filter {
        Array($0.name.utf8).starts(with: stored) && !$0.isDirectory
      }
      guard !files.isEmpty else { throw Failure.invalidPlan }
      for file in files.sorted(by: { $0.name < $1.name }) {
        let relative = String(
          decoding: Array(file.name.utf8).dropFirst(stored.count), as: UTF8.self)
        try add(prefix + "/" + relative, "Preboot", destination + "/" + relative)
      }
    }
    let bootability = "BootabilityBundle/Restore/Bootability"
    try tree(bootability, at: restore + "/Bootability")
    try add(
      "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", "Preboot",
      restore + "/Bootability/Bootability.trustcache")
    try tree("Firmware/Manifests/restore/" + Self.variant, at: restore)
    for key in components.keys.sorted() where Self.restores(component: key) {
      guard let value = components[key]?["Info"] as? [String: Any],
        let path = value["Path"] as? String
      else { throw Failure.invalidPlan }
      // The last component by bytes, as URL.lastPathComponent gives it: a
      // Character split keeps "/\u{301}" whole.
      let leaf = Array(path.utf8).split(
        separator: UInt8(ascii: "/"), omittingEmptySubsequences: false
      )
      .last.map { String(decoding: $0, as: UTF8.self) }
      try add(
        path, "Preboot", restore + "/" + path,
        data: path.utf8.starts(with: "kernelcache.".utf8) ? leaf : nil)
    }
    guard copies.count <= 10000,
      copies.reduce(UInt64(recoveryMember.size), { $0 + UInt64(members[$1.member]!.size) })
        <= 16 << 30
    else { throw Failure.invalidPlan }

    // Admit every selected local record before any disk work. Links are
    // confined to the selected Bootability tree and are never extraction
    // paths.
    var links = [String: String]()
    let selected = Set(copies.map(\.member) + [recoveryMember.name])
    func under(_ name: String, _ parent: String) -> Bool {
      Array(name.utf8).starts(with: Array((parent + "/").utf8))
    }
    for name in selected.sorted() {
      let member = members[name]!
      if member.isSymbolicLink {
        guard under(name, bootability), !selected.contains(where: { under($0, name) }) else {
          throw Failure.invalidPlan
        }
        links[name] = try directory.linkTarget(member, read: read)
      } else {
        _ = try directory.dataOffset(member, read: read)
      }
    }
    for name in links.keys {
      // Resolve a link the way the file system will, a prefix at a time,
      // relative to the link's own directory as the stub stage writes it.
      var target = name
      var visited = Set<String>()
      while true {
        let parts = target.split(separator: "/").map(String.init)
        var replaced = false
        for count in 1...parts.count {
          let prefix = parts.prefix(count).joined(separator: "/")
          if let link = links[prefix] {
            guard visited.insert(prefix).inserted, visited.count <= 40 else {
              throw Failure.invalidPlan
            }
            target =
              (Array(parts.prefix(count - 1)) + link.split(separator: "/").map(String.init)
              + Array(parts.dropFirst(count))).joined(separator: "/")
            replaced = true
            break
          }
        }
        if !replaced { break }
      }
      guard selected.contains(target) || selected.contains(where: { under($0, target) }) else {
        throw Failure.invalidPlan
      }
    }
    self.copies = copies
    linkTargets = links
  }

  /// Whether the stub's restore directory gets a manifest component; the
  /// rest are images the stub doesn't boot.
  public static func restores(component key: String) -> Bool {
    ![
      "BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "RestoreRamDisk",
      "RestoreTrustCache",
    ].contains(key) && !key.hasPrefix("Cryptex")
  }

  /// A file copied straight into the restore directory. Its member, like the
  /// Recovery image, is decoded first when it is an Apple Encrypted Archive.
  public func isTopLevelRestore(_ copy: Copy) -> Bool {
    let restore = Array((restorePath + "/").utf8)
    let path = Array(copy.path.utf8)
    return copy.role == "Preboot" && path.starts(with: restore)
      && !path.dropFirst(restore.count).contains(UInt8(ascii: "/"))
  }

  /// Every member whose body the stub reads from the image, the Recovery
  /// image last; links were read while admitting the plan.
  public var readMembers: [RestoreImageDirectory.Entry] {
    var seen = Set<String>()
    return
      (copies.filter { linkTargets[$0.member] == nil }.compactMap { entries[$0.member] }
      + [recoveryMember]).filter { seen.insert($0.name).inserted }
  }

  /// What the stub keeps: every copied member's size plus the Recovery image.
  public var stubBytes: UInt64 {
    copies.reduce(UInt64(recoveryMember.size)) { $0 + UInt64(entries[$1.member]?.size ?? 0) }
  }
}
