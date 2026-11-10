#if os(macOS)
  import CoreFoundation
  import Foundation

  struct NativeSourceBootstrap: Equatable, Sendable {
    let systemUUID: String
    let groupUUID: String
    let ownerUUID: String

    init(systemUUID: String, groupUUID: String, ownerUUID: String) throws {
      self.systemUUID = try Self.uuid(systemUUID)
      self.groupUUID = try Self.uuid(groupUUID)
      self.ownerUUID = try Self.uuid(ownerUUID)
    }

    init(_ object: [String: Any]) throws {
      guard object["mode"] as? String == "source-volume-owner",
        let system = object["sourceSystemUUID"] as? String,
        let group = object["sourceGroupUUID"] as? String,
        let owners = object["ownerUUIDs"] as? [String], owners.count == 1
      else { throw NativeHandoffValidationError.invalidOwner }
      try self.init(systemUUID: system, groupUUID: group, ownerUUID: owners[0])
    }

    var configuration: [String: Any] {
      [
        "mode": "source-volume-owner", "sourceSystemUUID": systemUUID,
        "sourceGroupUUID": groupUUID, "ownerUUIDs": [ownerUUID],
      ]
    }

    static func uuid(_ value: String) throws -> String {
      guard let id = UUID(uuidString: value), value.uppercased() == id.uuidString,
        id.uuidString != "00000000-0000-0000-0000-000000000000"
      else { throw NativeHandoffValidationError.invalidOwner }
      return id.uuidString
    }
  }

  /// Which part of the source-owner proof failed. Every guard of the proof
  /// has its own case, so a refusal names the check that stopped it instead
  /// of one sentence for all of them. `summary` is shown to the person;
  /// `description` adds the underlying error for the root-only diagnostics.
  enum NativeSourceOwnerRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The hardware identity differs from the one the plan was made on.
    case otherMac
    /// The internal disk differs from the one the plan was made on.
    case otherDisk
    /// A disk utility query failed or its reply could not be read.
    case diskQuery(step: String, detail: String)
    /// The running system's volume group or APFS container is unidentifiable.
    case runningSystem
    /// The running system's container lacks exactly one of the volumes.
    case volumes(system: Int, data: Int, preboot: Int, recovery: Int)
    /// The System volume's own record disagrees with the disk layout.
    case systemVolume
    /// OpenDirectory has no single local account for the name.
    case unknownAccount
    /// APFS does not list the account as a volume owner of the System volume.
    case notVolumeOwner
    /// The source Preboot volume could not be mounted or opened safely.
    case preboot(detail: String)
    /// macOS's Recovery administrator list is absent from Preboot.
    case adminListMissing
    /// The Recovery administrator list exists but is unsafe or unreadable.
    case adminListUnreadable(detail: String)
    /// The Recovery administrator list has no entry for the account.
    case notInAdminList
    /// The Recovery administrator list gives the account another identity.
    case adminIdentityMismatch
    /// The disk layout or the running system changed during the check.
    case layoutChanged

    /// Printable ASCII, so `EngineFailureNotice` keeps every character.
    var summary: String {
      switch self {
      case .otherMac: "this Mac is not the one the installation was planned on."
      case .otherDisk: "the internal disk is not the one the installation was planned on."
      case .diskQuery(let step, _): "macOS did not answer the \(step) query."
      case .runningSystem: "the running macOS volume group could not be identified."
      case .volumes(let system, let data, let preboot, let recovery):
        "the macOS container has \(system) System, \(data) Data, \(preboot) Preboot and "
          + "\(recovery) Recovery volumes; one of each is required."
      case .systemVolume: "the macOS System volume does not match the disk layout."
      case .unknownAccount: "this account was not found among the local macOS accounts."
      case .notVolumeOwner:
        "APFS does not list this account as a volume owner. Use the account that set up this Mac."
      case .preboot: "the macOS Preboot volume could not be opened safely."
      case .adminListMissing: "the Preboot volume has no list of Recovery administrators."
      case .adminListUnreadable(let detail):
        "the Recovery administrator list on Preboot could not be read safely: "
          + "\(Self.clipped(detail))."
      case .notInAdminList:
        "the Recovery administrator list on Preboot does not include this account."
      case .adminIdentityMismatch:
        "the Recovery administrator list on Preboot gives this account another identity."
      case .layoutChanged: "the disk layout changed during the check. Choose Check again."
      }
    }

    var description: String {
      switch self {
      case .otherMac: "otherMac"
      case .otherDisk: "otherDisk"
      case .diskQuery(let step, let detail): "diskQuery(\(step)): \(detail)"
      case .runningSystem: "runningSystem"
      case .volumes(let system, let data, let preboot, let recovery):
        "volumes(system: \(system), data: \(data), preboot: \(preboot), recovery: \(recovery))"
      case .systemVolume: "systemVolume"
      case .unknownAccount: "unknownAccount"
      case .notVolumeOwner: "notVolumeOwner"
      case .preboot(let detail): "preboot: \(detail)"
      case .adminListMissing: "adminListMissing"
      case .adminListUnreadable(let detail): "adminListUnreadable: \(detail)"
      case .notInAdminList: "notInAdminList"
      case .adminIdentityMismatch: "adminIdentityMismatch"
      case .layoutChanged: "layoutChanged"
      }
    }

    /// A detail shown inside a summary stays short enough that the whole
    /// summary fits the failure notice.
    static func clipped(_ detail: String) -> String {
      detail.count <= 64 ? detail : String(detail.prefix(61)) + "..."
    }

    /// Cancellation and an earlier refusal pass through unchanged.
    static func wrapping<T>(_ step: String, _ body: () throws -> T) throws -> T {
      do {
        return try body()
      } catch let error as CancellationError {
        throw error
      } catch let error as NativeSourceOwnerRefusal {
        throw error
      } catch {
        throw diskQuery(step: step, detail: String(describing: error))
      }
    }
  }

  /// The same live source-owner proof is required before disk preparation and
  /// again when a target's Recovery configuration is admitted. No password is
  /// sent to a command or used to modify the source installation.
  struct NativeSourceOwnerAdmission: Sendable {
    let environment: NativeHandoffEnvironment
    init(environment: NativeHandoffEnvironment = .live) { self.environment = environment }

    static let adminListPath = "var/db/AdminUserRecoveryInfo.plist"

    /// Reading the disk layout takes a dozen disk utility queries. A caller
    /// that read the layout for its own pass and reads it again before it
    /// relies on the owner or changes the disk passes that layout as
    /// `layout`: the check then works from it and reads none of its own.
    /// Without it, the check reads the layout before and after resolving the
    /// owner, so the owner always comes from one unchanged layout.
    func check(
      package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
      layout: RemovalSnapshot? = nil
    ) throws -> NativeSourceBootstrap {
      try Task.checkCancellation()
      let device = try InstallerPerformance.measure("owner_device") {
        try NativeSourceOwnerRefusal.wrapping("hardware identity") { try environment.device() }
      }
      guard device == package.deviceIdentifier else { throw NativeSourceOwnerRefusal.otherMac }
      let before =
        try layout
        ?? InstallerPerformance.measure("owner_snapshot") {
          try NativeSourceOwnerRefusal.wrapping("disk layout") { try environment.snapshot() }
        }
      guard before.disk == package.storeIdentifier else {
        throw NativeSourceOwnerRefusal.otherDisk
      }
      let mounts = NativeHandoffMounts(environment)
      let bootstrap = try InstallerPerformance.measure("owner_resolve") {
        try resolve(snapshot: before, authorization: authorization, mounts: mounts)
      }
      try Task.checkCancellation()
      try InstallerPerformance.measure("owner_recheck") {
        if layout == nil {
          let after = try NativeSourceOwnerRefusal.wrapping("disk layout") {
            try environment.snapshot()
          }
          guard after == before else { throw NativeSourceOwnerRefusal.layoutChanged }
        }
        guard try runningGroup() == bootstrap.groupUUID else {
          throw NativeSourceOwnerRefusal.layoutChanged
        }
      }
      return bootstrap
    }

    func requireExpected(
      config: [String: Any], snapshot: RemovalSnapshot,
      authorization: MachineOwnerAuthorization, mounts: NativeHandoffMounts
    ) throws {
      guard let object = config["bootstrap"] as? [String: Any],
        let targetGroup = config["groupUUID"] as? String
      else { throw NativeHandoffValidationError.invalidOwner }
      let expected = try NativeSourceBootstrap(object)
      guard try NativeSourceBootstrap.uuid(targetGroup) != expected.groupUUID,
        try resolve(snapshot: snapshot, authorization: authorization, mounts: mounts) == expected
      else { throw NativeHandoffValidationError.invalidOwner }
    }

    private func resolve(
      snapshot: RemovalSnapshot, authorization: MachineOwnerAuthorization,
      mounts: NativeHandoffMounts
    ) throws -> NativeSourceBootstrap {
      try Task.checkCancellation()
      let root = try NativeSourceOwnerRefusal.wrapping("running system") {
        try environment.disk("/")
      }
      try Task.checkCancellation()
      guard let group = root["APFSVolumeGroupID"] as? String,
        let reference = root["APFSContainerReference"] as? String,
        NativeInspectionCommands.identifier(reference),
        let groupUUID = try? NativeSourceBootstrap.uuid(group)
      else { throw NativeSourceOwnerRefusal.runningSystem }
      let containers = snapshot.containers.filter { $0.uuid == snapshot.macOSContainerUUID }
      guard containers.count == 1, let container = containers.first,
        container.storeUUID == snapshot.macOSStoreUUID
      else { throw NativeSourceOwnerRefusal.runningSystem }
      let systems = container.volumes.filter { $0.roles == ["System"] && $0.group == groupUUID }
      let data = container.volumes.filter { $0.roles == ["Data"] && $0.group == groupUUID }
      let preboots = container.volumes.filter { $0.roles == ["Preboot"] }
      let recoveries = container.volumes.filter { $0.roles == ["Recovery"] }
      guard systems.count == 1, data.count == 1, preboots.count == 1, recoveries.count == 1 else {
        throw NativeSourceOwnerRefusal.volumes(
          system: systems.count, data: data.count, preboot: preboots.count,
          recovery: recoveries.count)
      }
      let source = try NativeSourceOwnerRefusal.wrapping("System volume") {
        try environment.disk(systems[0].identifier)
      }
      try Task.checkCancellation()
      guard
        (source["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
          == systems[0].uuid,
        (source["APFSVolumeGroupID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
          == groupUUID,
        source["APFSContainerReference"] as? String == reference
      else { throw NativeSourceOwnerRefusal.systemVolume }
      // OpenDirectory matches a typed name without regard to case and also
      // accepts an account's aliases. The Preboot list is keyed by the
      // account's own short name, so that is the name looked up there.
      let account: String
      let guid: String
      do {
        account = try environment.ownerName(authorization.username)
        guid = try NativeSourceBootstrap.uuid(environment.ownerUUID(authorization.username))
      } catch let error as CancellationError {
        throw error
      } catch {
        throw NativeSourceOwnerRefusal.unknownAccount
      }
      let bootstrap = try NativeSourceBootstrap(
        systemUUID: systems[0].uuid, groupUUID: groupUUID, ownerUUID: guid)
      let users = try NativeSourceOwnerRefusal.wrapping("APFS volume users") {
        try environment.plist(["apfs", "listUsers", bootstrap.systemUUID, "-plist"])
      }
      guard let entries = users["Users"] as? [[String: Any]] else {
        throw NativeSourceOwnerRefusal.diskQuery(
          step: "APFS volume users", detail: "the reply has no Users list")
      }
      guard
        entries.contains(where: {
          guard let flag = $0["VolumeOwner"] as? NSNumber,
            CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue
          else { return false }
          return ($0["APFSCryptoUserUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            == guid
        })
      else {
        Self.log(.error, Self.usersSummary(entries) + "; this account is not a volume owner")
        throw NativeSourceOwnerRefusal.notVolumeOwner
      }
      Self.log(.progress, Self.usersSummary(entries) + "; this account is a volume owner")
      try Task.checkCancellation()
      let preboot = preboots[0]
      let url: URL
      let tree: NativeHandoffFileTree
      do {
        url = try mounts.mounted(preboot.identifier, uuid: preboot.uuid, sourcePreboot: true)
        tree = try NativeHandoffFileTree(
          url, protected: true, owner: environment.owner,
          volumeRoot: true, volumeDevice: preboot.identifier, verifyMount: environment.verifyMount
        )
      } catch let error as CancellationError {
        throw error
      } catch {
        Self.log(.error, "Preboot \(preboot.identifier) could not be opened safely: \(error)")
        throw NativeSourceOwnerRefusal.preboot(detail: String(describing: error))
      }
      // What was found at each component goes to the log at progress level,
      // which the default filter keeps, so a saved log shows the layout. The
      // read alone decides; the lines only describe it.
      Self.log(.progress, "Reading Recovery administrators from Preboot \(preboot.identifier)")
      let metadata: Data
      do {
        metadata = try tree.sourceOwnerMetadata(groupUUID: groupUUID) {
          Self.log(.progress, "Preboot \($0)")
        }
      } catch let error as CancellationError {
        throw error
      } catch let refusal as SourceOwnerMetadataRefusal {
        Self.log(.error, "Recovery administrator list refused: \(refusal.reason)")
        if refusal.missing { throw NativeSourceOwnerRefusal.adminListMissing }
        throw NativeSourceOwnerRefusal.adminListUnreadable(detail: refusal.reason)
      } catch {
        Self.log(.error, "Recovery administrator list refused: \(error)")
        throw NativeSourceOwnerRefusal.adminListUnreadable(detail: String(describing: error))
      }
      // Only the authorized account's entry is read, as the reference engine
      // reads it. Other keys may hold anything macOS records there.
      var format = PropertyListSerialization.PropertyListFormat.xml
      let parsed = try? PropertyListSerialization.propertyList(from: metadata, format: &format)
      guard let admins = parsed as? [String: Any] else {
        let detail =
          metadata.isEmpty
          ? "the file is empty"
          : parsed == nil ? "the file is not a property list" : "the file is not a dictionary"
        Self.log(.error, "Recovery administrator list refused: \(detail)")
        throw NativeSourceOwnerRefusal.adminListUnreadable(detail: detail)
      }
      let records = admins.values.filter { $0 is [String: Any] }.count
      let summary =
        "Recovery administrator list: \(metadata.count) bytes, \(Self.name(format)) property list, "
        + "\(admins.count) entr\(admins.count == 1 ? "y" : "ies") (\(records) account record"
        + "\(records == 1 ? "" : "s"))"
      guard let entry = admins[account] as? [String: Any] else {
        Self.log(.error, summary + "; none is this account's")
        throw NativeSourceOwnerRefusal.notInAdminList
      }
      guard
        (entry["GeneratedUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString == guid
      else {
        Self.log(.error, summary + "; this account's entry has another GeneratedUID")
        throw NativeSourceOwnerRefusal.adminIdentityMismatch
      }
      Self.log(.progress, summary + "; this account's entry matches")
      try Task.checkCancellation()
      return bootstrap
    }

    /// Owner-check lines carry no account name, GUID or volume group UUID.
    private static func log(_ level: InstallerLogLevel, _ message: String) {
      InstallerLog.record(level, "Owner check: " + message)
    }

    private static func usersSummary(_ entries: [[String: Any]]) -> String {
      let owners = entries.filter { ($0["VolumeOwner"] as? NSNumber)?.boolValue == true }.count
      let types = Set(entries.compactMap { $0["APFSCryptoUserType"] as? String }).sorted()
      return
        "APFS lists \(entries.count) user\(entries.count == 1 ? "" : "s") of the System volume, "
        + "\(owners) volume owner\(owners == 1 ? "" : "s")"
        + (types.isEmpty ? "" : " (types: \(types.joined(separator: ", ")))")
    }

    private static func name(_ format: PropertyListSerialization.PropertyListFormat) -> String {
      switch format {
      case .xml: "XML"
      case .binary: "binary"
      case .openStep: "OpenStep"
      @unknown default: "unknown"
      }
    }

    private func runningGroup() throws -> String {
      let root = try NativeSourceOwnerRefusal.wrapping("running system") {
        try environment.disk("/")
      }
      guard let group = root["APFSVolumeGroupID"] as? String,
        let uuid = try? NativeSourceBootstrap.uuid(group)
      else { throw NativeSourceOwnerRefusal.layoutChanged }
      return uuid
    }
  }
#endif
