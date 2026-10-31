#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest

  @testable import AuroraInstallerUXCore

  /// A disk built region by region, as the inspector reports it.
  struct LayoutFixture {
    static let gb: UInt64 = 1_000_000_000
    var regions = [NativeDiskLayout.Region]()
    var offset: UInt64 = 24_576
    var number = 1
    var removable: String?

    init(startingWithAppleSystem: Bool = true) {
      if startingWithAppleSystem { add(.appleSystem, "Apple system", 524_288_000) }
    }

    @discardableResult
    mutating func add(
      _ kind: NativeDiskLayout.Kind, _ name: String, _ bytes: UInt64, free: UInt64? = nil,
      recognized: Bool = false, partial: Bool = false
    ) -> String {
      let identifier = kind == .free ? nil : "disk0s\(number)"
      if kind != .free { number += 1 }
      regions.append(
        NativeDiskLayout.Region(
          kind: kind, identifier: identifier, uuid: identifier.map { "uuid-\($0)" },
          offsetBytes: offset, lengthBytes: bytes, name: name, freeBytes: free,
          recognized: recognized, partial: partial, isRunningMacOS: kind == .macOS && number == 3))
      offset += bytes
      return identifier ?? "free@\(offset - bytes)"
    }

    func display(
      freeSpace: Set<UInt64>? = nil, shrinkable: [String: UInt64]? = nil,
      resettable: Set<String>? = nil
    ) -> DiskLayoutDisplay {
      var shrink = [String: UInt64]()
      for region in regions where region.kind == .macOS {
        if let id = region.identifier, let free = region.freeBytes,
          free > PlanDisplay.recommendedMacOSFreeBytes
        {
          shrink[id] = free - PlanDisplay.recommendedMacOSFreeBytes
        }
      }
      return DiskLayoutDisplay(
        layout: NativeDiskLayout(
          diskBytes: offset + 5_368_709_120, regions: regions + [recovery],
          removableStartupContainerUUID: removable),
        freeSpaceOffsets: freeSpace
          ?? Set(regions.filter { $0.kind == .free }.map(\.offsetBytes)),
        shrinkableBytes: shrinkable ?? shrink,
        resettableSources: resettable
          ?? Set(regions.filter { $0.recognized }.compactMap(\.identifier)),
        icon: { $0.recognized ? .auroraVolume : .internalDrive })
    }

    private var recovery: NativeDiskLayout.Region {
      NativeDiskLayout.Region(
        kind: .appleSystem, identifier: "disk0s99", offsetBytes: offset,
        lengthBytes: 5_368_709_120, name: "Recovery")
    }

    /// Two Aurora installations, free space between them, then Asahi.
    static func mixed() -> LayoutFixture {
      var disk = LayoutFixture()
      disk.add(.macOS, "Macintosh HD", 260 * gb, free: 110 * gb)
      disk.add(.linux, "Aurora Fedora Remix", 80 * gb, recognized: true)
      disk.add(.free, "Free", 36 * gb)
      disk.add(.linux, "Aurora Alarm", 48 * gb, recognized: true)
      disk.add(.linux, "Fedora Linux with KDE Plasma", 64 * gb)
      return disk
    }
  }

  final class DiskLayoutDisplayTests: XCTestCase {
    private let gb = LayoutFixture.gb

    func testEveryInstallationIsListedInDiskOrderWithItsActions() {
      let layout = LayoutFixture.mixed().display()
      XCTAssertEqual(
        layout.rows.map(\.name),
        ["Macintosh HD", "Aurora Fedora Remix", "Aurora Alarm", "Fedora Linux with KDE Plasma"])
      XCTAssertEqual(layout.rows.map(\.kind), [.macOS, .aurora, .aurora, .otherLinux])
      XCTAssertEqual(layout.rows[1].detail, "80 GB")
      XCTAssertEqual(layout.rows[1].icon, .auroraVolume)
      XCTAssertEqual(layout.rows[3].icon, .internalDrive)
      // Linux this installer can't prove it made has no actions at all.
      XCTAssertNil(layout.rows[3].erase)
      XCTAssertNil(layout.rows[3].reset)
      XCTAssertNil(layout.rows[3].shrink)
      // Each Aurora row can be reset; with several installations the removal
      // service erases none of them, and the row says why.
      for row in layout.rows where row.kind == .aurora {
        XCTAssertEqual(row.reset, .available)
        XCTAssertEqual(row.erase, .unavailable(DiskLayoutDisplay.eraseUnavailableReason))
      }
      XCTAssertEqual(
        layout.segments.map(\.kind),
        [.appleSystem, .macOS, .aurora, .free, .aurora, .otherLinux, .appleSystem])
      XCTAssertEqual(layout.segments[1].usedBytes, 150 * gb)
      XCTAssertTrue(layout.isComplex)
    }

    func testShrinkIsOfferedFromFiftyGigabytesFreeAndAlwaysKeepsThirtyEight() {
      for (free, offered) in [(49_999_999_999, false), (50_000_000_000, true), (110 * gb, true)]
        as [(UInt64, Bool)]
      {
        var disk = LayoutFixture()
        let macOS = disk.add(.macOS, "Macintosh HD", 400 * gb, free: free)
        disk.add(.linux, "Aurora Alarm", 48 * gb, recognized: true)
        let layout = disk.display()
        let target = InstallerPlanTarget.shrink(sourceIdentifier: macOS)
        XCTAssertEqual(layout.rows[0].shrink, offered ? target : nil, "\(free)")
        XCTAssertEqual(layout.option(for: target) != nil, offered)
        if offered {
          XCTAssertEqual(layout.option(for: target)?.maximumBytes, free - 38 * gb)
          XCTAssertEqual(layout.option(for: target)?.title, "Shrink macOS")
        }
      }
      // The engine's own floor can only lower what is offered.
      var disk = LayoutFixture()
      let macOS = disk.add(.macOS, "Macintosh HD", 400 * gb, free: 110 * gb)
      disk.add(.linux, "Aurora Alarm", 48 * gb, recognized: true)
      let capped = disk.display(shrinkable: [macOS: 20 * gb])
      XCTAssertEqual(capped.options.first?.maximumBytes, 20 * gb)
      // A container the inventory won't resize offers nothing.
      XCTAssertNil(disk.display(shrinkable: [:]).rows[0].shrink)
    }

    func testFreeSpaceRightAfterMacOSIsSeparateFromShrinkingIt() {
      var disk = LayoutFixture()
      let macOS = disk.add(.macOS, "Macintosh HD", 300 * gb, free: 92 * gb)
      let gap = disk.offset
      disk.add(.free, "Free", 60 * gb)
      disk.add(.linux, "Aurora Fedora Remix", 128 * gb, recognized: true)
      let layout = disk.display()
      XCTAssertEqual(layout.options.map(\.kind), [.shrink, .freeSpace])
      let shrink = try! XCTUnwrap(layout.option(for: .shrink(sourceIdentifier: macOS)))
      // Planning can't add the adjacent free space to a shrink: the option
      // says so and offers only what shrinking gives.
      XCTAssertEqual(shrink.adjacentFreeBytes, 60 * gb)
      XCTAssertEqual(shrink.maximumBytes, 54 * gb)
      XCTAssertEqual(shrink.sizeText, "up to 54 GB")
      XCTAssertTrue(shrink.detail.contains("60 GB free right after it can’t be added"))
      let free = try! XCTUnwrap(layout.option(for: .freeSpace(offsetBytes: gap)))
      XCTAssertEqual(free.title, "Use the free space after Macintosh HD")
      XCTAssertEqual(free.maximumBytes, 60 * gb)
      XCTAssertEqual(
        free.detail, "Between Macintosh HD and Aurora Fedora Remix. macOS isn’t changed.")
      // A lone installation is what the removal service erases.
      var erasable = disk
      erasable.removable = "uuid-disk0s3"
      XCTAssertEqual(erasable.display().rows[1].erase, .available)
    }

    func testTheScreenIsShownOnlyForAComplexLayout() {
      var single = LayoutFixture()
      single.add(.macOS, "Macintosh HD", 400 * gb, free: 200 * gb)
      XCTAssertFalse(single.display().isComplex)
      // Free space too small to install into isn't in the inventory.
      var tiny = single
      tiny.add(.free, "Free", 2 * gb)
      XCTAssertFalse(tiny.display(freeSpace: []).isComplex)
      XCTAssertTrue(tiny.display().isComplex)
      var linux = single
      linux.add(.linux, "Fedora Linux with KDE Plasma", 64 * gb)
      XCTAssertTrue(linux.display().isComplex)
      var two = single
      two.add(.macOS, "macOS Tahoe Beta", 188 * gb, free: 64 * gb)
      let layout = two.display()
      XCTAssertTrue(layout.isComplex)
      XCTAssertEqual(
        layout.options.map(\.title), ["Shrink Macintosh HD", "Shrink macOS Tahoe Beta"])
      XCTAssertEqual(layout.options.map(\.maximumBytes), [162 * gb, 26 * gb])
    }

    func testNoRoomExplainsWhatWouldMakeRoom() {
      var disk = LayoutFixture()
      disk.add(.macOS, "Macintosh HD", 300 * gb, free: 41 * gb)
      disk.add(.linux, "Aurora Fedora Remix", 128 * gb, recognized: true)
      disk.add(.linux, "Aurora Alarm", 60 * gb, recognized: true)
      let layout = disk.display()
      XCTAssertTrue(layout.options.isEmpty)
      XCTAssertEqual(
        layout.noRoomReason,
        "There’s no free space big enough, and Macintosh HD has 41 GB free. Erase an installation above, or free up space in macOS until it has more than 50 GB free."
      )
      XCTAssertNil(LayoutFixture.mixed().display().noRoomReason)
    }

    func testAnUnfinishedInstallationCanOnlyBeErased() {
      var disk = LayoutFixture()
      disk.add(.macOS, "Macintosh HD", 300 * gb, free: 41 * gb)
      disk.add(.linux, "Aurora Alarm", 6 * gb, recognized: true, partial: true)
      disk.removable = "uuid-disk0s3"
      let row = disk.display().rows[1]
      XCTAssertEqual(row.erase, .available)
      XCTAssertEqual(row.reset, .unavailable(DiskLayoutDisplay.partialResetReason))
      XCTAssertEqual(row.detail, "6 GB · unfinished installation")
    }

    func testErasingGrowsMacOSOverTheFreedSpaceUpToTheNextKeptPartition() {
      var disk = LayoutFixture()
      disk.add(.macOS, "Macintosh HD", 300 * gb, free: 92 * gb)
      disk.add(.free, "Free", 60 * gb)
      let aurora = disk.add(.linux, "Aurora Fedora Remix", 128 * gb, recognized: true)
      disk.removable = "uuid-disk0s3"
      let layout = disk.display()
      let after = try! XCTUnwrap(layout.afterErasing(aurora))
      XCTAssertEqual(after.map(\.kind), [.appleSystem, .macOS, .appleSystem])
      XCTAssertEqual(after[1].bytes, 488 * gb)
      XCTAssertEqual(after[1].usedBytes, 208 * gb)
      XCTAssertEqual(layout.macOSGrowthAfterErasing(aurora), 188 * gb)
      // Rows Erase doesn't apply to have no after view.
      XCTAssertNil(LayoutFixture.mixed().display().afterErasing("disk0s3"))
    }
  }
#endif
