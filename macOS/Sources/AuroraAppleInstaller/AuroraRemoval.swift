#if os(macOS)
  import Foundation

  public enum AuroraRemovalKind: String, Codable, Equatable, Sendable {
    /// A startup container, its EFI partition and its Linux partitions.
    case installation
    /// No installation left; only unallocated space directly after macOS.
    case freeSpace
    /// One row of the Partitions screen: its partitions are deleted and
    /// their extent stays unallocated. macOS isn't resized.
    case eraseToFreeSpace
  }

  public struct AuroraRemovalItem: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let bytes: UInt64
    public init(title: String, detail: String, bytes: UInt64) {
      self.title = title
      self.detail = detail
      self.bytes = bytes
    }
  }

  /// The helper owns the disk plan. The client can only return this expiring ticket.
  public struct AuroraRemovalTicket: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: AuroraRemovalKind
    public let reclaimBytes: UInt64
    public let macOSBytesAfter: UInt64
    public let deletions: [AuroraRemovalItem]
    public let kept: [AuroraRemovalItem]
    public let notes: [String]
    /// Done before anything is deleted: macOS becomes the startup disk.
    public let startupDisk: AuroraRemovalItem?
    /// The partition UUID of the startup container this ticket deletes, so
    /// the app can refuse a ticket for another installation than the one
    /// the person chose. Nil for free space, and from older helpers.
    public let startupContainerUUID: String?
    /// Erase to free space only: every partition it deletes, in disk order,
    /// which must be exactly the row the person chose.
    public let erasedPartitionUUIDs: [String]?
    /// Erase to free space only: the unallocated extent left afterwards,
    /// including the free space it joins on either side.
    public let freedBytes: UInt64?
    public init(
      id: UUID, kind: AuroraRemovalKind = .installation, reclaimBytes: UInt64,
      macOSBytesAfter: UInt64, deletions: [AuroraRemovalItem] = [],
      kept: [AuroraRemovalItem] = [], notes: [String] = [],
      startupDisk: AuroraRemovalItem? = nil, startupContainerUUID: String? = nil,
      erasedPartitionUUIDs: [String]? = nil, freedBytes: UInt64? = nil
    ) {
      self.startupContainerUUID = startupContainerUUID
      self.erasedPartitionUUIDs = erasedPartitionUUIDs
      self.freedBytes = freedBytes
      self.id = id
      self.kind = kind
      self.reclaimBytes = reclaimBytes
      self.macOSBytesAfter = macOSBytesAfter
      self.deletions = deletions
      self.kept = kept
      self.notes = notes
      self.startupDisk = startupDisk
    }
    /// A helper older than the app sends tickets without the plan fields.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(UUID.self, forKey: .id)
      kind = try values.decodeIfPresent(AuroraRemovalKind.self, forKey: .kind) ?? .installation
      reclaimBytes = try values.decode(UInt64.self, forKey: .reclaimBytes)
      macOSBytesAfter = try values.decode(UInt64.self, forKey: .macOSBytesAfter)
      deletions = try values.decodeIfPresent([AuroraRemovalItem].self, forKey: .deletions) ?? []
      kept = try values.decodeIfPresent([AuroraRemovalItem].self, forKey: .kept) ?? []
      notes = try values.decodeIfPresent([String].self, forKey: .notes) ?? []
      startupDisk = try values.decodeIfPresent(AuroraRemovalItem.self, forKey: .startupDisk)
      startupContainerUUID = try values.decodeIfPresent(
        String.self, forKey: .startupContainerUUID)
      erasedPartitionUUIDs = try values.decodeIfPresent(
        [String].self, forKey: .erasedPartitionUUIDs)
      freedBytes = try values.decodeIfPresent(UInt64.self, forKey: .freedBytes)
    }
    public var confirmation: String {
      switch kind {
      case .freeSpace: Self.freeSpaceConfirmation
      case .eraseToFreeSpace: Self.eraseConfirmation
      case .installation: Self.confirmation
      }
    }
    public static let confirmation = "erase linux and its data"
    public static let freeSpaceConfirmation = "return free space to macos"
    public static let eraseConfirmation = "erase these partitions"

    /// Whether this ticket erases exactly the partitions the person chose.
    public func erases(exactly partitions: [String]) -> Bool {
      guard kind == .eraseToFreeSpace, let erased = erasedPartitionUUIDs else { return false }
      func normalized(_ values: [String]) -> Set<String> {
        Set(values.map { $0.uppercased() })
      }
      return erased.count == partitions.count && normalized(erased) == normalized(partitions)
    }
  }

  public struct AuroraRemovalReply: Codable, Sendable {
    public let ticket: AuroraRemovalTicket?
    public let completed: Bool
    public let requiresReview: Bool
    public let message: String
    public init(
      ticket: AuroraRemovalTicket? = nil, completed: Bool = false, requiresReview: Bool = false,
      message: String
    ) {
      self.ticket = ticket
      self.completed = completed
      self.requiresReview = requiresReview
      self.message = message
    }
  }

  struct RemovalFailure: LocalizedError, Sendable {
    let message: String
    /// The message already says what changed, so nothing is appended to it.
    var complete = false
    var errorDescription: String? { message }
  }

  /// bless didn't make the change. `reason` is its last output line, with
  /// the password removed.
  struct RemovalStartupRefusal: Error, Sendable {
    let reason: String
  }

  struct RemovalPartition: Codable, Equatable, Sendable {
    let identifier: String
    let uuid: String
    let type: String
    let offset: UInt64
    var size: UInt64
    let name: String
    var end: UInt64 { offset + size }
    // BSD identifiers can change after deleting another partition. Identity cannot.
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.uuid == rhs.uuid && lhs.type == rhs.type && lhs.offset == rhs.offset
        && lhs.size == rhs.size && lhs.name == rhs.name
    }
  }

  struct RemovalVolume: Codable, Equatable, Sendable {
    let uuid: String
    let name: String
    let roles: [String]
    let group: String?
    let identifier: String
    init(uuid: String, name: String, roles: [String], group: String? = nil, identifier: String = "")
    {
      self.uuid = uuid
      self.name = name
      self.roles = roles
      self.group = group
      self.identifier = identifier
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.uuid == rhs.uuid && lhs.name == rhs.name && lhs.roles == rhs.roles
        && lhs.group == rhs.group
    }
  }

  struct RemovalContainer: Codable, Equatable, Sendable {
    let uuid: String
    let storeUUID: String
    let volumes: [RemovalVolume]
  }

  struct RemovalSnapshot: Codable, Equatable, Sendable {
    let disk: String
    let devicePath: String
    let diskSize: UInt64
    let macOSStoreUUID: String
    let macOSContainerUUID: String
    var partitions: [RemovalPartition]
    var containers: [RemovalContainer]
  }

  /// One installation made by the Asahi installer engine: this app's own
  /// layout, older omarchy-mac installs and plain Asahi installs alike.
  struct RemovalInstallation: Codable, Equatable, Sendable {
    let name: String
    let stub: RemovalPartition
    let system: RemovalVolume
    let esp: RemovalPartition
    let linux: [RemovalPartition]
    var members: [RemovalPartition] { [stub, esp] + linux }

    /// The same partitions and volume with the BSD identifiers they have now.
    func live(in snapshot: RemovalSnapshot) -> RemovalInstallation? {
      func current(_ part: RemovalPartition) -> RemovalPartition? {
        snapshot.partitions.first { $0 == part }
      }
      guard let stub = current(stub), let esp = current(esp),
        let system = snapshot.containers.first(where: { $0.storeUUID == stub.uuid })?.volumes
          .first(where: { $0 == system })
      else { return nil }
      let linux = self.linux.compactMap(current)
      guard linux.count == self.linux.count else { return nil }
      return RemovalInstallation(name: name, stub: stub, system: system, esp: esp, linux: linux)
    }
  }

  /// The row Erase to free space deletes, as the plan was reviewed.
  struct RemovalErasedRegion: Codable, Equatable, Sendable {
    /// The row's first partition, which names it.
    let anchor: String
    let name: String
    let memberUUIDs: [String]
    /// The unallocated extent left afterwards, joined with its neighbours.
    let freedOffset: UInt64
    let freedBytes: UInt64

    /// The span the erased partitions covered.
    func extent(of members: [RemovalPartition]) -> Range<UInt64> {
      let start = members.map(\.offset).min() ?? freedOffset
      return start..<max(start, members.map(\.end).max() ?? start)
    }
  }

  enum RemovalStartup: Codable, Equatable, Sendable {
    case macOS
    case other(String)
    case nextStartupOverride
    case unknown
  }

  struct AuroraRemovalPlan: Codable, Equatable, Sendable {
    let kind: AuroraRemovalKind
    let snapshot: RemovalSnapshot
    let installation: RemovalInstallation?
    let evidence: RemovalEvidence?
    /// A fresh install that stopped after creating its startup container,
    /// proved by the installer's own journal.
    let partial: RemovalPartialInstallation?
    /// The binding of the native installer journal that proves `installation`
    /// is its own, when the asahi installer's files on it don't.
    let nativeJournal: String?
    let members: [RemovalPartition]
    let macOS: RemovalPartition
    let targetMacOSBytes: UInt64
    /// What the Mac started up from at review when that wasn't the running
    /// macOS. Execution sets macOS as the startup disk before deleting.
    let startup: RemovalStartup?
    /// Erase to free space only: the row the person chose.
    var erased: RemovalErasedRegion? = nil
    /// Stores of other operating systems' containers (iOS) on the disk,
    /// kept as they are. Nil when there are none.
    var preservedStores: [String]? = nil

    /// Read-only. Every check that can refuse happens here, before a ticket exists.
    /// - Parameter collect: inspection's read-only scan, which names another
    ///   operating system's container from its own System volume.
    init(
      disks: any RemovalDiskOperating, journals: (any RemovalInstallJournals)? = nil,
      collect: (() throws -> NativeCollectedDisk)? = nil
    ) throws {
      let snapshot = try disks.snapshot()
      self.snapshot = snapshot
      // Only a scan of this exact layout counts. When it fails, nothing is
      // preserved by name and recognition refuses the container as before.
      var preserved = Set<String>()
      if let collect, RemovalLayout.hasOtherSystem(snapshot), let disk = try? collect(),
        disk.snapshot == snapshot
      {
        preserved = disk.preservedForeignStores
      }
      preservedStores = preserved.isEmpty ? nil : preserved.sorted()
      switch try RemovalLayout.recognize(snapshot, preserved: preserved) {
      case .freeSpace(let macOS, let target):
        let limit = try disks.growLimit(macOS, disk: snapshot.disk)
        guard limit.addingReportingOverflow(1_048_576).partialValue >= target else {
          throw RemovalFailure(
            message: RemovalText.growthLimited(free: target - macOS.size, limit: limit))
        }
        kind = .freeSpace
        installation = nil
        evidence = nil
        partial = nil
        nativeJournal = nil
        members = []
        self.macOS = macOS
        targetMacOSBytes = target
        startup = nil
      case .installation(let found, let macOS, let target):
        let evidence: RemovalEvidence
        do { evidence = try disks.evidence(for: found, disk: snapshot.disk) } catch {
          let detail = (error as? RemovalFailure)?.message ?? "macOS couldn't read them"
          throw RemovalFailure(message: RemovalText.unreadable(found, detail: detail))
        }
        // The native installer writes neither asahi/installer.log nor an m1n1
        // step-2 object; its own journal is the proof for what it installed.
        var nativeJournal: String?
        if let reason = evidence.problem(for: found) {
          guard let journals, let journal = try journals.installer(of: found, in: snapshot) else {
            throw RemovalFailure(message: RemovalText.unconfirmed(found, reason: reason))
          }
          nativeJournal = journal
        }
        let startup = try disks.startup(snapshot)
        kind = .installation
        installation = found
        self.evidence = evidence
        partial = nil
        self.nativeJournal = nativeJournal
        members = found.members
        self.macOS = macOS
        targetMacOSBytes = target
        self.startup = startup == .macOS ? nil : startup
      case .partialInstallation(let stub, let macOS, let target, let refusal):
        guard let journals, let journal = try journals.creator(of: stub, in: snapshot) else {
          throw RemovalFailure(message: refusal)
        }
        let system = snapshot.containers.first { $0.storeUUID == stub.uuid }?.volumes
          .first { $0.roles == ["System"] }
        let startup = try disks.startup(snapshot)
        kind = .installation
        installation = nil
        evidence = nil
        nativeJournal = nil
        partial = RemovalPartialInstallation(
          name: system?.name ?? stub.name, stub: stub, journal: journal)
        members = [stub]
        self.macOS = macOS
        targetMacOSBytes = target
        self.startup = startup == .macOS ? nil : startup
      }
    }

    /// Erase to free space: deletes a row of the Partitions screen and
    /// leaves its extent unallocated. Read-only, like every plan: the shared
    /// erase rule refuses here, before a ticket exists.
    init(
      erasing anchor: String, disks: any RemovalDiskOperating,
      collect: () throws -> NativeCollectedDisk
    ) throws {
      let disk = try collect()
      let snapshot = disk.snapshot
      let region = try Self.erasableRegion(anchor, in: disk)
      let members = region.memberUUIDs.compactMap { uuid in
        snapshot.partitions.first { $0.uuid == uuid }
      }
      guard members.count == region.memberUUIDs.count,
        let macOS = snapshot.partitions.first(where: { $0.uuid == snapshot.macOSStoreUUID })
      else { throw RemovalFailure(message: RemovalText.eraseTargetGone) }
      self.snapshot = snapshot
      kind = .eraseToFreeSpace
      installation = nil
      evidence = nil
      partial = nil
      nativeJournal = nil
      // A container goes first: if one of its volumes is busy, diskutil
      // refuses before any other partition is touched.
      self.members =
        members.filter { $0.type == "Apple_APFS" } + members.filter { $0.type != "Apple_APFS" }
      self.macOS = macOS
      targetMacOSBytes = macOS.size
      let freed = NativePartitionErase.freedExtent(members: members, snapshot: snapshot)
      erased = RemovalErasedRegion(
        anchor: anchor.uppercased(), name: region.name, memberUUIDs: region.memberUUIDs,
        freedOffset: freed?.offset ?? region.offsetBytes,
        freedBytes: freed?.length ?? members.reduce(0) { $0 + $1.size })
      startup = try Self.erasedStartup(members: members, disks: disks, snapshot: snapshot)
    }

    /// What the Mac starts up from, when the erased row holds it. An unknown
    /// target counts as held when the row has a container.
    static func erasedStartup(
      members: [RemovalPartition], disks: any RemovalDiskOperating, snapshot: RemovalSnapshot
    ) throws -> RemovalStartup? {
      guard members.contains(where: { $0.type == "Apple_APFS" }) else { return nil }
      let startup = try disks.startup(snapshot)
      guard startup != .macOS else { return nil }
      if let stores = try disks.startupStores(snapshot),
        !stores.contains(where: { store in
          members.contains { $0.uuid.caseInsensitiveCompare(store) == .orderedSame }
        })
      {
        return nil
      }
      return startup
    }

    /// The row with this first partition, when Erase may delete it.
    static func erasableRegion(_ anchor: String, in disk: NativeCollectedDisk) throws
      -> NativeDiskLayout.Region
    {
      let layout: NativeDiskLayout
      do { layout = try NativeDiskLayout(disk) } catch {
        throw RemovalFailure(message: RemovalText.eraseUnreadable)
      }
      guard
        let region = layout.regions.first(where: {
          $0.uuid?.caseInsensitiveCompare(anchor) == .orderedSame
        }), [.macOS, .linux, .other].contains(region.kind), !region.isRunningMacOS
      else { throw RemovalFailure(message: RemovalText.eraseTargetGone) }
      if let refusal = region.eraseRefusal {
        throw RemovalFailure(message: refusal + " Nothing was changed.")
      }
      return region
    }

    /// Removal checks the startup disk before deleting, and sets macOS as it
    /// when it isn't.
    var setsMacOSStartupFirst: Bool { installation != nil || partial != nil }

    var reclaimBytes: UInt64 { targetMacOSBytes - macOS.size }

    /// False when another operating system's container sits between macOS
    /// and the installation: its space then stays unallocated.
    var growsMacOS: Bool { targetMacOSBytes > macOS.size }

    var summary: String {
      if let erased {
        let first = startup == nil ? "" : "Erase first sets macOS as the startup disk. "
        return
          "\(first)Erase permanently deletes “\(erased.name)” and everything stored in it. Its space becomes \(RemovalText.size(erased.freedBytes)) of unallocated free space that you can install into. macOS isn’t resized."
      }
      if let partial {
        let first = startup == nil ? "" : "Removal first sets macOS as the startup disk. "
        return
          "Found “\(partial.name)”, left by an installation that didn’t finish. \(first)Removal permanently deletes it and gives its space back to macOS."
      }
      if let installation, !growsMacOS {
        let first = startup == nil ? "" : "Removal first sets macOS as the startup disk, then "
        let deletes = startup == nil ? "Removal permanently deletes" : "permanently deletes"
        return
          "Found “\(installation.name)”. \(first)\(deletes) it and everything stored in it. Another operating system’s container sits between it and macOS, so its space is left unallocated and macOS isn’t resized."
      }
      if let installation {
        if startup != nil {
          return
            "Found “\(installation.name)”. Removal sets macOS as the startup disk, then permanently deletes “\(installation.name)” and everything in it, and gives its space back to macOS."
        }
        return
          "Found “\(installation.name)”. Removal permanently deletes it and everything in it, then gives its space back to macOS."
      }
      return
        "No installation found, but \(RemovalText.size(reclaimBytes)) after macOS is free. macOS can take it back. Nothing is deleted."
    }

    func ticket(id: UUID) -> AuroraRemovalTicket {
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      var deletions = [AuroraRemovalItem]()
      var notes = [String]()
      if let erased {
        for part in members.sorted(by: { $0.offset < $1.offset }) {
          deletions.append(RemovalText.erasedItem(part, snapshot))
        }
        let size = members.reduce(UInt64(0)) { $0 + $1.size }
        notes.append(
          erased.freedBytes > size
            ? "Its \(RemovalText.size(size)) joins the free space next to it, for \(RemovalText.size(erased.freedBytes)) free in all. macOS isn’t resized."
            : "Its \(RemovalText.size(erased.freedBytes)) is left free. macOS isn’t resized."
        )
      } else if let installation {
        deletions.append(
          AuroraRemovalItem(
            title: "Startup container “\(installation.name)”",
            detail: "\(installation.stub.identifier) · APFS", bytes: installation.stub.size))
        let espName = installation.esp.name.isEmpty ? "" : " “\(installation.esp.name)”"
        deletions.append(
          AuroraRemovalItem(
            title: "EFI partition\(espName)", detail: installation.esp.identifier,
            bytes: installation.esp.size))
        for part in installation.linux {
          deletions.append(
            AuroraRemovalItem(title: "Linux partition", detail: part.identifier, bytes: part.size))
        }
        if installation.linux.isEmpty {
          notes.append(
            "This installation has no Linux partitions of its own. A Linux system that starts through it (for example from an external disk) won’t start after removal. Its data isn’t touched."
          )
        }
      } else if let partial {
        deletions.append(
          AuroraRemovalItem(
            title: "Startup container “\(partial.name)”",
            detail: "\(partial.stub.identifier) · APFS · left by an unfinished installation",
            bytes: partial.stub.size))
        notes.append(
          "The installation stopped after it made this startup container. Nothing else is deleted."
        )
      } else {
        notes.append(
          "macOS takes all the unallocated space directly after it, whatever put it there.")
      }
      var kept = [
        AuroraRemovalItem(
          title: "macOS “\(macOSName)”",
          detail: growsMacOS
            ? "\(macOS.identifier) · grows to \(RemovalText.size(targetMacOSBytes))"
            : "\(macOS.identifier) · not resized",
          bytes: macOS.size),
        AuroraRemovalItem(
          title: "Apple system container", detail: parts[0].identifier, bytes: parts[0].size),
        AuroraRemovalItem(
          title: "Apple Recovery", detail: parts[parts.count - 1].identifier,
          bytes: parts[parts.count - 1].size),
      ]
      for part in parts
      where part.type == "Apple_APFS" && part.uuid != macOS.uuid
        && !members.contains(where: { $0.uuid == part.uuid })
      {
        let name =
          snapshot.containers.first { $0.storeUUID == part.uuid }?.volumes
          .first { $0.roles == ["System"] }?.name ?? part.name
        if preservedStores?.contains(part.uuid) == true {
          kept.append(
            AuroraRemovalItem(
              title: "Another operating system “\(name)”", detail: part.identifier,
              bytes: part.size))
          if erased == nil {
            notes.append(
              "“\(name)” holds another operating system (iOS) and is always kept. macOS never grows across it."
            )
          }
          continue
        }
        kept.append(
          AuroraRemovalItem(
            title: "Separate startup container “\(name)”", detail: part.identifier, bytes: part.size
          ))
        if erased == nil {
          notes.append(
            "The separate startup container “\(name)” is kept. macOS grows only up to it.")
        }
      }
      return AuroraRemovalTicket(
        id: id, kind: kind, reclaimBytes: reclaimBytes, macOSBytesAfter: targetMacOSBytes,
        deletions: deletions, kept: kept, notes: notes,
        startupDisk: startup.map {
          AuroraRemovalItem(
            title: "Set macOS “\(macOSName)” as the startup disk",
            detail: RemovalText.startupNow($0), bytes: 0)
        }, startupContainerUUID: installation?.stub.uuid ?? partial?.stub.uuid,
        erasedPartitionUUIDs: erased?.memberUUIDs, freedBytes: erased?.freedBytes)
    }

    var macOSName: String {
      snapshot.containers.first { $0.uuid == snapshot.macOSContainerUUID }?.volumes
        .first { $0.roles == ["System"] }?.name ?? "macOS"
    }

    /// Every intermediate state must be exactly the approved layout minus the
    /// partitions already removed. This also proves the gap is adjacent to macOS.
    func validate(_ current: RemovalSnapshot, removed: Set<String>, expanded: Bool = false) throws {
      guard current.disk == snapshot.disk, current.devicePath == snapshot.devicePath,
        current.diskSize == snapshot.diskSize, current.macOSStoreUUID == snapshot.macOSStoreUUID,
        current.macOSContainerUUID == snapshot.macOSContainerUUID
      else { throw RemovalFailure(message: "The disk identity changed. Removal stopped.") }
      var expected = snapshot.partitions.filter { !removed.contains($0.uuid) }
      if expanded {
        guard let actual = current.partitions.first(where: { $0.uuid == macOS.uuid }),
          actual.size > macOS.size, actual.size <= targetMacOSBytes,
          targetMacOSBytes - actual.size <= 1_048_576,
          let index = expected.firstIndex(where: { $0.uuid == macOS.uuid })
        else { throw RemovalFailure(message: "macOS did not reclaim the expected space.") }
        expected[index].size = actual.size
      }
      guard
        expected.sorted(by: { $0.offset < $1.offset })
          == current.partitions.sorted(by: { $0.offset < $1.offset }),
        snapshot.containers.filter({ !removed.contains($0.storeUUID) }).sorted(by: {
          $0.uuid < $1.uuid
        })
          == current.containers.sorted(by: { $0.uuid < $1.uuid })
      else {
        throw RemovalFailure(message: "The disk changed. Removal stopped.")
      }
    }

    func live(_ part: RemovalPartition, in current: RemovalSnapshot) throws -> RemovalPartition {
      guard let found = current.partitions.first(where: { $0 == part }) else {
        throw RemovalFailure(message: "The disk changed. Removal stopped.")
      }
      return found
    }
  }

  protocol RemovalDiskOperating: Sendable {
    func snapshot() throws -> RemovalSnapshot
    func evidence(for installation: RemovalInstallation, disk: String) throws -> RemovalEvidence
    func startup(_ snapshot: RemovalSnapshot) throws -> RemovalStartup
    /// Makes the running macOS the startup disk (`nextOnly`: for the next
    /// restart only), authorized by a local owner.
    func setMacOSStartup(
      _ snapshot: RemovalSnapshot, nextOnly: Bool, authorization: MachineOwnerAuthorization)
      throws
    func growLimit(_ macOS: RemovalPartition, disk: String) throws -> UInt64
    func deleteContainer(_ stub: RemovalPartition, disk: String) throws
    func erasePartition(_ partition: RemovalPartition, disk: String) throws
    func growContainer(_ macOS: RemovalPartition, disk: String) throws
    /// Every store the Mac may start up from next: the startup disk and any
    /// one-time choice. Nil when one can't be read.
    func startupStores(_ snapshot: RemovalSnapshot) throws -> [String]?
    /// Unmounts the partition's mounted volumes, without force, and returns
    /// them. Throws `RemovalVolumeBusy` when one is in use, after mounting
    /// the others again.
    func unmountVolumes(of partition: RemovalPartition, in snapshot: RemovalSnapshot) throws
      -> [String]
    /// Mounts volumes again; returns the ones that didn't mount.
    func remountVolumes(_ identifiers: [String]) -> [String]
  }

  extension RemovalDiskOperating {
    func startupStores(_ snapshot: RemovalSnapshot) throws -> [String]? { nil }
    func unmountVolumes(of partition: RemovalPartition, in snapshot: RemovalSnapshot) throws
      -> [String]
    { [] }
    func remountVolumes(_ identifiers: [String]) -> [String] { [] }
  }

  /// A volume in use refused to unmount.
  struct RemovalVolumeBusy: Error, Sendable {
    let volume: String
    /// Volumes unmounted before it that didn't mount again.
    let stillUnmounted: [String]
  }

  /// A deletion failed, and a fresh scan shows the disk as reviewed minus
  /// what was already removed.
  struct RemovalStopped: Error, Sendable {
    let removed: Set<String>
    let total: Int
    let detail: String
  }

  struct AuroraRemovalExecutor: Sendable {
    let disks: any RemovalDiskOperating
    var journals: (any RemovalInstallJournals)? = nil
    /// Erase to free space: a fresh scan with container facts, to recheck
    /// the row before anything is deleted.
    var collect: (@Sendable () throws -> NativeCollectedDisk)? = nil

    func execute(
      _ plan: AuroraRemovalPlan, authorization: MachineOwnerAuthorization? = nil,
      record: (String) throws -> Void
    ) throws {
      let first = try disks.snapshot()
      try plan.validate(first, removed: [])
      let changed = RemovalFailure(
        message:
          "The installation changed since you reviewed it. Close this window and review removal again."
      )
      if let installation = plan.installation {
        // The ticket may be minutes old: the files that proved this is one
        // installation, and the startup choice, must still be exactly as approved.
        guard let live = installation.live(in: first),
          try disks.evidence(for: live, disk: first.disk) == plan.evidence
        else { throw changed }
        if let journal = plan.nativeJournal {
          guard let journals, try journals.installer(of: live, in: first) == journal else {
            throw changed
          }
        }
      }
      if let partial = plan.partial {
        // The same journal must still prove it created this container and
        // went no further.
        guard let journals, let stub = first.partitions.first(where: { $0 == partial.stub }),
          try journals.creator(of: stub, in: first) == partial.journal
        else { throw changed }
      }
      if let erased = plan.erased {
        // The ticket may be minutes old: the row must still be the same
        // partitions, and the erase rule must still admit them.
        guard let collect else { throw changed }
        let region: NativeDiskLayout.Region
        do { region = try AuroraRemovalPlan.erasableRegion(erased.anchor, in: collect()) } catch {
          throw (error as? RemovalFailure) ?? changed
        }
        guard region.memberUUIDs == erased.memberUUIDs else { throw changed }
      }
      // Before any record: a volume in use refuses here, and what was
      // unmounted is mounted again whenever execution stops before a record.
      var unmounted = [(member: String, volumes: [String])]()
      do {
        for member in plan.members {
          unmounted.append(
            (member.uuid, try disks.unmountVolumes(of: plan.live(member, in: first), in: first)))
        }
      } catch let busy as RemovalVolumeBusy {
        let left = busy.stillUnmounted + disks.remountVolumes(unmounted.flatMap(\.volumes))
        throw RemovalFailure(
          message: RemovalText.busy(
            busy.volume, stillUnmounted: RemovalText.volumeNames(left, first)),
          complete: true)
      }
      var recorded = false
      do {
        try execute(plan, first: first, authorization: authorization) { phase in
          try record(phase)
          recorded = true
        }
      } catch let stopped as RemovalStopped {
        _ = disks.remountVolumes(
          unmounted.filter { !stopped.removed.contains($0.member) }.flatMap(\.volumes))
        throw stopped
      } catch let error where !recorded {
        let left = disks.remountVolumes(unmounted.flatMap(\.volumes))
        guard !left.isEmpty, let failure = error as? RemovalFailure else { throw error }
        throw RemovalFailure(
          message: failure.message + " "
            + RemovalText.stillUnmounted(RemovalText.volumeNames(left, first)),
          complete: failure.complete)
      }
    }

    private func execute(
      _ plan: AuroraRemovalPlan, first: RemovalSnapshot,
      authorization: MachineOwnerAuthorization?, record: (String) throws -> Void
    ) throws {
      let checksStartup =
        plan.kind == .eraseToFreeSpace
        ? try AuroraRemovalPlan.erasedStartup(members: plan.members, disks: disks, snapshot: first)
          != nil || plan.startup != nil
        : plan.setsMacOSStartupFirst
      if checksStartup {
        let startup = try disks.startup(first)
        if startup != .macOS {
          guard let reviewed = plan.startup, startup == reviewed else {
            throw RemovalFailure(message: RemovalText.startupChanged)
          }
          guard let authorization else {
            throw RemovalFailure(
              message: "Setting the startup disk needs a macOS administrator account.")
          }
          try setMacOSStartup(plan, snapshot: first, authorization: authorization)
          var recorded = false
          do {
            try removeAndReturnSpace(plan) { phase in
              try record(phase)
              recorded = true
            }
          } catch let error where !recorded {
            let detail = (error as? RemovalFailure)?.message ?? error.localizedDescription
            throw RemovalFailure(
              message:
                "\(detail) Your Mac now starts up from macOS “\(plan.macOSName)”. Nothing was deleted.",
              complete: true)
          }
          return
        }
      }
      try removeAndReturnSpace(plan, record: record)
    }

    private func removeAndReturnSpace(
      _ plan: AuroraRemovalPlan, record: (String) throws -> Void
    ) throws {
      var removed = Set<String>()
      // Delete the startup container first: if a volume is busy, diskutil refuses
      // before the Linux partitions are touched. No force-unmount or -force fallback.
      for (index, member) in plan.members.enumerated() {
        let current = try disks.snapshot()
        try plan.validate(current, removed: removed)
        let target = try plan.live(member, in: current)
        try record("removing-\(member.uuid)")
        do {
          if plan.kind == .eraseToFreeSpace ? member.type == "Apple_APFS" : index == 0 {
            // Without a new name, current macOS deletes the physical store too.
            try disks.deleteContainer(target, disk: current.disk)
          } else {
            try disks.erasePartition(target, disk: current.disk)
          }
        } catch {
          // A disk that is the reviewed layout minus what went is safe to plan
          // again from a fresh scan, so the record doesn't block what follows.
          guard plan.kind == .eraseToFreeSpace || removed.isEmpty,
            let after = try? disks.snapshot(), (try? plan.validate(after, removed: removed)) != nil
          else { throw error }
          try record("stopped")
          throw RemovalStopped(
            removed: removed, total: plan.members.count,
            detail: (error as? RemovalFailure)?.message ?? error.localizedDescription)
        }
        removed.insert(member.uuid)
        try plan.validate(disks.snapshot(), removed: removed)
      }
      // Erase leaves the extent unallocated: nothing grows into it. Neither
      // does macOS grow across another operating system's container.
      if plan.kind == .eraseToFreeSpace || !plan.growsMacOS {
        try plan.validate(disks.snapshot(), removed: removed)
        try record("complete")
        return
      }
      // With nothing deleted yet (free space only), a refused preflight must
      // not leave a journal behind that blocks later installs.
      if !plan.members.isEmpty { try record("returning-space-to-macos") }
      let current = try disks.snapshot()
      try plan.validate(current, removed: removed)
      let macOS = try plan.live(plan.macOS, in: current)
      let limit = try disks.growLimit(macOS, disk: current.disk)
      guard limit.addingReportingOverflow(1_048_576).partialValue >= plan.targetMacOSBytes else {
        throw RemovalFailure(
          message:
            "macOS reports it can only grow to \(RemovalText.size(limit)), not \(RemovalText.size(plan.targetMacOSBytes))."
        )
      }
      if plan.members.isEmpty { try record("returning-space-to-macos") }
      try disks.growContainer(macOS, disk: current.disk)
      try plan.validate(disks.snapshot(), removed: removed, expanded: true)
      try record("complete")
    }

    /// Nothing is deleted unless macOS then reports the running macOS as both
    /// the startup disk and the next restart's choice.
    private func setMacOSStartup(
      _ plan: AuroraRemovalPlan, snapshot: RemovalSnapshot,
      authorization: MachineOwnerAuthorization
    ) throws {
      let name = plan.macOSName
      do {
        try disks.setMacOSStartup(snapshot, nextOnly: false, authorization: authorization)
      } catch let refusal as RemovalStartupRefusal {
        throw RemovalFailure(
          message: RemovalText.startupRefused(name, reason: refusal.reason), complete: true)
      }
      var now = try disks.startup(snapshot)
      if now == .nextStartupOverride {
        do {
          try disks.setMacOSStartup(snapshot, nextOnly: true, authorization: authorization)
        } catch {
          let reason = (error as? RemovalStartupRefusal)?.reason ?? error.localizedDescription
          throw RemovalFailure(
            message: RemovalText.startupUnconfirmed(name, now, reason: reason), complete: true)
        }
        now = try disks.startup(snapshot)
      }
      guard now == .macOS else {
        throw RemovalFailure(
          message: RemovalText.startupUnconfirmed(name, now, reason: nil), complete: true)
      }
    }
  }
#endif
