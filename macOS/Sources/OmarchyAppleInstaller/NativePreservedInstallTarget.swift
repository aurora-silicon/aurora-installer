#if os(macOS)
  import Foundation

  enum NativePreservedInstallError: Error, Equatable, Sendable {
    case unavailable
    case changedLayout
    case imageTooLarge
  }

  /// Read-only admission of an existing Aurora installation for a future
  /// Stage-1-preserving rewrite. This value alone never authorizes a disk write.
  struct NativePreservedInstallTarget: Equatable, Sendable {
    let disk: String
    let title: String
    let group: String
    let stub: RemovalPartition
    let esp: RemovalPartition
    let boot: RemovalPartition
    let root: RemovalPartition
    let identityDigest: String

    static func admit(
      _ collected: NativeCollectedDisk, sourceIdentifier: String, title: String,
      bootImageBytes: UInt64, rootImageBytes: UInt64
    ) throws -> Self {
      let snapshot = collected.snapshot
      _ = try NativeDiskInventory.extents(snapshot)
      guard AuroraDistribution.allCases.map(\.title).contains(title),
        bootImageBytes > 0, rootImageBytes > 0,
        bootImageBytes % 4096 == 0, rootImageBytes % 4096 == 0
      else { throw NativePreservedInstallError.unavailable }
      let ordered = snapshot.partitions.sorted { $0.offset < $1.offset }
      guard let index = ordered.firstIndex(where: { $0.identifier == sourceIdentifier }),
        index + 3 < ordered.count,
        ordered[index].type == "Apple_APFS",
        ordered[index].uuid != snapshot.macOSStoreUUID,
        ordered[index + 1].type == "EFI",
        ordered[index + 1].name == NativeKnownInstallations.espLabel(for: title),
        ordered[index + 2].type == "Linux Filesystem",
        ordered[index + 3].type == "Linux Filesystem"
      else { throw NativePreservedInstallError.unavailable }
      let parts = Array(ordered[index...index + 3])
      guard zip(parts, parts.dropFirst()).allSatisfy({ pair in
        pair.0.end == pair.1.offset
      }), Set(parts.map(\.uuid)).count == 4
      else { throw NativePreservedInstallError.changedLayout }
      guard bootImageBytes <= parts[2].size, rootImageBytes <= parts[3].size else {
        throw NativePreservedInstallError.imageTooLarge
      }
      let matchingFacts = collected.containers.filter { $0.storeUUID == parts[0].uuid }
      let matchingContainers = snapshot.containers.filter { $0.storeUUID == parts[0].uuid }
      guard matchingFacts.count == 1, matchingContainers.count == 1,
        matchingFacts[0].capacity == parts[0].size,
        matchingFacts[0].free <= matchingFacts[0].capacity,
        matchingFacts[0].systems.count == 1,
        let system = matchingFacts[0].systems.first,
        system.stub, system.label == title,
        UUID(uuidString: system.group) != nil,
        matchingContainers[0].volumes.filter({
          $0.roles == ["System"] && $0.group == system.group && $0.name == title
        }).count == 1,
        matchingContainers[0].volumes.filter({
          $0.roles == ["Data"] && $0.group == system.group
        }).count == 1,
        matchingContainers[0].volumes.filter({ $0.roles == ["Preboot"] }).count == 1,
        matchingContainers[0].volumes.filter({ $0.roles == ["Recovery"] }).count == 1
      else { throw NativePreservedInstallError.changedLayout }
      var fields = ["aurora.preserve-stage1-target", "1", snapshot.disk, title, system.group]
      for part in parts {
        fields += [
          part.identifier, part.type, part.name, part.uuid,
          String(part.offset), String(part.size),
        ]
      }
      return Self(
        disk: snapshot.disk, title: title, group: system.group,
        stub: parts[0], esp: parts[1], boot: parts[2], root: parts[3],
        identityDigest: InstallerDigest.lengthPrefixedSHA256(fields).rawValue)
    }
  }
#endif
