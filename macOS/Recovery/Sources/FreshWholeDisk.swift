import Foundation

/// A fresh whole-disk installation from recoveryOS: macOS goes first, then
/// Aurora is laid out once in the space it leaves, directly after Apple's
/// iSC and before Apple's System Recovery:
///
///     [iSC][Aurora startup container][EFI][Boot][Root ... ][System Recovery]
///
/// Nothing is moved or resized afterwards and the root is one partition.
///
/// This file is the pure part. It decides from one reading of the disk what
/// goes and where each new partition lands, says which step comes next on any
/// later reading (so an interrupted installation resumes and never repeats a
/// destructive step), and checks the final layout. It runs no commands, so the
/// same rules are tested without a Mac (`Tests/FreshWholeDiskCheck.swift`)
/// and replayed on disk images (`tools/whole-disk/fresh-image-test.py`).
///
/// It only accepts a disk that holds Apple's iSC, exactly one macOS and
/// Apple's System Recovery, with nothing else, or the same disk part way
/// through this installation. Any other partition refuses: this path is for a
/// fresh Mac. A Mac that already has Aurora uses Remove macOS instead.

/// What the release asks for, from the OS package's metadata and the
/// startup firmware choice. Every size is a multiple of `unit`.
struct FreshWholeDiskRequest: Equatable {
  /// The startup container (stub), from the firmware choice.
  let stubBytes: UInt64
  /// The EFI partition, Boot and the smallest Root the package allows.
  let espBytes: UInt64
  let bootBytes: UInt64
  let rootMinimumBytes: UInt64
  /// The APFS label of the startup container, e.g. `Aurora`.
  let label: String

  /// The release's sizes are whole multiples of this, as the installer's own
  /// partition plan requires.
  static let unit: UInt64 = 1 << 20
  /// Partitions start and end on the disk's 4 KiB blocks. Apple's own iSC
  /// ends on one (not on a MiB), and diskutil places each new partition right
  /// after its predecessor, so every new partition starts on one too.
  static let block: UInt64 = 4096
}

enum FreshWholeDiskRole: String, Equatable, CaseIterable {
  case stub, esp, boot, root

  /// The partition type diskutil reports for it.
  var type: String {
    switch self {
    case .stub: return "Apple_APFS"
    case .esp: return "EFI"
    case .boot, .root: return "Linux Filesystem"
    }
  }
}

struct FreshWholeDiskRow: Equatable {
  let role: FreshWholeDiskRole
  let offset: UInt64
  let size: UInt64
  var end: UInt64 { offset + size }
}

struct FreshWholeDiskPlan: Equatable {
  let disk: String
  let isc: WholeDiskPartition
  let systemRecovery: WholeDiskPartition
  /// The macOS container to delete, or nil when it is already gone (a
  /// resumed installation).
  let macOS: WholeDiskContainer?
  let macOSPartition: WholeDiskPartition?
  /// The space between iSC and System Recovery that Aurora fills.
  let extentOffset: UInt64
  let extentSize: UInt64
  /// In disk order: stub, EFI, Boot, Root. Root ends at System Recovery.
  let rows: [FreshWholeDiskRow]
}

struct FreshWholeDiskRefusal: Error, LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// Where an installation stands on a given reading of the disk.
enum FreshWholeDiskStep: Equatable {
  /// macOS is still there: delete its container (the only destructive step
  /// for existing data, so it needs the typed phrase).
  case removeMacOS
  /// Create the partition of this role right after `predecessor`.
  case create(FreshWholeDiskRole, predecessor: String)
  /// Every partition is there and in place.
  case laidOut
}

enum FreshWholeDisk {
  /// Typed in full before macOS goes, as for Remove macOS.
  static let phrase = MacOSRemoval.phrase

  private static func refuse(_ message: String) -> FreshWholeDiskRefusal {
    FreshWholeDiskRefusal(message: message)
  }

  /// The Apple containers at both ends, checked the same way as Remove macOS.
  private static func ends(_ parts: [WholeDiskPartition]) throws -> (
    WholeDiskPartition, WholeDiskPartition
  ) {
    guard let first = parts.first, let last = parts.last, parts.count >= 2 else {
      throw refuse("This disk doesn’t have the layout of an Apple silicon Mac. Nothing was changed.")
    }
    for (a, b) in zip(parts, parts.dropFirst()) where a.end > b.offset {
      throw refuse("Partitions \(a.identifier) and \(b.identifier) overlap. Nothing was changed.")
    }
    guard first.type == "Apple_APFS_ISC" else {
      throw refuse("The first partition isn’t Apple’s system container (iSC). Nothing was changed.")
    }
    guard last.type == "Apple_APFS_Recovery" else {
      throw refuse("The last partition isn’t Apple’s System Recovery. Nothing was changed.")
    }
    guard
      parts.filter({ $0.type == "Apple_APFS_ISC" }).count == 1,
      parts.filter({ $0.type == "Apple_APFS_Recovery" }).count == 1
    else {
      throw refuse(
        "This disk has more than one Apple system or Recovery container. Nothing was changed.")
    }
    return (first, last)
  }

  /// The rows for the space between iSC and System Recovery.
  static func rows(extentOffset: UInt64, extentSize: UInt64, request: FreshWholeDiskRequest)
    throws -> [FreshWholeDiskRow]
  {
    let unit = FreshWholeDiskRequest.unit
    for size in [request.stubBytes, request.espBytes, request.bootBytes, request.rootMinimumBytes]
    where size == 0 || size % unit != 0 {
      throw refuse("The release’s partition sizes aren’t usable on this disk. Nothing was changed.")
    }
    // The stub starts where iSC ends and the root ends exactly where System
    // Recovery starts. Both are on the disk's 4 KiB blocks on every Mac.
    let block = FreshWholeDiskRequest.block
    guard extentOffset % block == 0, extentSize % block == 0 else {
      throw refuse(
        "The space between Apple’s containers isn’t on 4 KiB blocks. Nothing was changed.")
    }
    let sizes = [request.stubBytes, request.espBytes, request.bootBytes, request.rootMinimumBytes]
    guard sizes.allSatisfy({ $0 <= extentSize }) else {
      throw refuse("The release’s partitions don’t fit this disk. Nothing was changed.")
    }
    let fixed = request.stubBytes + request.espBytes + request.bootBytes
    guard extentSize >= fixed + request.rootMinimumBytes else {
      func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
      throw refuse(
        "Aurora needs \(gb(fixed + request.rootMinimumBytes)) and the disk has \(gb(extentSize)) between Apple’s containers. Nothing was changed."
      )
    }
    var rows = [FreshWholeDiskRow]()
    var at = extentOffset
    for (role, size) in [
      (FreshWholeDiskRole.stub, request.stubBytes), (.esp, request.espBytes),
      (.boot, request.bootBytes),
    ] {
      rows.append(FreshWholeDiskRow(role: role, offset: at, size: size))
      at += size
    }
    rows.append(FreshWholeDiskRow(role: .root, offset: at, size: extentOffset + extentSize - at))
    return rows
  }

  /// Plans from one reading of the disk. Accepted, between Apple's iSC and
  /// System Recovery:
  /// - exactly one full macOS and nothing else (a Mac as it was sold or set
  ///   up): macOS goes, then Aurora fills the space;
  /// - nothing at all (macOS already gone): Aurora fills the space;
  /// - the first partitions of this same layout, in place (an installation
  ///   that stopped part way, even without its journal).
  /// Anything else refuses.
  static func plan(_ layout: WholeDiskLayout, request: FreshWholeDiskRequest) throws
    -> FreshWholeDiskPlan
  {
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    let (isc, recovery) = try ends(parts)
    let middle = Array(parts.dropFirst().dropLast())
    // macOS goes with the free space either side of it: Aurora gets
    // everything between the two Apple containers.
    let extentOffset = isc.end
    let extentSize = recovery.offset - isc.end
    let rows = try rows(extentOffset: extentOffset, extentSize: extentSize, request: request)
    if middle.count == 1, let part = middle.first, part.type == "Apple_APFS",
      !(part.offset == rows[0].offset && part.size == rows[0].size)
    {
      let found = layout.containers.filter { $0.storeUUID == part.uuid }
      guard found.count == 1 else {
        throw refuse(
          "\(part.identifier) couldn’t be listed as one APFS container, so its contents can’t be reviewed. Nothing was changed."
        )
      }
      let macOS = found[0]
      guard macOS.looksLikeMacOS else {
        throw refuse(
          "\(part.identifier) isn’t a macOS container. A fresh whole-disk installation needs a Mac with only macOS. Nothing was changed."
        )
      }
      if let problem = macOS.macOSProblem {
        throw refuse(
          "\(part.identifier) holds macOS together with something else: \(problem). Deleting it would delete every volume in it, so nothing was changed."
        )
      }
      return FreshWholeDiskPlan(
        disk: layout.disk, isc: isc, systemRecovery: recovery, macOS: macOS,
        macOSPartition: part, extentOffset: extentOffset, extentSize: extentSize, rows: rows)
    }
    let plan = FreshWholeDiskPlan(
      disk: layout.disk, isc: isc, systemRecovery: recovery, macOS: nil, macOSPartition: nil,
      extentOffset: extentOffset, extentSize: extentSize, rows: rows)
    do {
      _ = try next(plan, now: layout)
    } catch {
      throw refuse(
        "This disk holds more than macOS between Apple’s containers (\(middle.map(\.identifier).joined(separator: ", "))). A fresh whole-disk installation needs a Mac with only macOS; a Mac with Aurora already installed uses Remove macOS instead. Nothing was changed."
      )
    }
    return plan
  }

  /// A second reading before macOS is deleted must plan exactly the same.
  static func requireUnchanged(
    _ reviewed: FreshWholeDiskPlan, now layout: WholeDiskLayout, request: FreshWholeDiskRequest
  ) throws {
    guard try plan(layout, request: request) == reviewed else {
      throw refuse("The disk changed since it was reviewed. Nothing was changed; review it again.")
    }
  }

  /// The step this reading of the disk calls for. The two Apple containers
  /// must be exactly as planned; the rows already made must be exactly as
  /// planned, in order, with nothing after them. Anything else refuses.
  static func next(_ plan: FreshWholeDiskPlan, now layout: WholeDiskLayout) throws
    -> FreshWholeDiskStep
  {
    guard layout.disk == plan.disk else {
      throw refuse("The internal disk changed identity. Nothing more was changed.")
    }
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    let (isc, recovery) = try ends(parts)
    func same(_ a: WholeDiskPartition, _ b: WholeDiskPartition) -> Bool {
      a.uuid == b.uuid && a.type == b.type && a.offset == b.offset && a.size == b.size
    }
    guard same(isc, plan.isc), same(recovery, plan.systemRecovery) else {
      throw refuse(
        "Apple’s system container or System Recovery changed. Nothing more was changed; save the Installer Log."
      )
    }
    let middle = Array(parts.dropFirst().dropLast())
    if let macOSPartition = plan.macOSPartition, middle.contains(where: { same($0, macOSPartition) })
    {
      guard middle.count == 1,
        layout.containers.contains(where: { $0.uuid == plan.macOS?.uuid })
      else { throw refuse("The disk changed around macOS. Nothing more was changed.") }
      return .removeMacOS
    }
    if let macOSPartition = plan.macOSPartition,
      middle.contains(where: { $0.uuid == macOSPartition.uuid })
    {
      throw refuse("The disk changed since it was reviewed. Nothing was changed; review it again.")
    }
    if let macOS = plan.macOS, layout.containers.contains(where: { $0.uuid == macOS.uuid }) {
      throw refuse(
        "The macOS container is half there. Nothing more was changed; save the Installer Log.")
    }
    guard middle.count <= plan.rows.count else {
      throw refuse("The disk has partitions this installation didn’t plan. Nothing more was changed.")
    }
    for (made, row) in zip(middle, plan.rows) {
      guard made.type == row.role.type, made.offset == row.offset, made.size == row.size else {
        throw refuse(
          "\(made.identifier) isn’t where this installation planned its \(row.role.rawValue) partition. Nothing more was changed."
        )
      }
      // A startup container made here holds no macOS (no Update volume).
      if row.role == .stub,
        layout.containers.contains(where: { $0.storeUUID == made.uuid && $0.looksLikeMacOS })
      {
        throw refuse(
          "\(made.identifier) holds a macOS, not this installation’s startup container. Nothing more was changed."
        )
      }
    }
    guard middle.count < plan.rows.count else { return .laidOut }
    let predecessor = middle.last?.identifier ?? isc.identifier
    return .create(plan.rows[middle.count].role, predecessor: predecessor)
  }

  /// After the last step: every row is there, in place, and the Apple
  /// containers are untouched. Returns the new partitions by role.
  static func verifyLaidOut(_ plan: FreshWholeDiskPlan, after layout: WholeDiskLayout) throws
    -> [FreshWholeDiskRole: WholeDiskPartition]
  {
    guard try next(plan, now: layout) == .laidOut else {
      throw refuse("The installation’s partitions aren’t all there yet.")
    }
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    let middle = Array(parts.dropFirst().dropLast())
    guard middle.last?.end == plan.systemRecovery.offset, middle.first?.offset == plan.isc.end
    else {
      throw refuse("The installation doesn’t fill the space between Apple’s containers.")
    }
    for (a, b) in zip(middle, middle.dropFirst()) where a.end != b.offset {
      throw refuse("There is a gap between \(a.identifier) and \(b.identifier).")
    }
    return Dictionary(uniqueKeysWithValues: zip(plan.rows.map(\.role), middle))
  }

  /// What the person is told before typing the phrase.
  static func consequences() -> String {
    """
    This deletes macOS, its apps, its users and every file in it, for good. After this:
      - Aurora is the only system on this Mac. Its startup container, EFI, Boot and Root
        partitions are made in the space macOS used, between Apple's iSC and System Recovery.
      - Apple's macOS and firmware updates no longer arrive by themselves. The Mac's
        system firmware stays at its current version.
      - The Mac has no macOS user any more. Aurora's own Recovery sets up the account
        that owns this Mac's startup security when you first start it.
      - To get macOS back you erase the Mac in DFU mode (a second Mac with Finder or
        Apple Configurator, or a Linux computer with idevicerestore) and restore it.
    """
  }

  /// What the review screen and `--dry-run` print.
  static func describe(_ plan: FreshWholeDiskPlan) -> String {
    func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
    var lines = [String]()
    if let part = plan.macOSPartition, let macOS = plan.macOS {
      lines.append("WILL BE DELETED, with all its data:")
      lines.append(
        "  \(part.identifier)  \(gb(part.size))  APFS container \(macOS.uuid) (partition \(part.uuid))"
      )
      for v in macOS.volumes.sorted(by: { $0.name < $1.name }) {
        lines.append("    volume “\(v.name)” (\(v.roles.joined(separator: ", ")))")
      }
    }
    lines.append("KEPT, unchanged:")
    lines.append(
      "  \(plan.isc.identifier)  \(gb(plan.isc.size))  Apple system container (iSC: LocalPolicy, xART, Hardware)"
    )
    lines.append("  \(plan.systemRecovery.identifier)  \(gb(plan.systemRecovery.size))  Apple System Recovery")
    lines.append("CREATED, in this order after the iSC:")
    let names: [FreshWholeDiskRole: String] = [
      .stub: "Aurora startup container and its Recovery", .esp: "EFI partition",
      .boot: "Linux /boot", .root: "Linux root, up to System Recovery",
    ]
    for row in plan.rows {
      lines.append("  \(gb(row.size))  at byte offset \(row.offset)  \(names[row.role]!)")
    }
    return lines.joined(separator: "\n")
  }

  /// The diskutil arguments for one creation step. diskutil puts the new
  /// partition right after `predecessor`, in the free space that follows it.
  static func createArguments(
    _ role: FreshWholeDiskRole, predecessor: String, plan: FreshWholeDiskPlan,
    request: FreshWholeDiskRequest
  ) -> [String] {
    let row = plan.rows.first { $0.role == role }!
    switch role {
    case .stub:
      return ["addPartition", predecessor, "apfs", request.label, String(row.size)]
    case .esp:
      return ["addPartition", predecessor, "%EFI%", "%noformat%", String(row.size)]
    case .boot, .root:
      return ["addPartition", predecessor, "%Linux%", "%noformat%", String(row.size)]
    }
  }

  /// The record for the EFI partition at `aurora/whole-disk/fresh.json`,
  /// telling Linux the layout is final and there is nothing to claim. The
  /// stage that fills the EFI partition writes it; the disk stage doesn't.
  static func linuxRecord(_ plan: FreshWholeDiskPlan, parts: [FreshWholeDiskRole: WholeDiskPartition], at: Date)
    -> [String: Any]
  {
    var record: [String: Any] = [
      "schema": 1, "layout": "fresh-whole-disk",
      "installedAt": ISO8601DateFormatter().string(from: at),
    ]
    for (role, part) in parts {
      record[role.rawValue + "PartitionUUID"] = part.uuid
    }
    if let removed = plan.macOSPartition { record["removedPartitionUUID"] = removed.uuid }
    return record
  }
}
