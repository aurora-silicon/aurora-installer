#if os(macOS)
  import Foundation

  /// A nondestructive recognition result, never authority to remove or repair.
  public struct NativeKnownInstallation: Equatable, Sendable {
    public let sourceIdentifier: String
    public let offsetBytes: UInt64
    public let lengthBytes: UInt64
    /// Only the startup container of an installation that stopped early.
    public let partial: Bool

    public init(
      sourceIdentifier: String, offsetBytes: UInt64, lengthBytes: UInt64, partial: Bool = false
    ) {
      self.sourceIdentifier = sourceIdentifier
      self.offsetBytes = offsetBytes
      self.lengthBytes = lengthBytes
      self.partial = partial
    }
  }

  enum NativeKnownInstallations {
    static let recognizedTitles = Set(AuroraDistribution.allCases.map(\.title) + ["Omarchy"])

    static func recognize(_ disk: NativeCollectedDisk) throws -> [NativeKnownInstallation] {
      let rows = try NativeDiskInventory.extents(disk.snapshot)
      guard Set(disk.containers.map(\.storeUUID)).count == disk.containers.count else {
        throw NativeInspectionError.invalidLayout
      }
      var result = [NativeKnownInstallation]()
      for (index, row) in rows.enumerated() {
        guard let stub = row.partition, stub.type == "Apple_APFS",
          let container = disk.containers.first(where: { $0.storeUUID == stub.uuid })
        else { continue }
        guard index + 3 < rows.count else {
          if let partial = partial(rows, at: index, disk: disk) { result.append(partial) }
          continue
        }
        guard container.capacity == stub.size, container.free <= container.capacity else {
          throw NativeInspectionError.invalidLayout
        }
        let systems = container.systems.filter { $0.stub && recognizedTitles.contains($0.label) }
        guard !systems.isEmpty else { continue }
        let members = rows[index...index + 3].compactMap(\.partition)
        guard members.count == 4, members[1].type == "EFI",
          members[2].type == "Linux Filesystem", members[3].type == "Linux Filesystem",
          systems.contains(where: { members[1].name == espLabel(for: $0.label) })
        else {
          if let partial = partial(rows, at: index, disk: disk) { result.append(partial) }
          continue
        }
        let end = try NativeInspectionMath.add(members[3].offset, members[3].size)
        result.append(
          NativeKnownInstallation(
            sourceIdentifier: stub.identifier,
            offsetBytes: stub.offset, lengthBytes: end - stub.offset))
      }
      return result
    }

    /// A fresh install that stopped right after creating its startup
    /// container leaves only that container: one recognized stub system,
    /// directly after macOS, with no EFI partition after it. Only removal
    /// may delete it, and only on the installer journal's proof.
    private static func partial(
      _ rows: [NativeDiskInventory.Extent], at index: Int, disk: NativeCollectedDisk
    ) -> NativeKnownInstallation? {
      guard index > 0, let stub = rows[index].partition,
        let macOS = rows[index - 1].partition, macOS.uuid == disk.snapshot.macOSStoreUUID,
        macOS.end == stub.offset,
        let container = disk.containers.first(where: { $0.storeUUID == stub.uuid }),
        container.capacity == stub.size, container.systems.count == 1,
        let system = container.systems.first, system.stub,
        recognizedTitles.contains(system.label),
        rows[(index + 1)...].first(where: { $0.partition != nil })?.partition?.type != "EFI"
      else { return nil }
      return NativeKnownInstallation(
        sourceIdentifier: stub.identifier, offsetBytes: stub.offset, lengthBytes: stub.size,
        partial: true)
    }

    // These source-defined titles are ASCII. Match the existing FAT formatter's
    // eleven-character label, rather than the old fixed label for one distro.
    static func espLabel(for title: String) -> String {
      String(("EFI - " + title).prefix(11)).uppercased()
    }
  }
#endif
