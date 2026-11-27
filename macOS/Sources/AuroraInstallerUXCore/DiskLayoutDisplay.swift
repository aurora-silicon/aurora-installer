#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// The Partitions screen: every installation on the disk, the disk strip,
  /// and where another installation could go. Render-only: an option names a
  /// target, and planning checks that target afresh against the inventory.
  public struct DiskLayoutDisplay: Equatable, Sendable {
    /// Shrink is offered only for a macOS with at least this much free.
    public static let shrinkOfferedFreeBytes: UInt64 = 50_000_000_000
    /// What a shrunk macOS always keeps free (Asahi's MIN_FREE_OS).
    public static let macOSKeepsFreeBytes = PlanDisplay.recommendedMacOSFreeBytes

    public enum SegmentKind: String, Equatable, Sendable {
      case macOS, aurora, otherLinux, free, appleSystem, other
    }

    /// One part of the disk strip, in disk order.
    public struct Segment: Equatable, Sendable, Identifiable {
      public let id: String
      public let kind: SegmentKind
      public let name: String
      public let bytes: UInt64
      /// macOS only: the part of the container in use.
      public let usedBytes: UInt64?

      public init(
        id: String, kind: SegmentKind, name: String, bytes: UInt64, usedBytes: UInt64? = nil
      ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bytes = bytes
        self.usedBytes = usedBytes
      }
    }

    public enum RowIcon: Equatable, Sendable {
      /// The `.VolumeIcon.icns` the volume itself carries.
      case volumeIcon(URL)
      /// The simulation's stand-in for an Aurora volume's own icon.
      case auroraVolume
      /// The standard internal-drive icon.
      case internalDrive
    }

    public enum Availability: Equatable, Sendable {
      case available
      case unavailable(String)

      public var isAvailable: Bool { self == .available }
      public var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
      }
    }

    /// What Erase on one row deletes. The removal service scans again and
    /// must name exactly these partitions before anything is approved.
    public struct EraseTarget: Equatable, Sendable, Identifiable {
      /// The row's first partition, which names the row to the service.
      public let anchorUUID: String
      /// Every partition in the row, in disk order.
      public let memberUUIDs: [String]
      public let name: String
      public let bytes: UInt64
      /// The unallocated space left afterwards, joined with its neighbours.
      public let freedBytes: UInt64
      public var id: String { anchorUUID }

      public init(
        anchorUUID: String, memberUUIDs: [String], name: String, bytes: UInt64, freedBytes: UInt64
      ) {
        self.anchorUUID = anchorUUID
        self.memberUUIDs = memberUUIDs
        self.name = name
        self.bytes = bytes
        self.freedBytes = freedBytes
      }
    }

    public struct Row: Equatable, Sendable, Identifiable {
      /// `other` is anything else Erase may delete, such as a partition with
      /// another file system or an APFS container without a system.
      public enum Kind: String, Equatable, Sendable { case macOS, aurora, otherLinux, other }

      /// The partition identifier; for Linux, its startup container.
      public let id: String
      public let kind: Kind
      public let name: String
      public let bytes: UInt64
      public let icon: RowIcon
      /// The startup container's partition UUID, which Erase must match.
      public let startupContainerUUID: String?
      /// Only the startup container an unfinished installation left.
      public let partial: Bool
      /// Every row but the running macOS: whether Erase may delete it.
      public let erase: Availability?
      /// Set when Erase is available: exactly what it deletes.
      public let eraseTarget: EraseTarget?
      /// Aurora installations only: the preserved Stage 1 reinstall.
      public let reset: Availability?
      /// macOS only, when it has room to give.
      public let shrink: InstallerPlanTarget?

      public init(
        id: String, kind: Kind, name: String, bytes: UInt64, icon: RowIcon,
        startupContainerUUID: String? = nil, partial: Bool = false, erase: Availability? = nil,
        eraseTarget: EraseTarget? = nil, reset: Availability? = nil,
        shrink: InstallerPlanTarget? = nil
      ) {
        self.eraseTarget = eraseTarget
        self.id = id
        self.kind = kind
        self.name = name
        self.bytes = bytes
        self.icon = icon
        self.startupContainerUUID = startupContainerUUID
        self.partial = partial
        self.erase = erase
        self.reset = reset
        self.shrink = shrink
      }

      /// The line under the name: its size, nothing more.
      public var detail: String {
        partial
          ? "\(PlainLanguage.bytes(bytes)) · unfinished installation" : PlainLanguage.bytes(bytes)
      }
    }

    /// One way to make room for another installation.
    public struct Option: Equatable, Sendable, Identifiable {
      public enum Kind: String, Equatable, Sendable { case freeSpace, shrink }

      public let kind: Kind
      public let target: InstallerPlanTarget
      public let title: String
      public let detail: String
      /// The most this option can give, before the plan screen's exact check.
      public let maximumBytes: UInt64
      /// Shrink only: free space directly after the container. Planning
      /// cannot add it to the shrunk space; it stays a separate option.
      public let adjacentFreeBytes: UInt64?

      public var id: String {
        switch target {
        case .freeSpace(let offset): "free@\(offset)"
        case .shrink(let source): "shrink:\(source)"
        }
      }

      public var sizeText: String {
        kind == .shrink
          ? "up to \(PlainLanguage.bytes(maximumBytes))" : PlainLanguage.bytes(maximumBytes)
      }
    }

    public let totalBytes: UInt64
    public let segments: [Segment]
    public let rows: [Row]
    public let options: [Option]

    public init(totalBytes: UInt64, segments: [Segment], rows: [Row], options: [Option]) {
      self.totalBytes = totalBytes
      self.segments = segments
      self.rows = rows
      self.options = options
    }

    /// A Mac with only one macOS keeps today's flow: the screen is shown when
    /// there is any Linux installation, free space big enough to install
    /// into, or more than one macOS.
    public var isComplex: Bool {
      rows.contains { $0.kind != .macOS } || options.contains { $0.kind == .freeSpace }
        || rows.filter { $0.kind == .macOS }.count > 1
    }

    public var diskDescription: String { "Internal storage · \(PlainLanguage.bytes(totalBytes))" }

    public var macOSRows: [Row] { rows.filter { $0.kind == .macOS } }

    /// Why nothing can be added, when no option exists.
    public var noRoomReason: String? {
      guard options.isEmpty else { return nil }
      let macOS = macOSRows
      let space: String
      if macOS.count == 1, let free = freeBytes(of: macOS[0].id) {
        space = "\(macOS[0].name) has \(PlainLanguage.bytes(free)) free"
      } else {
        space = "no macOS has more than \(PlainLanguage.bytes(Self.shrinkOfferedFreeBytes)) free"
      }
      return
        "No free space is big enough, and \(space). Erase a partition above, or free up space in macOS until it has more than \(PlainLanguage.bytes(Self.shrinkOfferedFreeBytes)) free."
    }

    /// The same disk once this row is erased, as the removal service does it:
    /// its extent becomes unallocated and joins the free space on either
    /// side. Nothing grows into it. Nil for a row Erase does not apply to.
    public func afterErasing(_ rowID: String) -> [Segment]? {
      guard let erased = segments.firstIndex(where: { $0.id == rowID }),
        rows.first(where: { $0.id == rowID })?.erase?.isAvailable == true
      else { return nil }
      var first = erased
      var last = erased
      while first > 0, segments[first - 1].kind == .free { first -= 1 }
      while last + 1 < segments.count, segments[last + 1].kind == .free { last += 1 }
      var result = segments
      result.replaceSubrange(
        first...last,
        with: [
          Segment(
            id: "erased:\(rowID)", kind: .free, name: "Free",
            bytes: segments[first...last].reduce(0) { $0 + $1.bytes })
        ])
      return result
    }

    /// The free extent Erase leaves for this row, joined with its neighbours.
    public func freeBytesAfterErasing(_ rowID: String) -> UInt64? {
      afterErasing(rowID)?.first { $0.id == "erased:\(rowID)" }?.bytes
    }

    public func freeBytes(of rowID: String) -> UInt64? {
      guard let segment = segments.first(where: { $0.id == rowID }), let used = segment.usedBytes
      else { return nil }
      return segment.bytes - min(segment.bytes, used)
    }

    public func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    public func option(for target: InstallerPlanTarget) -> Option? {
      options.first { $0.target == target }
    }
  }

  extension DiskLayoutDisplay {
    public static let eraseUnavailableReason =
      "Erase isn’t available while more than one installation shares the disk with macOS."
    public static let resetUnavailableReason =
      "These partitions don’t match an installation that can be reset."
    public static let partialResetReason = "An unfinished installation can only be erased."

    /// Builds the screen from the disk's regions and what the inventory
    /// admits: free extents by offset, containers that can shrink with the
    /// most they can give, and installations that can be reset.
    public init(
      layout: NativeDiskLayout,
      freeSpaceOffsets: Set<UInt64>,
      shrinkableBytes: [String: UInt64],
      resettableSources: Set<String>,
      icon: (NativeDiskLayout.Region) -> RowIcon
    ) {
      var segments = [Segment]()
      var rows = [Row]()
      var options = [Option]()
      let regions = layout.regions
      let macOSCount = regions.filter { $0.kind == .macOS }.count
      func label(_ region: NativeDiskLayout.Region?) -> String? {
        guard let region else { return nil }
        switch region.kind {
        case .free, .appleSystem: return nil
        default: return region.name
        }
      }
      for (index, region) in regions.enumerated() {
        let id = region.identifier ?? "free@\(region.offsetBytes)"
        switch region.kind {
        case .macOS:
          let free = min(region.freeBytes ?? 0, region.lengthBytes)
          segments.append(
            Segment(
              id: id, kind: .macOS, name: region.name, bytes: region.lengthBytes,
              usedBytes: region.lengthBytes - free))
          var shrink: InstallerPlanTarget?
          if let identifier = region.identifier, free >= Self.shrinkOfferedFreeBytes,
            let shrinkable = shrinkableBytes[identifier], shrinkable > 0
          {
            let target = InstallerPlanTarget.shrink(sourceIdentifier: identifier)
            shrink = target
            let following = index + 1 < regions.count ? regions[index + 1] : nil
            let adjacent = following?.kind == .free ? following?.lengthBytes : nil
            let maximum = min(free - Self.macOSKeepsFreeBytes, shrinkable)
            var detail =
              "\(region.name) has \(PlainLanguage.bytes(free)) free and keeps \(PlainLanguage.bytes(Self.macOSKeepsFreeBytes)) of it for updates. You choose the exact size next."
            if let adjacent {
              detail +=
                " The \(PlainLanguage.bytes(adjacent)) free right after it can’t be added. It stays free."
            }
            options.append(
              Option(
                kind: .shrink, target: target,
                title: macOSCount > 1 ? "Shrink \(region.name)" : "Shrink macOS",
                detail: detail, maximumBytes: maximum, adjacentFreeBytes: adjacent))
          }
          rows.append(
            Row(
              id: id, kind: .macOS, name: region.name, bytes: region.lengthBytes,
              icon: icon(region),
              erase: region.isRunningMacOS ? nil : eraseAvailability(region),
              eraseTarget: eraseTarget(region, index: index), shrink: shrink))
        case .linux:
          segments.append(
            Segment(
              id: id, kind: region.recognized ? .aurora : .otherLinux, name: region.name,
              bytes: region.lengthBytes))
          let erase = eraseAvailability(region)
          guard region.recognized else {
            rows.append(
              Row(
                id: id, kind: .otherLinux, name: region.name, bytes: region.lengthBytes,
                icon: icon(region), startupContainerUUID: region.uuid, erase: erase,
                eraseTarget: eraseTarget(region, index: index)))
            continue
          }
          let reset: Availability =
            region.partial
            ? .unavailable(Self.partialResetReason)
            : (region.identifier.map(resettableSources.contains) == true
              ? .available : .unavailable(Self.resetUnavailableReason))
          rows.append(
            Row(
              id: id, kind: .aurora, name: region.name, bytes: region.lengthBytes,
              icon: icon(region), startupContainerUUID: region.uuid, partial: region.partial,
              erase: erase, eraseTarget: eraseTarget(region, index: index), reset: reset))
        case .free:
          segments.append(Segment(id: id, kind: .free, name: "Free", bytes: region.lengthBytes))
          guard freeSpaceOffsets.contains(region.offsetBytes) else { continue }
          let before = index > 0 ? regions[index - 1] : nil
          let after = index + 1 < regions.count ? regions[index + 1] : nil
          let title: String
          let place: String
          switch (label(before), label(after)) {
          case (let first?, let second?):
            title = before?.kind == .macOS ? "Use the free space after \(first)" : "Use free space"
            place = "Between \(first) and \(second)."
          case (let first?, nil):
            title = before?.kind == .macOS ? "Use the free space after \(first)" : "Use free space"
            place = "After \(first)."
          case (nil, let second?):
            title = "Use free space"
            place = "Before \(second)."
          case (nil, nil):
            title = "Use free space"
            place = "Free space."
          }
          options.append(
            Option(
              kind: .freeSpace, target: .freeSpace(offsetBytes: region.offsetBytes),
              title: title, detail: place + " macOS isn’t changed.",
              maximumBytes: region.lengthBytes, adjacentFreeBytes: nil))
        case .appleSystem:
          segments.append(
            Segment(id: id, kind: .appleSystem, name: region.name, bytes: region.lengthBytes))
        case .other:
          segments.append(
            Segment(id: id, kind: .other, name: region.name, bytes: region.lengthBytes))
          // A partition no installation explains, such as another file
          // system: Erase may still make room from it.
          rows.append(
            Row(
              id: id, kind: .other, name: region.name, bytes: region.lengthBytes,
              icon: icon(region), erase: eraseAvailability(region),
              eraseTarget: eraseTarget(region, index: index)))
        }
      }
      func eraseAvailability(_ region: NativeDiskLayout.Region) -> Availability {
        region.isErasable
          ? .available : .unavailable(region.eraseRefusal ?? Self.eraseUnavailableReason)
      }
      func eraseTarget(_ region: NativeDiskLayout.Region, index: Int) -> EraseTarget? {
        guard region.isErasable, let anchor = region.memberUUIDs.first else { return nil }
        // The region's extent with the free space on either side, as the
        // partition map will show it once its partitions are gone.
        var freed = region.lengthBytes
        var before = index - 1
        while before >= 0, regions[before].kind == .free {
          freed += regions[before].lengthBytes
          before -= 1
        }
        var after = index + 1
        while after < regions.count, regions[after].kind == .free {
          freed += regions[after].lengthBytes
          after += 1
        }
        return EraseTarget(
          anchorUUID: anchor, memberUUIDs: region.memberUUIDs, name: region.name,
          bytes: region.lengthBytes, freedBytes: freed)
      }
      self.init(totalBytes: layout.diskBytes, segments: segments, rows: rows, options: options)
    }
  }
#endif

#if os(macOS)
  /// The Erase sheet's lines, before the removal service's own review.
  public enum EraseSheetText {
    public static func removes(_ row: DiskLayoutDisplay.Row) -> String {
      let size = PlainLanguage.bytes(row.bytes)
      if row.kind == .aurora {
        return "Removes its startup volume, EFI partition and Linux partitions (\(size))."
      }
      let count = row.eraseTarget?.memberUUIDs.count ?? 1
      return count == 1
        ? "Removes this partition (\(size))." : "Removes its \(count) partitions (\(size))."
    }

    public static func leaves(_ freedBytes: UInt64) -> String {
      "Leaves \(PlainLanguage.bytes(freedBytes)) free to install into. The macOS you’re running isn’t resized, and its files stay as they are."
    }
  }
#endif
