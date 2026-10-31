#if os(macOS)
  import CoreFoundation
  import Foundation

  public struct NativeInstallerInspection: Sendable {
    public let transcript: Data
    public let validated: ValidatedEngineTranscript
    public let knownInstallations: [NativeKnownInstallation]
    public let displayGeometry: NativeDiskDisplayGeometry?

    public init(
      transcript: Data, knownInstallations: [NativeKnownInstallation] = [],
      displayGeometry: NativeDiskDisplayGeometry? = nil
    ) throws {
      self.transcript = transcript
      validated = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
      self.knownInstallations = knownInstallations
      self.displayGeometry = displayGeometry
    }
  }

  public protocol NativeInstallerInspecting: Sendable {
    func inspect(host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact?) async throws
      -> NativeInstallerInspection
    /// The same inspection for an experimental choice: refused unless the
    /// decision, run again here, gives the record.
    func inspect(
      host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact?,
      experimental: ExperimentalAdmissionRecord?
    ) async throws -> NativeInstallerInspection
  }

  extension NativeInstallerInspecting {
    public func inspect(
      host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact?,
      experimental: ExperimentalAdmissionRecord?
    ) async throws -> NativeInstallerInspection {
      guard experimental == nil else {
        throw ExperimentalAdmissionError.notOffered
      }
      return try await inspect(host: host, metadata: metadata)
    }
  }

  struct NativeCollectedDisk: Sendable {
    let snapshot: RemovalSnapshot
    let containers: [NativeContainerFacts]
  }

  public struct NativeInstallerInspector: NativeInstallerInspecting, Sendable {
    private let policy: @Sendable () throws -> NativeInspectionPolicy
    private let hardware: @Sendable () throws -> NativeInspectionHardware
    private let collect: @Sendable (AppleSiliconHostInspection) throws -> NativeCollectedDisk

    public init() {
      policy = { try NativeInspectionPolicy.sealed() }
      hardware = { try NativeInspectionHardware.live() }
      collect = { try NativeDiskCollector().collect(host: $0) }
    }

    init(
      policy: @escaping @Sendable () throws -> NativeInspectionPolicy,
      hardware: @escaping @Sendable () throws -> NativeInspectionHardware,
      collect: @escaping @Sendable (AppleSiliconHostInspection) throws -> NativeCollectedDisk
    ) {
      self.policy = policy
      self.hardware = hardware
      self.collect = collect
    }

    public func inspect(host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact? = nil)
      async throws -> NativeInstallerInspection
    {
      try await inspect(host: host, metadata: metadata, experimental: nil)
    }

    public func inspect(
      host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact?,
      experimental: ExperimentalAdmissionRecord?
    ) async throws -> NativeInstallerInspection {
      try Task.checkCancellation()
      let worker = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        var policy = try self.policy()
        let hardware = try self.hardware()
        let device = host.identity.deviceIdentifier
        // Without an experimental record this is the original order and check.
        guard
          experimental != nil
            || (!AppleSiliconHostInspector.isExplicitlyUnsupported(device)
              && policy.supports(device, hardware: hardware))
        else {
          return try NativeInstallerInspection(
            transcript: NativeDiskInventory.unsupported(device: device))
        }
        let metadata =
          try metadata.map(NativeInstallationMetadata.authenticated)
          ?? (experimental == nil
            ? policy.baselineMetadata : ExperimentalHardwareInspection.anyPayload())
        if let experimental {
          policy =
            try NativeDeviceAdmission.verify(
              experimental, deviceIdentifier: device, hardware: hardware, policy: policy,
              metadata: metadata
            ).policy
        }
        let stub = try policy.stubBytes(device, hardware: hardware, metadata: metadata)
        let disk = try self.collect(host)
        try Task.checkCancellation()
        let result = try NativeInstallerInspection(
          transcript: NativeDiskInventory.transcript(
            device: device, snapshot: disk.snapshot, containers: disk.containers,
            metadata: metadata, stubBytes: stub),
          knownInstallations: NativeKnownInstallations.recognize(disk),
          displayGeometry: NativeDiskDisplayGeometry(snapshot: disk.snapshot))
        try Task.checkCancellation()
        return result
      }
      let result = try await withTaskCancellationHandler(
        operation: { try await worker.value },
        onCancel: { worker.cancel() })
      try Task.checkCancellation()
      return result
    }
  }

  struct NativeDiskCollector: Sendable {
    var disks: MacRemovalDiskOperator

    init() {
      var disks = MacRemovalDiskOperator()
      disks.commands = { try NativeInspectionCommands.run($0) }
      disks.cleanupCommands = { try NativeInspectionCommands.run($0, cleanup: true) }
      self.disks = disks
    }

    init(disks: MacRemovalDiskOperator) { self.disks = disks }

    func collect(host: AppleSiliconHostInspection) throws -> NativeCollectedDisk {
      try Task.checkCancellation()
      let before = try disks.snapshot(maximumPartitions: 4096)
      guard let rootStore = before.partitions.first(where: { $0.uuid == before.macOSStoreUUID }),
        rootStore.identifier == host.storage.physicalStoreIdentifier,
        host.storage.isInternal
      else { throw NativeInspectionError.invalidLayout }
      let root = try plist(["info", "-plist", "/"])
      guard root["APFSContainerReference"] as? String == host.storage.containerIdentifier,
        let stores = root["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        stores[0]["APFSPhysicalStore"] as? String == rootStore.identifier
      else {
        throw NativeInspectionError.invalidLayout
      }
      let rootGroup = (root["APFSVolumeGroupID"] as? String).flatMap(UUID.init(uuidString:))?
        .uuidString
      let listing = try plist(["apfs", "list", "-plist"])
      guard let rawContainers = listing["Containers"] as? [[String: Any]] else {
        throw NativeInspectionError.invalidLayout
      }
      var facts = [NativeContainerFacts]()
      for container in before.containers {
        try Task.checkCancellation()
        guard let part = before.partitions.first(where: { $0.uuid == container.storeUUID }) else {
          throw NativeInspectionError.invalidLayout
        }
        guard part.type == "Apple_APFS" else { continue }
        let matching = rawContainers.filter {
          ($0["APFSContainerUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            == container.uuid
        }
        guard matching.count == 1, let raw = matching.first,
          let reference = raw["ContainerReference"] as? String,
          NativeInspectionCommands.identifier(reference)
        else { throw NativeInspectionError.invalidLayout }
        let capacity = try unsigned(raw, "CapacityCeiling")
        let free = try unsigned(raw, "CapacityFree")
        guard capacity == part.size, free <= capacity else {
          throw NativeInspectionError.invalidLayout
        }
        let systemVolumes = container.volumes.filter { $0.roles == ["System"] }
        if !systemVolumes.isEmpty {
          guard container.volumes.filter({ $0.roles == ["Preboot"] }).count == 1,
            container.volumes.filter({ $0.roles == ["Recovery"] }).count == 1
          else {
            throw NativeInspectionError.systemVolumeUnreadable
          }
        }
        var systems = [NativeSystemVolumeFacts]()
        for system in systemVolumes {
          guard let group = system.group,
            systemVolumes.filter({ $0.group == group }).count == 1,
            container.volumes.filter({ $0.roles == ["Data"] && $0.group == group }).count == 1
          else { throw NativeInspectionError.systemVolumeUnreadable }
          let read: (RemovalFileTree) throws -> NativeSystemVolumeFacts = { tree in
            let stub = !(try tree.exists("Library"))
            var version: String?
            for name in ["SystemVersion.plist", "SystemVersion-disabled.plist"] {
              guard
                let data = try tree.read(
                  ["System", "Library", "CoreServices", name], limit: 65_536)
              else {
                continue
              }
              guard
                let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any], let product = value["ProductVersion"] as? String,
                !product.isEmpty
              else {
                throw NativeInspectionError.systemVolumeUnreadable
              }
              version = product
              break
            }
            return NativeSystemVolumeFacts(
              group: group, label: system.name, stub: stub, version: version)
          }
          // The booted System volume is normally a mounted snapshot, whose
          // BSD identity differs from the underlying System volume's identity.
          if container.uuid == before.macOSContainerUUID, group == rootGroup {
            guard let identifier = root["DeviceIdentifier"] as? String,
              NativeInspectionCommands.identifier(identifier), root["MountPoint"] as? String == "/"
            else { throw NativeInspectionError.invalidLayout }
            systems.append(try read(disks.openTree("/", identifier)))
          } else {
            systems.append(
              try disks.withVolume(
                system.identifier, uuid: system.uuid,
                belongs: { info in
                  guard info["APFSContainerReference"] as? String == reference,
                    let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1
                  else { return false }
                  return stores[0]["APFSPhysicalStore"] as? String == part.identifier
                }, read: read))
          }
        }
        var minimum: UInt64 = 0
        if NativeDiskInventory.resizeEligible(
          diskSize: before.diskSize, free: free, systems: systems)
        {
          let limits = try plist(["apfs", "resizeContainer", part.identifier, "limits", "-plist"])
          minimum = try unsigned(limits, "MinimumSizePreferred")
        }
        facts.append(
          NativeContainerFacts(
            storeUUID: part.uuid, capacity: capacity, free: free,
            preferredMinimum: minimum, systems: systems))
      }
      // Read-only collection can overlap a user changing disks elsewhere.
      // Never combine geometry or BSD identifiers from two different layouts.
      let after = try disks.snapshot(maximumPartitions: 4096)
      guard before == after,
        before.partitions.map(\.identifier) == after.partitions.map(\.identifier),
        before.containers.flatMap({ $0.volumes.map(\.identifier) })
          == after.containers.flatMap({ $0.volumes.map(\.identifier) })
      else {
        throw NativeInspectionError.invalidLayout
      }
      try Task.checkCancellation()
      return NativeCollectedDisk(snapshot: after, containers: facts)
    }

    private func plist(_ arguments: [String]) throws -> [String: Any] {
      guard
        let value = try PropertyListSerialization.propertyList(
          from: disks.commands(arguments), format: nil)
          as? [String: Any]
      else { throw NativeInspectionError.invalidLayout }
      return value
    }

    private func unsigned(_ value: [String: Any], _ key: String) throws -> UInt64 {
      guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        ["Q", "q", "I", "i", "L", "l", "S", "s", "C", "c"].contains(
          String(cString: number.objCType)),
        !number.stringValue.hasPrefix("-")
      else { throw NativeInspectionError.invalidLayout }
      return number.uint64Value
    }
  }
#endif
