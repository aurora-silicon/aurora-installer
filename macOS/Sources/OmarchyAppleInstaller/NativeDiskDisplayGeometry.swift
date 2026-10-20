#if os(macOS)
  import Foundation

  /// Render-only physical accounting from the same snapshot as the inventory.
  /// APFS volumes share their physical store and are never counted separately.
  public struct NativeDiskDisplayGeometry: Equatable, Sendable {
    public let diskTotalBytes: UInt64
    public let macOSStoreIdentifier: String
    public let macOSBytes: UInt64
    public let otherAllocatedBytes: UInt64
    public let unallocatedBytes: UInt64
    public let partitionNames: [String: String]

    public init(
      diskTotalBytes: UInt64, macOSStoreIdentifier: String, macOSBytes: UInt64,
      otherAllocatedBytes: UInt64, unallocatedBytes: UInt64,
      partitionNames: [String: String] = [:]
    ) throws {
      guard diskTotalBytes > 0, macOSBytes > 0, macOSBytes <= diskTotalBytes,
        otherAllocatedBytes <= diskTotalBytes - macOSBytes,
        unallocatedBytes == diskTotalBytes - macOSBytes - otherAllocatedBytes,
        NativeInspectionCommands.identifier(macOSStoreIdentifier)
      else { throw NativeInspectionError.invalidLayout }
      self.diskTotalBytes = diskTotalBytes
      self.macOSStoreIdentifier = macOSStoreIdentifier
      self.macOSBytes = macOSBytes
      self.otherAllocatedBytes = otherAllocatedBytes
      self.unallocatedBytes = unallocatedBytes
      self.partitionNames = partitionNames
    }

    init(snapshot: RemovalSnapshot) throws {
      let rows = try NativeDiskInventory.extents(snapshot)
      let stores = snapshot.partitions.filter { $0.uuid == snapshot.macOSStoreUUID }
      guard stores.count == 1, let store = stores.first, store.type == "Apple_APFS" else {
        throw NativeInspectionError.invalidLayout
      }
      var free: UInt64 = 0
      for row in rows where row.partition == nil {
        free = try NativeInspectionMath.add(free, row.length)
      }
      guard store.size <= snapshot.diskSize, free <= snapshot.diskSize - store.size else {
        throw NativeInspectionError.invalidLayout
      }
      try self.init(
        diskTotalBytes: snapshot.diskSize, macOSStoreIdentifier: store.identifier,
        macOSBytes: store.size,
        // Includes system partitions, GPT space and gaps too small to allocate.
        otherAllocatedBytes: snapshot.diskSize - store.size - free,
        unallocatedBytes: free,
        partitionNames: Dictionary(uniqueKeysWithValues: snapshot.partitions.map {
          ($0.identifier, $0.name)
        }))
    }
  }
#endif
