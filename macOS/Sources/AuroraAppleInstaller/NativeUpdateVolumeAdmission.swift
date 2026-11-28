#if os(macOS)
  import Foundation

  /// macOS 27.2 can add an Update volume outside any volume group to the new
  /// startup container after the installer first records its layout. Admit at
  /// most one such volume in that container under the same rule as initial
  /// preparation; refuse a second Update volume, a grouped Update volume, or
  /// any other volume or container change.
  enum NativeUpdateVolumeAdmission {
    static func isUpdateVolume(_ volume: RemovalVolume) -> Bool {
      volume.roles == ["Update"] && volume.group == nil
        && UUID(uuidString: volume.uuid)?.uuidString == volume.uuid
    }

    /// True when `live` equals `recorded`, or equals `recorded` plus one new
    /// ungrouped Update volume when `recorded` had none.
    static func matches(_ live: [RemovalVolume], recorded: [RemovalVolume]) -> Bool {
      if live == recorded { return true }
      guard !recorded.contains(where: { $0.roles == ["Update"] }),
        live.count == recorded.count + 1
      else { return false }
      let known = Set(recorded.map(\.uuid))
      let added = live.filter { !known.contains($0.uuid) }
      guard added.count == 1, let update = added.first, isUpdateVolume(update) else {
        return false
      }
      return live.filter { $0.uuid != update.uuid } == recorded
    }

    static func matches(_ live: RemovalContainer, recorded: RemovalContainer) -> Bool {
      live.uuid == recorded.uuid && live.storeUUID == recorded.storeUUID
        && matches(live.volumes, recorded: recorded.volumes)
    }

    /// True when `live` matches `recorded`, allowing at most one late-appearing
    /// ungrouped Update volume in the startup container named by `stubStoreUUID`.
    static func matches(
      _ live: RemovalSnapshot, recorded: RemovalSnapshot, stubStoreUUID: String
    ) -> Bool {
      guard live.disk == recorded.disk, live.devicePath == recorded.devicePath,
        live.diskSize == recorded.diskSize, live.macOSStoreUUID == recorded.macOSStoreUUID,
        live.macOSContainerUUID == recorded.macOSContainerUUID,
        live.partitions == recorded.partitions,
        live.containers.count == recorded.containers.count
      else { return false }
      return zip(live.containers, recorded.containers).allSatisfy { current, saved in
        saved.storeUUID == stubStoreUUID
          ? matches(current, recorded: saved)
          : current == saved
      }
    }
  }
#endif
