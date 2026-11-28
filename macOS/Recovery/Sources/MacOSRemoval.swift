import Foundation

/// Removing macOS so Aurora can use the whole internal disk.
///
/// This file is the pure part: it decides from one reading of the disk what
/// goes and what stays, and checks a later reading against that decision. It
/// runs no commands, so the same rules are tested without a Mac.
///
/// What stays, always: Apple's iSC container (the first partition: iSCPreboot
/// with every LocalPolicy, xART, Hardware), Apple's System Recovery container
/// (the last partition), this installation's startup container with its
/// paired Recovery, its EFI partition, every other startup container and
/// every non-APFS partition. What goes: exactly one APFS container that holds
/// a full macOS, which is a System volume with a Data volume in the same
/// volume group and an Update volume. Startup containers made by the
/// installer have no Update volume. Anything else is refused, never guessed.

struct WholeDiskPartition: Equatable {
  let identifier: String
  let uuid: String
  let type: String
  let offset: UInt64
  let size: UInt64
  var end: UInt64 { offset + size }
}

struct WholeDiskVolume: Equatable {
  let uuid: String
  let name: String
  let roles: [String]
  let group: String?
}

struct WholeDiskContainer: Equatable {
  let uuid: String
  let reference: String
  /// The partition UUID of the container's one physical store.
  let storeUUID: String
  let volumes: [WholeDiskVolume]

  /// The roles a macOS container holds, each at most once.
  static let macOSRoles: Set<String> = ["System", "Data", "Preboot", "Recovery", "VM", "Update"]

  /// Looks like a macOS container: a System volume and an Update volume.
  /// Startup containers made by the installer have no Update volume.
  var looksLikeMacOS: Bool {
    volumes.contains { $0.roles.contains("System") }
      && volumes.contains { $0.roles.contains("Update") }
  }

  /// Why this container is more than exactly one macOS, or nil when it is
  /// one: one System and one Data volume in the same volume group, and
  /// nothing but macOS's own volumes beside them. Deleting the container
  /// deletes every volume in it, so a second macOS or a volume someone added
  /// must never ride along.
  var macOSProblem: String? {
    let systems = volumes.filter { $0.roles.contains("System") }
    guard systems.count == 1 else { return "it holds \(systems.count) System volumes" }
    let data = volumes.filter { $0.roles.contains("Data") }
    guard data.count == 1, let group = systems[0].group, data[0].group == group else {
      return "its System and Data volumes aren’t one volume group"
    }
    for v in volumes {
      guard v.roles.count == 1, Self.macOSRoles.contains(v.roles[0]) else {
        let roles = v.roles.isEmpty ? "no role" : v.roles.joined(separator: ", ")
        return "volume “\(v.name)” (\(roles)) isn’t part of macOS"
      }
    }
    for role in Self.macOSRoles.sorted()
    where volumes.filter({ $0.roles.contains(role) }).count > 1 {
      return "it holds more than one \(role) volume"
    }
    return nil
  }

  /// Exactly one full macOS and nothing else.
  var holdsMacOS: Bool { looksLikeMacOS && macOSProblem == nil }

  var systemName: String {
    volumes.first { $0.roles.contains("System") }?.name ?? "(no System volume)"
  }
}

struct WholeDiskLayout: Equatable {
  /// BSD name of the internal whole disk, e.g. `disk0`.
  let disk: String
  let diskSize: UInt64
  let partitions: [WholeDiskPartition]
  let containers: [WholeDiskContainer]
}

/// This installation, as `install-config.json` names it.
struct WholeDiskInstallation: Equatable {
  let systemUUID: String
  let groupUUID: String
  let espUUID: String
}

struct MacOSRemovalPlan: Equatable {
  let disk: String
  /// The container to delete and its partition.
  let macOS: WholeDiskContainer
  let partition: WholeDiskPartition
  /// Every partition that must be unchanged afterwards, in disk order.
  let kept: [WholeDiskPartition]
  /// The startup container of this installation.
  let installationStoreUUID: String
  let espUUID: String
  /// Other startup containers kept (for example a firmware slot).
  let otherStartupContainers: [WholeDiskContainer]
}

struct MacOSRemovalRefusal: Error, LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// Why this installation can't be the Mac's only owner yet. Removal stops
/// here and offers the account step instead of deleting anything.
struct MacOSRemovalNeedsOwner: Error, LocalizedError, Equatable {
  /// True when no recovery account was started: Create Recovery Account… fixes it.
  /// False when one waits for Startup Disk authorization.
  let canCreate: Bool
  let message: String
  var errorDescription: String? { message }
}

enum MacOSRemoval {
  /// Typed in full to confirm. Lower case, so caps lock can't make it differ.
  static let phrase = "remove macos and all its data"

  /// The typed confirmation, ignoring spaces around it and nothing else.
  static func confirms(_ typed: String) -> Bool {
    typed.trimmingCharacters(in: .whitespaces) == phrase
  }

  /// The owner step before removal, from the recovery account's recorded
  /// phase (nil: never started). Only a finalized account, which Recovery has
  /// also read back as an APFS volume owner, may stand alone after macOS.
  static func ownerGate(phase: String?) -> MacOSRemovalNeedsOwner? {
    switch phase {
    case "finalized": return nil
    case nil:
      return MacOSRemovalNeedsOwner(
        canCreate: true,
        message:
          "This installation has no recovery account of its own yet. Create it first (Aurora Installer → Utilities → Create Recovery Account…), authorize it in Startup Disk, and come back. macOS was not removed, because without that account nobody could change this Mac’s startup security afterwards."
      )
    case "allocating", "creating":
      return MacOSRemovalNeedsOwner(
        canCreate: false,
        message:
          "This installation’s recovery account wasn’t finished. Quit and open Aurora Installer again in this Recovery to finish it, authorize it in Startup Disk, then come back. macOS was not removed."
      )
    default:
      return MacOSRemovalNeedsOwner(
        canCreate: false,
        message:
          "This installation’s recovery account isn’t authorized yet. Restart, choose this installation in Startup Disk and authorize the account there, then open Recovery again. macOS was not removed."
      )
    }
  }

  /// What the owner is told before typing the phrase, in the CLI and the app.
  static func consequences(owner: String) -> String {
    """
    This deletes macOS, its apps and every file in it, for good. After this:
      - macOS and macOS apps are gone. Aurora is the only system on this Mac.
      - Apple's macOS and firmware updates no longer arrive by themselves. The Mac's
        system firmware stays at its current version; Aurora's startup firmware is
        updated by Aurora Installer's startup-firmware path.
      - Startup security changes need \(owner)'s password, in this Recovery.
      - To get macOS back you erase the Mac in DFU mode (a second Mac with Finder or
        Apple Configurator, or a Linux computer with idevicerestore) and restore it.
    """
  }

  static func plan(_ layout: WholeDiskLayout, installation: WholeDiskInstallation) throws
    -> MacOSRemovalPlan
  {
    func refuse(_ message: String) -> MacOSRemovalRefusal { MacOSRemovalRefusal(message: message) }
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    guard parts.count >= 4, let first = parts.first, let last = parts.last else {
      throw refuse(
        "This disk doesn’t have the layout of an Apple silicon Mac with Aurora installed.")
    }
    for (a, b) in zip(parts, parts.dropFirst()) where a.end > b.offset {
      throw refuse("Partitions \(a.identifier) and \(b.identifier) overlap. Nothing was changed.")
    }
    guard first.type == "Apple_APFS_ISC" else {
      throw refuse("The first partition isn’t Apple’s system container (iSC). Nothing was changed.")
    }
    guard last.type == "Apple_APFS_Recovery" else {
      throw refuse("The last partition isn’t Apple’s System Recovery. Nothing was changed.")
    }
    guard
      parts.filter({ $0.type == "Apple_APFS_ISC" }).count == 1,
      parts.filter({ $0.type == "Apple_APFS_Recovery" }).count == 1
    else {
      throw refuse(
        "This disk has more than one Apple system or Recovery container. Nothing was changed.")
    }
    func container(of part: WholeDiskPartition) -> [WholeDiskContainer] {
      layout.containers.filter { $0.storeUUID == part.uuid }
    }
    // This installation: its System volume, in its own group.
    let own = layout.containers.filter { c in
      c.volumes.contains {
        $0.uuid == installation.systemUUID && $0.group == installation.groupUUID
          && $0.roles.contains("System")
      }
    }
    guard own.count == 1, let ownStore = parts.first(where: { $0.uuid == own[0].storeUUID })
    else {
      throw refuse("This installation’s startup container couldn’t be found on this disk.")
    }
    guard parts.contains(where: { $0.uuid == installation.espUUID && $0.type == "EFI" }) else {
      throw refuse("This installation’s EFI partition couldn’t be found on this disk.")
    }
    var macOS = [(WholeDiskContainer, WholeDiskPartition)]()
    var otherStartup = [WholeDiskContainer]()
    for part in parts.dropFirst().dropLast() where part.type == "Apple_APFS" {
      let found = container(of: part)
      guard found.count == 1 else {
        throw refuse(
          "\(part.identifier) couldn’t be listed as one APFS container, so its contents can’t be reviewed. Nothing was changed."
        )
      }
      let c = found[0]
      if c.uuid == own[0].uuid { continue }
      if c.looksLikeMacOS {
        if let problem = c.macOSProblem {
          let names = c.volumes.map { "“\($0.name)”" }.joined(separator: ", ")
          throw refuse(
            "\(part.identifier) holds macOS together with something else: \(problem). Deleting it would delete every volume in it (\(names)), so nothing was changed. Move or delete the extra volumes in macOS first."
          )
        }
        macOS.append((c, part))
      } else if c.volumes.contains(where: { $0.roles.contains("System") }) {
        otherStartup.append(c)
      }
    }
    guard !macOS.isEmpty else {
      throw refuse("There is no macOS on this disk to remove.")
    }
    guard macOS.count == 1 else {
      throw refuse(
        "This disk has \(macOS.count) macOS installations. Remove the extra ones with Aurora Installer’s Erase first, so it’s clear which one goes."
      )
    }
    let (target, partition) = macOS[0]
    guard partition.uuid != ownStore.uuid, partition.uuid != installation.espUUID else {
      throw refuse("The macOS container is this installation’s own. Nothing was changed.")
    }
    return MacOSRemovalPlan(
      disk: layout.disk, macOS: target, partition: partition,
      kept: parts.filter { $0.uuid != partition.uuid }, installationStoreUUID: ownStore.uuid,
      espUUID: installation.espUUID, otherStartupContainers: otherStartup)
  }

  /// A second reading of the disk must equal the planned one before deletion.
  static func requireUnchanged(
    _ reviewed: MacOSRemovalPlan, now layout: WholeDiskLayout,
    installation: WholeDiskInstallation
  ) throws {
    guard try plan(layout, installation: installation) == reviewed else {
      throw MacOSRemovalRefusal(
        message: "The disk changed since it was reviewed. Nothing was changed; review it again.")
    }
  }

  /// After deletion: the macOS partition is gone and every kept partition is
  /// exactly where and what it was. Nothing new appeared.
  static func verifyRemoved(_ plan: MacOSRemovalPlan, after layout: WholeDiskLayout) throws {
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    guard layout.disk == plan.disk else {
      throw MacOSRemovalRefusal(message: "The internal disk changed identity during removal.")
    }
    guard !parts.contains(where: { $0.uuid == plan.partition.uuid }),
      !layout.containers.contains(where: { $0.uuid == plan.macOS.uuid })
    else {
      throw MacOSRemovalRefusal(message: "The macOS container is still on the disk.")
    }
    guard
      parts.map({ [$0.uuid, $0.type, String($0.offset), String($0.size)] })
        == plan.kept.map({ [$0.uuid, $0.type, String($0.offset), String($0.size)] })
    else {
      throw MacOSRemovalRefusal(
        message:
          "The partitions that had to stay changed during removal. Don’t restart; save the Installer Log."
      )
    }
  }

  /// The free extent the deletion leaves, joined with free space either side.
  static func freedExtent(_ plan: MacOSRemovalPlan) -> (offset: UInt64, size: UInt64) {
    let before = plan.kept.filter { $0.end <= plan.partition.offset }.map(\.end).max() ?? 0
    let after =
      plan.kept.filter { $0.offset >= plan.partition.end }.map(\.offset).min()
      ?? plan.partition.end
    return (before, after - before)
  }

  /// What `aura remove-macos --dry-run` prints, and what the confirmation shows.
  static func describe(_ plan: MacOSRemovalPlan) -> String {
    func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
    var lines = [String]()
    lines.append("WILL BE DELETED, with all its data:")
    lines.append(
      "  \(plan.partition.identifier)  \(gb(plan.partition.size))  APFS container \(plan.macOS.uuid) (partition \(plan.partition.uuid))"
    )
    for v in plan.macOS.volumes.sorted(by: { $0.name < $1.name }) {
      lines.append("    volume “\(v.name)” (\(v.roles.joined(separator: ", ")))")
    }
    lines.append("KEPT, unchanged:")
    for p in plan.kept {
      var what = p.type
      if p.type == "Apple_APFS_ISC" {
        what = "Apple system container (iSC: LocalPolicy, xART, Hardware)"
      }
      if p.type == "Apple_APFS_Recovery" { what = "Apple System Recovery" }
      if p.uuid == plan.installationStoreUUID { what = "Aurora startup container and its Recovery" }
      if p.uuid == plan.espUUID { what = "Aurora EFI partition" }
      if plan.otherStartupContainers.contains(where: { $0.storeUUID == p.uuid }) {
        what = "another startup container"
      }
      lines.append("  \(p.identifier)  \(gb(p.size))  \(what)")
    }
    let free = freedExtent(plan)
    lines.append(
      "FREED: \(gb(free.size)) at byte offset \(free.offset). Aurora adds it to Linux on its next start (aurora-whole-disk claim)."
    )
    return lines.joined(separator: "\n")
  }

  /// Find My, from the firmware variables (`nvram -x -p`). Its token stays in
  /// NVRAM while Find My is on.
  static func findMyOn(nvram: [String: Any]) -> Bool {
    nvram.keys.contains {
      $0 == "fmm-mobileme-token-FMM" || $0.hasSuffix(":fmm-mobileme-token-FMM")
    }
  }

  /// The journal written just before `diskutil apfs deleteContainer`.
  static func journal(_ plan: MacOSRemovalPlan, removedAt: Date) -> [String: Any] {
    var journal = claimRecord(plan, removedAt: removedAt)
    journal["phase"] = "deleting"
    journal["disk"] = plan.disk
    journal["kept"] = plan.kept.map { part -> [String: Any] in
      ["uuid": part.uuid, "type": part.type, "offset": part.offset, "size": part.size]
    }
    return journal
  }

  /// Linux's record (`removed.json`) from the journal, once the deletion verified.
  static func linuxRecord(_ journal: [String: Any]) -> [String: Any] {
    var record = journal
    record["phase"] = "removed"
    record.removeValue(forKey: "kept")
    record.removeValue(forKey: "disk")
    return record
  }

  enum Resume: Equatable {
    /// The removal finished before.
    case complete
    /// The container is still there and nothing else changed: the deletion
    /// never started. The journal can go.
    case notStarted
    /// The container is gone and every kept partition is exactly as planned:
    /// write Linux's record and finish.
    case finish
  }

  /// What an existing journal means for this installation and this disk.
  /// Anything that doesn't match exactly refuses; nothing is guessed.
  static func resume(
    journal: [String: Any], installation: WholeDiskInstallation, now layout: WholeDiskLayout
  ) throws -> Resume {
    func refuse(_ why: String) -> MacOSRemovalRefusal {
      MacOSRemovalRefusal(
        message:
          "The record of an earlier macOS removal \(why). Nothing more was changed; save Window → Installer Log and ask for help."
      )
    }
    func uuid(_ key: String) -> String? {
      guard let raw = journal[key] as? String, let id = UUID(uuidString: raw) else { return nil }
      return id.uuidString
    }
    func number(_ value: Any?) -> UInt64? {
      if let n = value as? NSNumber, n.int64Value >= 0 { return n.uint64Value }
      return nil
    }
    guard journal["schema"] as? Int == 1, let phase = journal["phase"] as? String,
      ["deleting", "complete"].contains(phase)
    else { throw refuse("is unreadable or from another version") }
    guard uuid("espUUID") == installation.espUUID.uppercased() else {
      throw refuse("belongs to another installation")
    }
    let own = layout.containers.filter { c in
      c.volumes.contains {
        $0.uuid == installation.systemUUID && $0.group == installation.groupUUID
          && $0.roles.contains("System")
      }
    }
    guard own.count == 1, uuid("installationStoreUUID") == own[0].storeUUID else {
      throw refuse("names another startup container")
    }
    if phase == "complete" { return .complete }
    guard journal["disk"] as? String == layout.disk, let removed = uuid("removedPartitionUUID"),
      let container = uuid("removedContainerUUID"),
      let keptRaw = journal["kept"] as? [[String: Any]], !keptRaw.isEmpty
    else { throw refuse("is incomplete") }
    var kept = [[String]]()
    for k in keptRaw {
      guard let id = k["uuid"] as? String, let type = k["type"] as? String,
        let offset = number(k["offset"]), let size = number(k["size"])
      else { throw refuse("is incomplete") }
      kept.append([id.uppercased(), type, String(offset), String(size)])
    }
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    let others = parts.filter { $0.uuid != removed }.map {
      [$0.uuid, $0.type, String($0.offset), String($0.size)]
    }
    guard others == kept else { throw refuse("doesn’t match the disk") }
    let partitionThere = parts.contains { $0.uuid == removed }
    let containerThere = layout.containers.contains { $0.uuid == container }
    switch (partitionThere, containerThere) {
    case (true, true): return .notStarted
    case (false, false): return .finish
    default: throw refuse("doesn’t match the disk (the macOS container is half there)")
    }
  }

  /// The record left on the EFI partition for Linux, at
  /// `aurora/whole-disk/removed.json`. Linux claims only this extent.
  static func claimRecord(_ plan: MacOSRemovalPlan, removedAt: Date) -> [String: Any] {
    let free = freedExtent(plan)
    return [
      "schema": 1,
      "removedPartitionUUID": plan.partition.uuid,
      "removedContainerUUID": plan.macOS.uuid,
      "removedOffset": plan.partition.offset,
      "removedSize": plan.partition.size,
      "freeOffset": free.offset,
      "freeSize": free.size,
      "installationStoreUUID": plan.installationStoreUUID,
      "espUUID": plan.espUUID,
      "removedAt": ISO8601DateFormatter().string(from: removedAt),
    ]
  }
}

extension WholeDiskLayout {
  /// Builds the layout from diskutil's own listings: `list -plist internal
  /// physical`, `info -plist` of every partition of `disk`, `apfs list -plist`
  /// and `apfs listVolumeGroups -plist`. Any missing or contradictory field
  /// refuses; nothing is inferred.
  static func parse(
    disk: String, diskSize: UInt64, list: [String: Any], infos: [String: [String: Any]],
    apfs: [String: Any], groups: [String: Any]
  ) throws -> WholeDiskLayout {
    func bad(_ what: String) -> MacOSRemovalRefusal {
      MacOSRemovalRefusal(
        message: "diskutil’s listing of \(what) couldn’t be read. Nothing was changed.")
    }
    func uuid(_ value: Any?) -> String? {
      guard let raw = value as? String, let id = UUID(uuidString: raw) else { return nil }
      return id.uuidString
    }
    func number(_ value: Any?) -> UInt64? {
      if let n = value as? UInt64 { return n }
      if let n = value as? Int, n >= 0 { return UInt64(n) }
      if let n = value as? NSNumber, n.int64Value >= 0 { return n.uint64Value }
      return nil
    }
    guard let whole = list["AllDisksAndPartitions"] as? [[String: Any]],
      whole.filter({ $0["DeviceIdentifier"] as? String == disk }).count == 1,
      let entry = whole.first(where: { $0["DeviceIdentifier"] as? String == disk }),
      entry["Content"] as? String == "GUID_partition_scheme",
      let records = entry["Partitions"] as? [[String: Any]], !records.isEmpty, records.count <= 32
    else { throw bad(disk) }
    var parts = [WholeDiskPartition]()
    for record in records {
      guard let id = record["DeviceIdentifier"] as? String, let info = infos[id],
        info["ParentWholeDisk"] as? String == disk, info["DeviceIdentifier"] as? String == id,
        let partUUID = uuid(info["DiskUUID"]), let type = info["Content"] as? String,
        let offset = number(info["PartitionMapPartitionOffset"]), let size = number(info["Size"]),
        size > 0, !offset.addingReportingOverflow(size).overflow
      else { throw bad(deviceName(record)) }
      parts.append(
        WholeDiskPartition(identifier: id, uuid: partUUID, type: type, offset: offset, size: size))
    }
    guard Set(parts.map(\.uuid)).count == parts.count else { throw bad("partition UUIDs") }
    var groupOf = [String: String]()
    for c in groups["Containers"] as? [[String: Any]] ?? [] {
      for g in c["VolumeGroups"] as? [[String: Any]] ?? [] {
        guard let gid = uuid(g["APFSVolumeGroupUUID"]), let vols = g["Volumes"] as? [[String: Any]]
        else { throw bad("volume groups") }
        for v in vols {
          guard let vid = uuid(v["DiskUUID"]), groupOf.updateValue(gid, forKey: vid) == nil else {
            throw bad("volume groups")
          }
        }
      }
    }
    guard let raw = apfs["Containers"] as? [[String: Any]] else { throw bad("APFS containers") }
    var containers = [WholeDiskContainer]()
    for c in raw {
      guard let stores = c["PhysicalStores"] as? [[String: Any]] else {
        throw bad("APFS containers")
      }
      let onDisk = stores.compactMap { s in
        parts.first { $0.identifier == s["DeviceIdentifier"] as? String }
      }
      if onDisk.isEmpty { continue }  // another disk, e.g. an external drive
      guard onDisk.count == 1, stores.count == 1, let cid = uuid(c["APFSContainerUUID"]),
        let reference = c["ContainerReference"] as? String,
        let volumes = c["Volumes"] as? [[String: Any]]
      else { throw bad("APFS container \(c["ContainerReference"] as? String ?? "?")") }
      let parsed = try volumes.map { v -> WholeDiskVolume in
        guard let vid = uuid(v["APFSVolumeUUID"]), let roles = v["Roles"] as? [String] else {
          throw bad("APFS volumes in \(reference)")
        }
        return WholeDiskVolume(
          uuid: vid, name: v["Name"] as? String ?? "", roles: roles.sorted(), group: groupOf[vid])
      }
      containers.append(
        WholeDiskContainer(
          uuid: cid, reference: reference, storeUUID: onDisk[0].uuid, volumes: parsed))
    }
    return WholeDiskLayout(
      disk: disk, diskSize: diskSize, partitions: parts.sorted { $0.offset < $1.offset },
      containers: containers.sorted { $0.uuid < $1.uuid })
  }
  private static func deviceName(_ record: [String: Any]) -> String {
    record["DeviceIdentifier"] as? String ?? "a partition"
  }
}
