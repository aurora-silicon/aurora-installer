#if os(macOS)
  import Foundation

  /// Every part of the internal disk in disk order, from the same snapshot as
  /// the inventory, for the Partitions screen. Render-only: planning still
  /// uses the inventory's candidates, and removal its own fresh scan.
  public struct NativeDiskLayout: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
      /// Apple's system container or its Recovery partition.
      case appleSystem
      /// An APFS container with a macOS installation.
      case macOS
      /// A Linux installation: its startup container, EFI and Linux partitions.
      case linux
      case free
      /// Anything else, such as an APFS data container.
      case other
    }

    public struct Region: Equatable, Sendable {
      public let kind: Kind
      /// The partition; for a Linux installation, its startup container. Nil
      /// for free space.
      public let identifier: String?
      public let uuid: String?
      public let offsetBytes: UInt64
      public let lengthBytes: UInt64
      /// The system volume's name, or the partition's.
      public let name: String
      /// Free space inside an APFS container.
      public let freeBytes: UInt64?
      /// The system volume, whose own icon is shown when it is mounted.
      public let systemVolumeUUID: String?
      /// A title and layout this installer recognizes as its own.
      public let recognized: Bool
      /// Only the startup container an unfinished installation left.
      public let partial: Bool
      /// The macOS that is running now.
      public let isRunningMacOS: Bool

      public init(
        kind: Kind, identifier: String? = nil, uuid: String? = nil, offsetBytes: UInt64,
        lengthBytes: UInt64, name: String, freeBytes: UInt64? = nil,
        systemVolumeUUID: String? = nil, recognized: Bool = false, partial: Bool = false,
        isRunningMacOS: Bool = false
      ) {
        self.kind = kind
        self.identifier = identifier
        self.uuid = uuid
        self.offsetBytes = offsetBytes
        self.lengthBytes = lengthBytes
        self.name = name
        self.freeBytes = freeBytes
        self.systemVolumeUUID = systemVolumeUUID
        self.recognized = recognized
        self.partial = partial
        self.isRunningMacOS = isRunningMacOS
      }

      public var endBytes: UInt64 { offsetBytes &+ lengthBytes }
    }

    public let diskBytes: UInt64
    public let regions: [Region]
    /// The startup container the removal service's own recognition would
    /// delete now. Nil when it would refuse this layout. The removal service
    /// scans again and decides; this only says which row it would act on.
    public let removableStartupContainerUUID: String?

    public init(diskBytes: UInt64, regions: [Region], removableStartupContainerUUID: String? = nil)
    {
      self.diskBytes = diskBytes
      self.regions = regions
      self.removableStartupContainerUUID = removableStartupContainerUUID
    }

    init(_ disk: NativeCollectedDisk) throws {
      let snapshot = disk.snapshot
      let rows = try NativeDiskInventory.extents(snapshot)
      let known = try NativeKnownInstallations.recognize(disk)
      var regions = [Region]()
      var index = 0
      func systemVolume(_ part: RemovalPartition, named label: String?) -> RemovalVolume? {
        let volumes = snapshot.containers.first { $0.storeUUID == part.uuid }?.volumes ?? []
        return volumes.first { $0.roles == ["System"] && (label == nil || $0.name == label) }
      }
      while index < rows.count {
        let row = rows[index]
        index += 1
        guard let part = row.partition else {
          regions.append(
            Region(kind: .free, offsetBytes: row.offset, lengthBytes: row.length, name: "Free"))
          continue
        }
        let facts = disk.containers.first { $0.storeUUID == part.uuid }
        switch part.type {
        case "Apple_APFS_ISC", "Apple_APFS_Recovery":
          regions.append(
            Region(
              kind: .appleSystem, identifier: part.identifier, uuid: part.uuid,
              offsetBytes: part.offset, lengthBytes: part.size,
              name: part.type == "Apple_APFS_ISC" ? "Apple system" : "Recovery"))
        case "Apple_APFS":
          if let installation = known.first(where: { $0.sourceIdentifier == part.identifier }) {
            let label = facts?.systems.first { $0.stub }?.label ?? part.name
            let end = installation.offsetBytes &+ installation.lengthBytes
            while index < rows.count, let next = rows[index].partition, next.offset < end {
              index += 1
            }
            regions.append(
              Region(
                kind: .linux, identifier: part.identifier, uuid: part.uuid,
                offsetBytes: installation.offsetBytes, lengthBytes: installation.lengthBytes,
                name: label, systemVolumeUUID: systemVolume(part, named: label)?.uuid,
                recognized: true, partial: installation.partial))
          } else if let system = facts?.systems.first(where: {
            !$0.stub && $0.version?.isEmpty == false
          }) {
            regions.append(
              Region(
                kind: .macOS, identifier: part.identifier, uuid: part.uuid,
                offsetBytes: part.offset, lengthBytes: part.size, name: system.label,
                freeBytes: facts?.free,
                systemVolumeUUID: systemVolume(part, named: system.label)?.uuid,
                isRunningMacOS: part.uuid == snapshot.macOSStoreUUID))
          } else if let stub = facts?.systems.first(where: \.stub) {
            // Another installer's Linux: its startup container, then its own
            // EFI and Linux partitions.
            var end = part.end
            var sawESP = false
            while index < rows.count, let next = rows[index].partition,
              next.type == "Linux Filesystem" || (next.type == "EFI" && !sawESP)
            {
              sawESP = sawESP || next.type == "EFI"
              end = next.end
              index += 1
            }
            regions.append(
              Region(
                kind: .linux, identifier: part.identifier, uuid: part.uuid,
                offsetBytes: part.offset, lengthBytes: end - part.offset, name: stub.label,
                systemVolumeUUID: systemVolume(part, named: stub.label)?.uuid))
          } else {
            let volumes = snapshot.containers.first { $0.storeUUID == part.uuid }?.volumes ?? []
            regions.append(
              Region(
                kind: .other, identifier: part.identifier, uuid: part.uuid,
                offsetBytes: part.offset, lengthBytes: part.size,
                name: volumes.first(where: { $0.roles.isEmpty || $0.roles == ["Data"] })?.name
                  ?? (part.name.isEmpty ? "APFS container" : part.name),
                freeBytes: facts?.free))
          }
        case "EFI", "Linux Filesystem":
          // Linux partitions with no startup container of their own.
          var end = part.end
          while index < rows.count, let next = rows[index].partition,
            ["EFI", "Linux Filesystem"].contains(next.type)
          {
            end = next.end
            index += 1
          }
          regions.append(
            Region(
              kind: .linux, identifier: part.identifier, uuid: part.uuid,
              offsetBytes: part.offset, lengthBytes: end - part.offset,
              name: part.name.isEmpty ? "Linux" : part.name))
        default:
          regions.append(
            Region(
              kind: .other, identifier: part.identifier, uuid: part.uuid,
              offsetBytes: part.offset, lengthBytes: part.size,
              name: part.name.isEmpty ? "Other" : part.name))
        }
      }
      let removable: String?
      switch try? RemovalLayout.recognize(snapshot) {
      case .installation(let found, _, _): removable = found.stub.uuid
      case .partialInstallation(let stub, _, _, _): removable = stub.uuid
      default: removable = nil
      }
      self.init(
        diskBytes: snapshot.diskSize, regions: regions, removableStartupContainerUUID: removable)
    }
  }
#endif
