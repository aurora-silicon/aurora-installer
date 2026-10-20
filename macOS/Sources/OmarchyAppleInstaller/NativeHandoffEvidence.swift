#if os(macOS)
  import Foundation

  enum NativeHandoffValidationError: Error, Equatable {
    case invalidEvidence
    case changedLayout
    case changedContent
    case invalidTarget
    case invalidOwner
    case unsafePath
    case authorizationFailed
  }

  struct NativeHandoffEvidence: Sendable {
    struct Target: Decodable, Sendable {
      let planDigest: String
      let partitionIdentifier: String
      let offsetBytes: UInt64
      let sizeBytes: UInt64
      let uuid: String
    }
    struct Icon: Decodable, Sendable {
      let member: String
      let installedBytes: UInt64
      let verification: String
      let contentSha256: String
    }
    struct Partition: Decodable, Sendable {
      let name: String
      let partitionIdentifier: String
      let partitionUuid: String
      let partitionSizeBytes: UInt64
      let population: String
      let installedBytes: UInt64
      let verification: String
      let contentSha256: String
    }
    struct Installed: Decodable, Sendable {
      let planDigest: String
      let apfsVgid: String
      let systemVolume: String
      let efiPartition: String
      let startupVolumeIcon: Icon
      let populatedPartitions: [Partition]
    }
    let plan: ValidatedEnginePlan
    let target: Target
    let installed: Installed
    let qualifiedCommonFirmware: [String]

    init(snapshot: NativeRecoveryJournalSnapshot, metadata: Data) throws {
      plan = snapshot.plan
      guard let targetBytes = snapshot.evidence["apfs-target-prepared"],
        let installedBytes = snapshot.evidence["stub-and-esp-installed"],
        SHA256Digest(hashing: metadata).rawValue == plan.metadataDigest,
        let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
        let templates = document["os_list"] as? [[String: Any]] else {
        throw NativeHandoffValidationError.invalidEvidence
      }
      try Self.keys(targetBytes, ["plan_digest", "partition_identifier", "offset_bytes", "size_bytes", "uuid"])
      try Self.keys(installedBytes, ["plan_digest", "apfs_vgid", "system_volume", "efi_partition",
        "startup_volume_icon", "populated_partitions"])
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      target = try decoder.decode(Target.self, from: targetBytes)
      installed = try decoder.decode(Installed.self, from: installedBytes)
      let object = try JSONSerialization.jsonObject(with: installedBytes) as! [String: Any]
      try Self.keys(try JSONSerialization.data(withJSONObject: object["startup_volume_icon"]!),
        ["member", "installed_bytes", "verification", "content_sha256"])
      guard let parts = object["populated_partitions"] as? [[String: Any]], parts.count == 3 else {
        throw NativeHandoffValidationError.invalidEvidence
      }
      for part in parts {
        try Self.keys(try JSONSerialization.data(withJSONObject: part),
          ["name", "partition_identifier", "partition_uuid", "partition_size_bytes", "population",
            "installed_bytes", "verification", "content_sha256"])
      }
      let matching = templates.filter { $0["omarchy_target"] as? String == "apple-silicon-full-os" }
      guard matching.count == 1, let template = matching.first,
        let partitions = template["partitions"] as? [[String: Any]], partitions.count == 3,
        template["icon"] as? String == installed.startupVolumeIcon.member,
        Self.safeRelative(installed.startupVolumeIcon.member),
        installed.startupVolumeIcon.installedBytes > 0,
        installed.startupVolumeIcon.verification == "stub-file-sha256",
        Self.hash(installed.startupVolumeIcon.contentSha256),
        target.planDigest == plan.planDigest, installed.planDigest == plan.planDigest,
        target.offsetBytes == plan.offsetBytes, target.sizeBytes > 0,
        target.sizeBytes <= plan.lengthBytes, Self.uuid(target.uuid),
        Self.uuid(installed.apfsVgid), Self.uuid(installed.efiPartition),
        Self.partition(target.partitionIdentifier), Self.partition(installed.systemVolume)
      else { throw NativeHandoffValidationError.invalidEvidence }
      for (index, part) in installed.populatedPartitions.enumerated() {
        let expected = partitions[index]
        guard part.name == ["EFI", "Boot", "Root"][index], expected["name"] as? String == part.name,
          expected["type"] as? String == (index == 0 ? "EFI" : "Linux"),
          (expected["image"] as? String ?? expected["source"] as? String) == part.population,
          part.population == ["esp", "boot.img", "root.img"][index],
          part.verification == (index == 0 ? "copied-tree-sha256" : "raw-prefix-sha256")
            || (index == 2 && part.verification == "source-sha256-write-flushed-v1"),
          part.installedBytes > 0, part.installedBytes <= part.partitionSizeBytes,
          Self.uuid(part.partitionUuid), Self.partition(part.partitionIdentifier),
          Self.hash(part.contentSha256)
        else { throw NativeHandoffValidationError.invalidEvidence }
      }
      guard installed.populatedPartitions[0].partitionUuid.lowercased() == installed.efiPartition.lowercased(),
        Set(([target.uuid] + installed.populatedPartitions.map(\.partitionUuid)).map { $0.lowercased() }).count == 4
      else { throw NativeHandoffValidationError.invalidEvidence }
      if let policy = template["aurora_stage1"] {
        guard let values = policy as? [String: Any], Set(values.keys) == ["kind", "qualified_machines"],
          values["kind"] as? String == "common-raw-v1",
          let machines = values["qualified_machines"] as? [String: [String]] else {
          throw NativeHandoffValidationError.invalidEvidence
        }
        qualifiedCommonFirmware = machines[Self.board(plan.deviceIdentifier)] ?? []
      } else { qualifiedCommonFirmware = [] }
    }

    func requireLayout(_ snapshot: RemovalSnapshot) throws -> [RemovalPartition] {
      _ = try NativeDiskInventory.extents(snapshot)
      guard snapshot.disk == plan.storeIdentifier,
        let stub = snapshot.partitions.first(where: { $0.identifier == target.partitionIdentifier }),
        stub.type == "Apple_APFS", stub.uuid.lowercased() == target.uuid.lowercased(),
        stub.offset == target.offsetBytes, stub.size == target.sizeBytes,
        !plan.offsetBytes.addingReportingOverflow(plan.lengthBytes).overflow else {
        throw NativeHandoffValidationError.changedLayout
      }
      let end = plan.offsetBytes + plan.lengthBytes
      let parts = snapshot.partitions.filter { $0.offset >= stub.end && $0.offset < end }
        .sorted { $0.offset < $1.offset }
      guard parts.count == 3 else { throw NativeHandoffValidationError.changedLayout }
      for (part, recorded) in zip(parts, installed.populatedPartitions) {
        guard part.identifier == recorded.partitionIdentifier,
          part.uuid.lowercased() == recorded.partitionUuid.lowercased(),
          part.size == recorded.partitionSizeBytes, part.end <= end,
          part.type == (recorded.name == "EFI" ? "EFI" : "Linux Filesystem") else {
          throw NativeHandoffValidationError.changedLayout
        }
      }
      return parts
    }

    func espLayout(members: Set<String>, firmware: String) throws -> [String: String] {
      let common = members.contains("esp/aurora/stage1.bin") && qualifiedCommonFirmware.contains(firmware)
      let own = !common && Self.board(plan.deviceIdentifier) == "j700ap" ? "esp/m1n1/boot-j700.bin" : nil
      guard (!common || members.contains("esp/m1n1/boot.bin")),
        own.map({ members.contains($0) }) ?? true else {
        throw NativeHandoffValidationError.changedContent
      }
      var layout = [String: String]()
      for member in members.sorted() {
        guard member.hasPrefix("esp/"), Self.safeRelative(member) else {
          throw NativeHandoffValidationError.unsafePath
        }
        if member == own { layout[member] = "m1n1/boot.bin" }
        else if (member == "esp/aurora/stage1.bin" && !common)
          || member == "esp/m1n1/boot-j700.bin"
          || (common && ["esp/aurora/stage1-j700.bin", "esp/aurora/stage1-j613.bin"].contains(member))
          || (own != nil && member == "esp/m1n1/boot.bin") { continue }
        else { layout[member] = String(member.dropFirst(4)) }
      }
      guard !layout.isEmpty, Set(layout.values).count == layout.count else {
        throw NativeHandoffValidationError.changedContent
      }
      return layout
    }

    static func safeRelative(_ path: String) -> Bool {
      !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\0")
        && !path.contains("\\") && path.split(separator: "/", omittingEmptySubsequences: false)
          .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func board(_ device: String) -> String { String(device.dropFirst(6)) + "ap" }
    private static func partition(_ value: String) -> Bool {
      value.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil
    }
    private static func uuid(_ value: String) -> Bool {
      guard let id = UUID(uuidString: value) else { return false }
      return id.uuidString != "00000000-0000-0000-0000-000000000000"
    }
    private static func hash(_ value: String) -> Bool { SHA256Digest(hexadecimal: value) != nil }
    private static func keys(_ data: Data, _ expected: Set<String>) throws {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(object.keys) == expected else { throw NativeHandoffValidationError.invalidEvidence }
    }
  }
#endif
