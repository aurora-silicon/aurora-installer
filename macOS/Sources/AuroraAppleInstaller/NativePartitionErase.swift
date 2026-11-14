#if os(macOS)
  import Foundation

  /// What Erase on the Partitions screen may delete. The screen and the
  /// helper apply this one rule to their own scans of the same disk, so a row
  /// offered as erasable is one the helper accepts, and the helper decides.
  ///
  /// Erase deletes a row's partitions and leaves their extent unallocated.
  /// It preserves Apple's system container and Recovery partition, the
  /// running macOS, and EFI partitions needed by startup containers that stay.
  enum NativePartitionErase {
    static func refusal(members: [RemovalPartition], disk: NativeCollectedDisk) -> String? {
      let snapshot = disk.snapshot
      guard !members.isEmpty else { return "There’s nothing to erase here." }
      // The running store must be identifiable even when the selected row
      // contains another full macOS installation.
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      guard parts.contains(where: { $0.uuid == snapshot.macOSStoreUUID }) else {
        return "The macOS you’re running couldn’t be identified, so nothing can be erased."
      }
      for part in members {
        if part.uuid == snapshot.macOSStoreUUID {
          return "The macOS you’re running is never erased."
        }
        // Position still protects Apple's first and last partitions when a
        // damaged partition table reports an unexpected type.
        if ["Apple_APFS_ISC", "Apple_APFS_Recovery"].contains(part.type)
          || part.uuid == parts.first?.uuid || part.uuid == parts.last?.uuid
        {
          return "Apple’s system partitions are never erased."
        }
        if part.type == "Apple_APFS",
          !snapshot.containers.contains(where: { $0.storeUUID == part.uuid })
        {
          return
            "\(part.identifier) couldn’t be listed as an APFS container, so its contents can’t be reviewed for erasure."
        }
      }
      // An EFI partition stays while a kept container may start from it.
      let erased = Set(members.map(\.uuid))
      guard members.contains(where: { $0.type == "EFI" }) else { return nil }
      func unknown(_ name: String) -> String {
        "The bootloader of \(name) couldn’t be read, so any EFI partition might be the one it starts from. Erase \(name) first."
      }
      for part in parts
      where part.type == "Apple_APFS" && !erased.contains(part.uuid)
        && part.uuid != snapshot.macOSStoreUUID
      {
        guard let container = snapshot.containers.first(where: { $0.storeUUID == part.uuid })
        else { return unknown(part.identifier) }
        guard container.volumes.contains(where: { $0.roles == ["System"] }) else { continue }
        guard let facts = disk.containers.first(where: { $0.storeUUID == part.uuid }),
          !facts.systems.isEmpty
        else { return unknown(part.identifier) }
        for system in facts.systems where system.stub {
          guard let boot = system.bootPartitions else { return unknown("“\(system.label)”") }
          if let part = members.first(where: { $0.type == "EFI" && boot.contains($0.uuid) }) {
            return
              "“\(system.label)” starts Linux from the EFI partition \(part.identifier). Erase “\(system.label)” together with it."
          }
        }
      }
      return nil
    }

    /// The disk once `members` are gone: the free extent their space joins,
    /// with the free space on either side, as inspection will then find it.
    static func freedExtent(members: [RemovalPartition], snapshot: RemovalSnapshot)
      -> (offset: UInt64, length: UInt64)?
    {
      let erased = Set(members.map(\.uuid))
      guard let first = members.map(\.offset).min(), let last = members.map(\.end).max() else {
        return nil
      }
      var after = snapshot
      after.partitions.removeAll { erased.contains($0.uuid) }
      after.containers.removeAll { erased.contains($0.storeUUID) }
      guard !after.partitions.isEmpty, let rows = try? NativeDiskInventory.extents(after),
        let free = rows.first(where: {
          $0.partition == nil && $0.offset <= first && $0.offset + $0.length >= last
        })
      else { return nil }
      return (free.offset, NativeInspectionMath.alignDown(free.length))
    }
  }
#endif
