#if os(macOS)
  import Foundation

  /// A nondestructive recognition result, never authority to remove or repair.
  public struct NativeKnownInstallation: Equatable, Sendable {
    public let sourceIdentifier: String
    public let offsetBytes: UInt64
    public let lengthBytes: UInt64

    public init(sourceIdentifier: String, offsetBytes: UInt64, lengthBytes: UInt64) {
      self.sourceIdentifier = sourceIdentifier
      self.offsetBytes = offsetBytes
      self.lengthBytes = lengthBytes
    }
  }

  enum NativeKnownInstallations {
    static func recognize(_ disk: NativeCollectedDisk) throws -> [NativeKnownInstallation] {
      let rows = try NativeDiskInventory.extents(disk.snapshot)
      guard Set(disk.containers.map(\.storeUUID)).count == disk.containers.count else {
        throw NativeInspectionError.invalidLayout
      }
      let names = Set(AuroraDistribution.allCases.map(\.title) + ["Omarchy"])
      var result = [NativeKnownInstallation]()
      for (index, row) in rows.enumerated() {
        guard let stub = row.partition, stub.type == "Apple_APFS",
          let container = disk.containers.first(where: { $0.storeUUID == stub.uuid }),
          index + 3 < rows.count else { continue }
        guard container.capacity == stub.size, container.free <= container.capacity else {
          throw NativeInspectionError.invalidLayout
        }
        let systems = container.systems.filter { $0.stub && names.contains($0.label) }
        guard !systems.isEmpty else { continue }
        let members = rows[index...index + 3].compactMap(\.partition)
        guard members.count == 4, members[1].type == "EFI",
          members[2].type == "Linux Filesystem", members[3].type == "Linux Filesystem",
          systems.contains(where: { members[1].name == espLabel(for: $0.label) }) else { continue }
        let end = try NativeInspectionMath.add(members[3].offset, members[3].size)
        result.append(NativeKnownInstallation(sourceIdentifier: stub.identifier,
          offsetBytes: stub.offset, lengthBytes: end - stub.offset))
      }
      return result
    }

    // These source-defined titles are ASCII. Match the existing FAT formatter's
    // eleven-character label, rather than the old fixed label for one distro.
    static func espLabel(for title: String) -> String {
      String(("EFI - " + title).prefix(11)).uppercased()
    }
  }
#endif
