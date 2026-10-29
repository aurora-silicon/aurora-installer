#if os(macOS)
  import Foundation

  /// Mounting a newly formatted FAT ESP can reveal its volume label after the
  /// partition receipt was recorded. Admit only that exact label transition.
  enum NativeESPLabelAdmission {
    static func matches(_ live: RemovalPartition, saved: RemovalPartition, label: String?) -> Bool {
      if live == saved { return true }
      guard let label, !label.isEmpty, label.utf8.count <= 11,
        label.utf8.allSatisfy({ (32...126).contains($0) }),
        saved.type == "EFI", ["", "EFI"].contains(saved.name),
        live.name == label.uppercased(),
        live.uuid == saved.uuid, live.type == saved.type,
        live.offset == saved.offset, live.size == saved.size
      else { return false }
      return true
    }

    static func matches(
      _ live: RemovalSnapshot, recorded: RemovalSnapshot,
      espUUID: String, label: String?
    ) -> Bool {
      guard let index = recorded.partitions.firstIndex(where: { $0.uuid == espUUID }),
        recorded.partitions.filter({ $0.uuid == espUUID }).count == 1,
        let current = live.partitions.first(where: { $0.uuid == espUUID }),
        matches(current, saved: recorded.partitions[index], label: label)
      else { return false }
      var admitted = recorded
      admitted.partitions[index] = current
      return admitted == live
    }
  }
#endif
