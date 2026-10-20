#if os(macOS)
  import Darwin
  import Foundation

  enum NativeOSPartitionError: Error, Equatable {
    case invalidMetadata, changedLayout, ambiguousMutation, commandFailed
  }

  /// The complete authenticated layout is admitted before the first disk write.
  struct NativeOSPartitionPlan: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
      let name: String
      let type: String
      let bytes: UInt64
      let fatLabel: String?
      let volumeID: String?
    }
    let parts: [Part]

    init(metadata: Data, available: UInt64) throws {
      guard let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
        let templates = document["os_list"] as? [[String: Any]]
      else { throw NativeOSPartitionError.invalidMetadata }
      let selected = templates.filter { $0["omarchy_target"] as? String == "apple-silicon-full-os" }
      guard selected.count == 1, let template = selected.first,
        let label = template["default_os_name"] as? String, !label.isEmpty,
        let rows = template["partitions"] as? [[String: Any]], rows.count == 3,
        available > 0, available % 4096 == 0
      else { throw NativeOSPartitionError.invalidMetadata }
      let minimum = try rows.reduce(UInt64(0)) { total, row in
        guard let size = row["size"] as? String else { throw NativeOSPartitionError.invalidMetadata }
        return try NativeInspectionMath.add(total, NativeInspectionMath.alignUp(NativeInstallationMetadata.bytes(size)))
      }
      guard available >= minimum else { throw NativeOSPartitionError.invalidMetadata }
      var result = [Part]()
      for (index, row) in rows.enumerated() {
        let name = ["EFI", "Boot", "Root"][index]
        let type = index == 0 ? "EFI" : "Linux"
        guard row["name"] as? String == name, row["type"] as? String == type,
          (row["expand"] as? Bool ?? false) == (index == 2),
          row["expand"] == nil || row["expand"] is Bool,
          index == 0 ? row["format"] as? String == "fat" : row["format"] == nil,
          index == 0 ? row["source"] as? String == "esp" : row["image"] as? String == (index == 1 ? "boot.img" : "root.img"),
          index == 0 ? row["image"] == nil : row["source"] == nil
        else { throw NativeOSPartitionError.invalidMetadata }
        let base = try NativeInspectionMath.alignUp(NativeInstallationMetadata.bytes(row["size"] as! String))
        let bytes = try NativeInspectionMath.add(base, index == 2 ? available - minimum : 0)
        let volumeID: String?
        if let value = row["volume_id"] {
          guard index == 0, let text = value as? String,
            text.range(of: #"\A(?:0[xX])?[0-9A-Fa-f]{1,8}\z"#, options: .regularExpression) != nil
          else { throw NativeOSPartitionError.invalidMetadata }
          volumeID = text
        } else { volumeID = nil }
        let excluded = CharacterSet(charactersIn: "*?/\\|,;:+=<>[]\"")
        let clean = (name + " - " + label).unicodeScalars.filter { !excluded.contains($0) }
        let ascii = String(String.UnicodeScalarView(clean)).decomposedStringWithCompatibilityMapping
          .unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value != 127 }
        let fatLabel = String(String.UnicodeScalarView(ascii).prefix(11))
        guard index != 0 || !fatLabel.isEmpty else { throw NativeOSPartitionError.invalidMetadata }
        result.append(Part(name: name, type: type, bytes: bytes,
          fatLabel: index == 0 ? fatLabel : nil, volumeID: volumeID))
      }
      parts = result
    }
  }

  protocol NativeOSPartitionsExecuting: Sendable {
    func prepare(journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) throws
  }
  protocol NativeOSPartitionsPreparing: Sendable {
    func preflight(_ package: ImportedEngineHandoffPackage) throws -> any NativeOSPartitionsExecuting
  }

  struct NativeOSPartitionPlatform: Sendable {
    var disks: NativeAPFSPlatform
    var command: @Sendable (String, [String], FileHandle) throws -> Void
    static var live: Self {
      Self(disks: .live, command: { executable, arguments, lease in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = lease
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let deadline = DispatchTime.now() + .seconds(300)
        while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
          if Task.isCancelled || DispatchTime.now() >= deadline {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + .seconds(5)) == .timedOut, process.isRunning {
              kill(process.processIdentifier, SIGKILL)
              _ = exited.wait(timeout: .now() + .seconds(2))
            }
            try Task.checkCancellation()
            throw NativeOSPartitionError.commandFailed
          }
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
          throw NativeOSPartitionError.commandFailed
        }
      })
    }
  }

  struct NativeOSPartitionsPreparer: NativeOSPartitionsPreparing {
    var owner: uid_t = 0
    var platform: NativeOSPartitionPlatform = .live
    var firmwareFacts: @Sendable () throws -> NativeFirmwareSelection.Facts = { try .live() }

    func preflight(_ package: ImportedEngineHandoffPackage) throws -> any NativeOSPartitionsExecuting {
      guard package.installationIntent == .fresh else { throw NativeOSPartitionError.invalidMetadata }
      let approved = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let bytes = try tree.read(package.metadataURL.lastPathComponent, maximum: 65536)
      guard SHA256Digest(hashing: bytes).rawValue == approved.metadataDigest else {
        throw NativeOSPartitionError.invalidMetadata
      }
      let firmware = try NativeFirmwareSelection.choose(deviceIdentifier: package.deviceIdentifier,
        facts: firmwareFacts(), metadata: NativeInstallationMetadata(data: bytes), policy: NativeInspectionPolicy.sealed())
      guard approved.lengthBytes > firmware.stubBytes else { throw NativeOSPartitionError.invalidMetadata }
      let layout = try NativeOSPartitionPlan(metadata: bytes, available: approved.lengthBytes - firmware.stubBytes)
      return NativeOSPartitionsExecution(package: package, approved: approved, layout: layout,
        stubBytes: firmware.stubBytes, owner: owner, platform: platform)
    }
  }

  struct NativeOSPartitionsExecution: NativeOSPartitionsExecuting {
    struct Receipt: Codable {
      let plan: String
      let stubUUID: String
      let layout: NativeOSPartitionPlan
      let partitions: [RemovalPartition]
    }
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let layout: NativeOSPartitionPlan
    let stubBytes: UInt64
    let owner: uid_t
    let platform: NativeOSPartitionPlatform

    func prepare(journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(file.readJournal())
      guard transcript.plan == approved else { throw NativeOSPartitionError.changedLayout }
      if transcript.checkpoints.contains(where: { $0.identifier == "stub-and-esp-installed" }) { return }
      guard transcript.checkpoints.map(\.identifier) == ["apfs-target-prepared"],
        try file.readJournal().split(separator: 10).count == 5,
        try file.containsEvidence("native-stub-files")
      else { throw NativeOSPartitionError.changedLayout }
      let targetData = try file.readEvidence("apfs-target-prepared")
      guard transcript.checkpoints[0].evidenceDigest == SHA256Digest(hashing: targetData).rawValue else {
        throw NativeOSPartitionError.changedLayout
      }
      let target = try NativeAPFSTargetEvidence.read(targetData)
      var current = try platform.disks.snapshot()
      _ = try NativeDiskInventory.extents(current)
      let end = try NativeInspectionMath.add(approved.offsetBytes, approved.lengthBytes)
      guard target.planDigest == approved.planDigest, target.offsetBytes == approved.offsetBytes,
        target.sizeBytes == stubBytes, current.disk == approved.storeIdentifier,
        let stub = current.partitions.first(where: { $0.uuid == target.uuid }),
        stub.type == "Apple_APFS", stub.offset == approved.offsetBytes, stub.size == stubBytes
      else { throw NativeOSPartitionError.changedLayout }
      let volumes = try NativeStubVolumes.read(file.readEvidence(NativeStubVolumes.evidenceIdentifier))
      try volumes.validate(plan: approved.planDigest, target: stub, snapshot: current)
      try platform.disks.verifySourceOwner(package, authorization, sourceBootstrap)
      guard try platform.disks.snapshot() == current else { throw NativeOSPartitionError.changedLayout }
      let baselineName = "native-os-partition-baseline"
      let baseline: RemovalSnapshot
      if try file.containsEvidence(baselineName) {
        baseline = try JSONDecoder().decode(RemovalSnapshot.self, from: file.readEvidence(baselineName))
      } else {
        guard current.partitions.allSatisfy({ $0.uuid == stub.uuid || $0.offset < stub.end || $0.offset >= end }),
          try NativeDiskInventory.extents(current).contains(where: {
            $0.partition == nil && $0.offset == stub.end && $0.length >= end - stub.end
          })
        else { throw NativeOSPartitionError.changedLayout }
        baseline = current
        try file.publishEvidence(encode(baseline), identifier: baselineName)
      }
      var created = [RemovalPartition]()
      var expected = baseline
      for (index, part) in layout.parts.enumerated() {
        let receiptName = "native-os-partition-" + String(index)
        if try file.containsEvidence(receiptName) {
          let saved = try JSONDecoder().decode(RemovalPartition.self, from: file.readEvidence(receiptName))
          let offset = created.last?.end ?? stub.end
          guard saved.offset == offset, saved.size == part.bytes,
            saved.type == (part.type == "EFI" ? "EFI" : "Linux Filesystem"),
            saved.end <= end, let live = current.partitions.first(where: { $0.uuid == saved.uuid }), live == saved
          else { throw NativeOSPartitionError.changedLayout }
          created.append(live)
          expected.partitions.append(saved)
          expected.partitions.sort { $0.offset < $1.offset }
          continue
        }
        guard current == expected else { throw NativeOSPartitionError.changedLayout }
        let intent = receiptName + "-intent"
        guard try !file.containsEvidence(intent) else { throw NativeOSPartitionError.ambiguousMutation }
        let predecessor = created.last ?? stub
        try platform.disks.verifyPartition(predecessor, current.disk)
        guard try platform.disks.snapshot() == current else { throw NativeOSPartitionError.changedLayout }
        try Task.checkCancellation()
        try file.publishEvidence(encode(expected), identifier: intent)
        let lease = try file.leaseForChild()
        defer { try? lease.close() }
        try platform.command("/usr/sbin/diskutil", ["addPartition", predecessor.identifier,
          "%" + part.type + "%", "%noformat%", String(part.bytes)], lease)
        var after = try platform.disks.snapshot()
        let known = Set(current.partitions.map(\.uuid))
        let added = after.partitions.filter { !known.contains($0.uuid) }
        guard added.count == 1, let new = added.first,
          new.offset == predecessor.end, new.size == part.bytes, new.end <= end,
          new.type == (part.type == "EFI" ? "EFI" : "Linux Filesystem")
        else { throw NativeOSPartitionError.changedLayout }
        var remainder = after
        remainder.partitions.removeAll { $0.uuid == new.uuid }
        guard remainder == current else { throw NativeOSPartitionError.changedLayout }
        try platform.disks.verifyPartition(new, after.disk)
        if let label = part.fatLabel {
          try Task.checkCancellation()
          var arguments = ["-F", "32", "-v", label]
          if let volumeID = part.volumeID { arguments += ["-I", volumeID] }
          arguments.append("/dev/r" + new.identifier)
          try platform.command("/sbin/newfs_msdos", arguments, lease)
          after = try platform.disks.snapshot()
          guard let formatted = after.partitions.first(where: { $0.uuid == new.uuid }),
            formatted.identifier == new.identifier, formatted.type == new.type,
            formatted.offset == new.offset, formatted.size == new.size
          else { throw NativeOSPartitionError.changedLayout }
          remainder = after
          remainder.partitions.removeAll { $0.uuid == new.uuid }
          guard remainder == current else { throw NativeOSPartitionError.changedLayout }
        }
        let completed = after.partitions.first { $0.uuid == new.uuid }!
        try file.publishEvidence(encode(completed), identifier: receiptName)
        created.append(completed)
        expected = after
        current = after
      }
      guard current == expected, created.count == layout.parts.count,
        created.last?.end == end, try platform.disks.snapshot() == current
      else { throw NativeOSPartitionError.changedLayout }
      try file.publishEvidence(encode(Receipt(plan: approved.planDigest, stubUUID: stub.uuid,
        layout: layout, partitions: created)), identifier: "native-os-partitions")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(value)
    }
  }
#endif
