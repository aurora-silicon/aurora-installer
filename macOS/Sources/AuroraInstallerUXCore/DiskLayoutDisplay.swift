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

    public struct Row: Equatable, Sendable, Identifiable {
      public enum Kind: String, Equatable, Sendable { case macOS, aurora, otherLinux }

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
      /// Aurora installations only.
      public let erase: Availability?
      /// Aurora installations only: the preserved Stage 1 reinstall.
      public let reset: Availability?
      /// macOS only, when it has room to give.
      public let shrink: InstallerPlanTarget?

      public init(
        id: String, kind: Kind, name: String, bytes: UInt64, icon: RowIcon,
        startupContainerUUID: String? = nil, partial: Bool = false, erase: Availability? = nil,
        reset: Availability? = nil, shrink: InstallerPlanTarget? = nil
      ) {
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
        "There’s no free space big enough, and \(space). Erase an installation above, or free up space in macOS until it has more than \(PlainLanguage.bytes(Self.shrinkOfferedFreeBytes)) free."
    }

    /// The same disk once this row's installation is erased, as the removal
    /// service does it: macOS grows over the freed space up to the next
    /// partition it keeps. Nil for a row Erase does not apply to.
    public func afterErasing(_ rowID: String) -> [Segment]? {
      guard let erased = segments.firstIndex(where: { $0.id == rowID }),
        rows.first(where: { $0.id == rowID })?.erase?.isAvailable == true,
        let macOS = segments.firstIndex(where: { $0.kind == .macOS })
      else { return nil }
      var result = segments
      result[erased] = Segment(
        id: "erased:\(rowID)", kind: .free, name: "Free", bytes: segments[erased].bytes)
      var grown = result[macOS].bytes
      var next = macOS + 1
      while next < result.count, result[next].kind == .free {
        grown += result[next].bytes
        result.remove(at: next)
      }
      let old = result[macOS]
      result[macOS] = Segment(
        id: old.id, kind: .macOS, name: old.name, bytes: grown, usedBytes: old.usedBytes)
      return result
    }

    /// What the macOS that grows after Erase gains, for the sheet's summary.
    public func macOSGrowthAfterErasing(_ rowID: String) -> UInt64? {
      guard let after = afterErasing(rowID),
        let before = segments.first(where: { $0.kind == .macOS }),
        let grown = after.first(where: { $0.id == before.id })
      else { return nil }
      return grown.bytes - before.bytes
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
      "Erase isn’t available yet while more than one installation shares the disk with macOS."
    public static let resetUnavailableReason =
      "Its partitions don’t match an installation that can be reset."
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
                " The \(PlainLanguage.bytes(adjacent)) free right after it can’t be added to this space; it stays free."
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
              icon: icon(region), shrink: shrink))
        case .linux:
          segments.append(
            Segment(
              id: id, kind: region.recognized ? .aurora : .otherLinux, name: region.name,
              bytes: region.lengthBytes))
          guard region.recognized else {
            rows.append(
              Row(
                id: id, kind: .otherLinux, name: region.name, bytes: region.lengthBytes,
                icon: icon(region)))
            continue
          }
          let erase: Availability =
            region.uuid != nil && region.uuid == layout.removableStartupContainerUUID
            ? .available : .unavailable(Self.eraseUnavailableReason)
          let reset: Availability =
            region.partial
            ? .unavailable(Self.partialResetReason)
            : (region.identifier.map(resettableSources.contains) == true
              ? .available : .unavailable(Self.resetUnavailableReason))
          rows.append(
            Row(
              id: id, kind: .aurora, name: region.name, bytes: region.lengthBytes,
              icon: icon(region), startupContainerUUID: region.uuid, partial: region.partial,
              erase: erase, reset: reset))
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
            place = "Unallocated space."
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
        }
      }
      self.init(totalBytes: layout.diskBytes, segments: segments, rows: rows, options: options)
    }
  }
#endif
