#if os(macOS)
  import Foundation

  struct NativeSystemVolumeFacts: Decodable, Equatable, Sendable {
    let group: String
    let label: String
    let stub: Bool
    let version: String?
  }

  struct NativeContainerFacts: Decodable, Sendable {
    let storeUUID: String
    let capacity: UInt64
    let free: UInt64
    let preferredMinimum: UInt64
    let systems: [NativeSystemVolumeFacts]
  }

  /// Pure geometry and candidate construction; live collection has no authority
  /// to resize, erase, bless or otherwise change the partition map.
  struct NativeDiskInventory {
    private struct Extent {
      let source: String
      let offset: UInt64
      let length: UInt64
      let partition: RemovalPartition?
    }

    static func transcript(
      device: String, snapshot: RemovalSnapshot,
      containers: [NativeContainerFacts], metadata: NativeInstallationMetadata,
      stubBytes: UInt64
    ) throws -> Data {
      let target = try metadata.target()
      let bounds = try metadata.bounds(stubBytes: stubBytes)
      let rows = try extents(snapshot)
      guard Set(containers.map(\.storeUUID)).count == containers.count else {
        throw NativeInspectionError.invalidLayout
      }
      var candidates = [EngineInstallCandidate]()
      func candidate(
        _ kind: String, _ source: String, _ offset: UInt64, _ length: UInt64,
        minimum: UInt64, container: UInt64 = 0, identity: String? = nil
      ) -> EngineInstallCandidate {
        EngineInstallCandidate(
          kind: kind, sourceIdentifier: source, offsetBytes: offset,
          lengthBytes: length, minimumInstallBytes: minimum, minimumContainerBytes: container,
          identityDigest: identity, recommendedInstallBytes: bounds.recommended,
          recommendedContainerBytes: container)
      }
      for row in rows {
        try Task.checkCancellation()
        let length = NativeInspectionMath.alignDown(row.length)
        guard let part = row.partition else {
          if length >= bounds.floor {
            candidates.append(
              candidate(
                "free", row.source, row.offset, length,
                minimum: length >= bounds.recommended ? bounds.recommended : bounds.floor))
          }
          continue
        }
        guard part.type == "Apple_APFS",
          let facts = containers.first(where: { $0.storeUUID == part.uuid })
        else { continue }
        guard facts.capacity == part.size, facts.free <= facts.capacity
        else { throw NativeInspectionError.invalidLayout }
        guard resizeEligible(diskSize: snapshot.diskSize, free: facts.free, systems: facts.systems)
        else { continue }
        guard facts.preferredMinimum > 0, facts.preferredMinimum <= facts.capacity else {
          throw NativeInspectionError.invalidLayout
        }
        // The shared installation contract keeps the same explicit reserve
        // for every resize candidate, including tight and non-OS containers.
        let reserve = try NativeInspectionMath.alignUp(
          NativeInspectionMath.add(facts.capacity - facts.free, 38_000_000_000))
        let minimum = max(facts.preferredMinimum, reserve)
        candidates.append(
          candidate(
            "resize", part.identifier, part.offset, part.size,
            minimum: bounds.floor, container: minimum))
      }

      for (index, row) in rows.enumerated() {
        guard let part = row.partition, part.type.hasPrefix("Apple_APFS"),
          !["Apple_APFS_ISC", "Apple_APFS_Recovery"].contains(part.type),
          let facts = containers.first(where: { $0.storeUUID == part.uuid })
        else { continue }
        let stubs = facts.systems.filter { $0.stub && $0.label == target.name }
        guard stubs.count == 1, let stub = stubs.first, index + 3 < rows.count else { continue }
        let members = rows[index...index + 3].compactMap(\.partition)
        guard members.count == 4, members[1].name == "EFI - OMARC",
          members[2].type == "Linux Filesystem", members[3].type == "Linux Filesystem"
        else { continue }
        let start =
          index > 0 && rows[index - 1].partition == nil ? rows[index - 1].offset : part.offset
        var end = try NativeInspectionMath.add(members[3].offset, members[3].size)
        if index + 4 < rows.count, rows[index + 4].partition == nil {
          let following = rows[index + 4]
          end = try NativeInspectionMath.add(following.offset, following.length)
        }
        let length = NativeInspectionMath.alignDown(end - start)
        guard length >= bounds.floor else { continue }
        var fields = ["omarchy.apple.replace-identity", "1", target.name, stub.group]
        for member in members {
          fields += [
            member.identifier, member.type, member.uuid, String(member.offset), String(member.size),
          ]
        }
        candidates.append(
          candidate(
            "replace", part.identifier, start, length,
            minimum: length >= bounds.recommended ? bounds.recommended : bounds.floor,
            identity: InstallerDigest.lengthPrefixedSHA256(fields).rawValue))
      }
      candidates.sort {
        $0.offsetBytes == $1.offsetBytes ? $0.kind < $1.kind : $0.offsetBytes < $1.offsetBytes
      }
      let unsigned = EngineInventoryMessage(
        layoutDigest: "", systemStoreIdentifier: snapshot.disk,
        candidates: candidates)
      let inventory = EngineInventoryMessage(
        layoutDigest: unsigned.computedLayoutDigest,
        systemStoreIdentifier: snapshot.disk, candidates: candidates)
      return try records(device: device, inventory: inventory)
    }

    static func unsupported(device: String) throws -> Data {
      try records(device: device, inventory: nil)
    }

    static func resizeEligible(diskSize: UInt64, free: UInt64, systems: [NativeSystemVolumeFacts])
      -> Bool
    {
      // The runtime retains exhausted real macOS containers for exact
      // shortfalls, while avoiding new probes of unrelated stubs or data.
      let hasOS = systems.contains { $0.version?.isEmpty == false }
      if systems.contains(where: { !$0.stub && $0.version?.isEmpty == false }) { return true }
      let threshold: UInt64 =
        hasOS && diskSize >= 150 * 1024 * 1024 * 1024
        ? 38_000_000_000 : 1_000_000_000
      return free > threshold + 500_000_000
    }

    private static func records(device: String, inventory: EngineInventoryMessage?) throws -> Data {
      var payloads: [(String, [String: Any])] = [
        (
          "inspection",
          ["device_identifier": device, "support": inventory == nil ? "unsupported" : "supported"]
        )
      ]
      if let inventory {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard
          let payload = try JSONSerialization.jsonObject(with: encoder.encode(inventory))
            as? [String: Any]
        else { throw NativeInspectionError.invalidLayout }
        payloads.append(("inventory", payload))
      }
      var bytes = Data()
      for (index, record) in payloads.enumerated() {
        bytes.append(
          try JSONSerialization.data(
            withJSONObject: [
              "schema_version": 1, "sequence": index + 1, "type": record.0, "payload": record.1,
            ], options: [.sortedKeys]))
        bytes.append(10)
      }
      _ = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      return bytes
    }

    private static func extents(_ snapshot: RemovalSnapshot) throws -> [Extent] {
      guard snapshot.diskSize > 40_960, !snapshot.partitions.isEmpty,
        NativeInspectionCommands.identifier(snapshot.disk),
        Set(snapshot.partitions.map(\.uuid)).count == snapshot.partitions.count,
        Set(snapshot.partitions.map(\.identifier)).count == snapshot.partitions.count
      else {
        throw NativeInspectionError.invalidLayout
      }
      let end = (snapshot.diskSize - 17_408) / 4096 * 4096
      var offset: UInt64 = 20_480
      var preceding = snapshot.disk
      var rows = [Extent]()
      for part in snapshot.partitions.sorted(by: { $0.offset < $1.offset }) {
        guard part.identifier.hasPrefix(snapshot.disk + "s"),
          NativeInspectionCommands.identifier(part.identifier),
          UUID(uuidString: part.uuid) != nil, part.size > 0, part.offset >= offset
        else {
          throw NativeInspectionError.invalidLayout
        }
        let partEnd = try NativeInspectionMath.add(part.offset, part.size)
        guard partEnd <= end else { throw NativeInspectionError.invalidLayout }
        if part.offset - offset > 16 * 1024 * 1024 {
          rows.append(
            Extent(source: preceding, offset: offset, length: part.offset - offset, partition: nil))
        }
        rows.append(
          Extent(source: part.identifier, offset: part.offset, length: part.size, partition: part))
        preceding = part.identifier
        offset = partEnd
      }
      if end - offset > 16 * 1024 * 1024 {
        rows.append(Extent(source: preceding, offset: offset, length: end - offset, partition: nil))
      }
      return rows
    }
  }
#endif
