import Foundation

/// The container growth of an "in-place-grow" upgrade (UPGRADE-FLOW.md
/// section 4.2 step 1): Linux moved the EFI partition from right after the
/// stub's APFS container into free space elsewhere, keeping its partition
/// entry and PARTUUID; before any file is written, Recovery checks that the
/// partition really is at its new place and that its old range, right after
/// the container, is free, then has diskutil grow the container into it
/// (`diskutil apfs resizeContainer <physical store> 0`), checks that it grew
/// to the size the plan names (within APFS's alignment) and records it in
/// the upgrade's journal, so a run again doesn't grow it twice.
public enum StubUpgradeGrow {
  public struct Partition: Equatable {
    public let bsdName: String
    /// The GPT partition UUID, lower case.
    public let uuid: String
    public let base: Int
    public let size: Int
    public init(bsdName: String, uuid: String, base: Int, size: Int) {
      self.bsdName = bsdName
      self.uuid = uuid.lowercased()
      self.base = base
      self.size = size
    }
  }

  /// The partitions of the stub's disk and the disk's size, in bytes.
  public struct Layout: Equatable {
    public let partitions: [Partition]
    public let diskSize: Int
    public init(partitions: [Partition], diskSize: Int) {
      self.partitions = partitions
      self.diskSize = diskSize
    }
  }

  public enum Refusal: Error, Equatable, LocalizedError {
    /// The EFI partition isn't where Linux said it moved it.
    case espNotMoved
    /// The container's physical store isn't on this disk.
    case noContainer
    /// Something other than free space follows the container.
    case notFree
    /// The free space after the container is smaller than the plan's.
    case smallerThanExpected
    /// diskutil returned, but the container isn't the plan's size.
    case didNotGrow(size: Int, want: Int)

    public var errorDescription: String? {
      switch self {
      case .espNotMoved:
        return
          "The EFI partition isn't where aurora-upgrade moved it. Run aurora-upgrade cancel in Linux, then stage again. Nothing was changed."
      case .noContainer:
        return "The startup container's partition wasn't found on this disk. Nothing was changed."
      case .notFree:
        return
          "The space after the startup container isn't free, so it can't grow into it. Nothing was changed."
      case .smallerThanExpected:
        return
          "The free space after the startup container is smaller than the upgrade planned. Nothing was changed."
      case .didNotGrow(let size, let want):
        return
          "The startup container is \(size / 1_000_000) MB after growing, not \(want / 1_000_000) MB. No file was written."
      }
    }
  }

  /// APFS and GPT keep partitions on 1 MiB (aurora-upgrade's ALIGN).
  public static let alignment = 1 << 20

  /// Whether a container of `size` bytes is the planned `want`.
  public static func grown(_ size: Int, want: Int) -> Bool { size > want - alignment }

  /// Checks `layout` before the container grows; true when it already has
  /// (a run stopped after diskutil and before the journal recorded it).
  public static func check(_ layout: Layout, store: String, request: StubUpgradeRequest) throws
    -> Bool
  {
    guard let move = request.espMove, let want = request.growContainerTo else {
      throw Refusal.notFree
    }
    let esp = layout.partitions.filter { $0.uuid == request.espPartitionUUID }
    guard esp.count == 1, esp[0].base == move.newStart, esp[0].size == move.size else {
      throw Refusal.espNotMoved
    }
    let found = layout.partitions.filter { $0.bsdName == store }
    guard found.count == 1 else { throw Refusal.noContainer }
    let container = found[0]
    let end = container.base + container.size
    let others = layout.partitions.filter { $0 != container }
    if grown(container.size, want: want) {
      guard others.allSatisfy({ $0.base + $0.size <= container.base || $0.base >= end }) else {
        throw Refusal.notFree
      }
      return true
    }
    // The container ends where the EFI partition started.
    guard end <= move.oldStart, move.oldStart - end < alignment else { throw Refusal.notFree }
    let limit = move.oldStart + move.size
    guard others.allSatisfy({ $0.base + $0.size <= end || $0.base >= limit }) else {
      throw Refusal.notFree
    }
    let next = min(others.filter { $0.base >= end }.map(\.base).min() ?? Int.max, layout.diskSize)
    guard next >= limit, container.base + want <= next + alignment else {
      throw Refusal.smallerThanExpected
    }
    return false
  }

  /// Grows the container once: checks, `resize`, checks the new size and
  /// records it in the journal at `url` (made only then, so a refusal
  /// leaves no trace). `layout` reads the disk; `resize` runs diskutil.
  public static func run(
    request: StubUpgradeRequest, store: String, journal url: URL,
    layout: () throws -> Layout, resize: () throws -> Void
  ) throws {
    guard request.mode == .inPlaceGrow else { return }
    func begin() throws -> RestoreImageStubUpgrade.Journal {
      try RestoreImageStubUpgrade.begin(
        url, planSHA256: request.planSHA256, group: request.group, build: request.target.build)
    }
    if try RestoreImageStubUpgrade.Journal.load(url) != nil, try begin().containerGrown == true {
      return
    }
    if try !check(layout(), store: store, request: request) {
      try resize()
      let after = try layout()
      let size = after.partitions.first { $0.bsdName == store }?.size ?? 0
      guard grown(size, want: request.growContainerTo ?? 0) else {
        throw Refusal.didNotGrow(size: size, want: request.growContainerTo ?? 0)
      }
    }
    var journal = try begin()
    journal.containerGrown = true
    try journal.save(url)
  }

  /// The order of an upgrade's disk work: for in-place-grow, the container
  /// grows first (`layout`, `resize`, recorded in the journal at `url`,
  /// without any volume tree being opened), then everything is checked again
  /// (`recheck`: the space above all), and only then does `write` open,
  /// check and write the volumes. An in-place upgrade goes straight to
  /// `recheck` and `write`. The request, pin and floor checks come before
  /// this (StubUpgradeCheck); nothing here runs if they refuse.
  public static func growThenWrite(
    request: StubUpgradeRequest, store: String, journal url: URL,
    layout: () throws -> Layout, resize: () throws -> Void, recheck: () throws -> Void,
    write: () throws -> RestoreImageStubUpgrade.Journal
  ) throws -> RestoreImageStubUpgrade.Journal {
    try run(request: request, store: store, journal: url, layout: layout, resize: resize)
    try recheck()
    return try write()
  }
}
