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

  /// The same live source-owner proof is required before disk preparation and
  /// again when a target's Recovery configuration is admitted. No password is
  /// sent to a command or used to modify the source installation.
  struct NativeSourceOwnerAdmission: Sendable {
    let environment: NativeHandoffEnvironment
    init(environment: NativeHandoffEnvironment = .live) { self.environment = environment }

    func check(
      package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization
    ) throws -> NativeSourceBootstrap {
      try Task.checkCancellation()
      guard try environment.device() == package.deviceIdentifier,
        !AppleSiliconHostInspector.isExplicitlyUnsupported(package.deviceIdentifier)
      else { throw NativeHandoffValidationError.invalidOwner }
      let before = try environment.snapshot()
      guard before.disk == package.storeIdentifier else {
        throw NativeHandoffValidationError.invalidOwner
      }
      let mounts = NativeHandoffMounts(environment)
      let bootstrap = try resolve(snapshot: before, authorization: authorization, mounts: mounts)
      try Task.checkCancellation()
      guard try environment.snapshot() == before,
        try NativeSourceBootstrap.uuid(rootGroup()) == bootstrap.groupUUID
      else { throw NativeHandoffValidationError.changedLayout }
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
      let root = try environment.disk("/")
      try Task.checkCancellation()
      guard let group = root["APFSVolumeGroupID"] as? String,
        let reference = root["APFSContainerReference"] as? String,
        NativeInspectionCommands.identifier(reference)
      else { throw NativeHandoffValidationError.invalidOwner }
      let groupUUID = try NativeSourceBootstrap.uuid(group)
      let containers = snapshot.containers.filter { $0.uuid == snapshot.macOSContainerUUID }
      guard containers.count == 1, let container = containers.first,
        container.storeUUID == snapshot.macOSStoreUUID
      else { throw NativeHandoffValidationError.invalidOwner }
      let systems = container.volumes.filter { $0.roles == ["System"] && $0.group == groupUUID }
      let data = container.volumes.filter { $0.roles == ["Data"] && $0.group == groupUUID }
      let preboots = container.volumes.filter { $0.roles == ["Preboot"] }
      guard systems.count == 1, data.count == 1, preboots.count == 1,
        container.volumes.filter({ $0.roles == ["Recovery"] }).count == 1
      else { throw NativeHandoffValidationError.invalidOwner }
      let source = try environment.disk(systems[0].identifier)
      try Task.checkCancellation()
      guard
        (source["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
          == systems[0].uuid,
        (source["APFSVolumeGroupID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
          == groupUUID,
        source["APFSContainerReference"] as? String == reference
      else { throw NativeHandoffValidationError.invalidOwner }
      let guid = try NativeSourceBootstrap.uuid(environment.ownerUUID(authorization.username))
      let bootstrap = try NativeSourceBootstrap(
        systemUUID: systems[0].uuid, groupUUID: groupUUID, ownerUUID: guid)
      let users = try environment.plist(["apfs", "listUsers", bootstrap.systemUUID, "-plist"])
      guard let entries = users["Users"] as? [[String: Any]],
        entries.contains(where: {
          guard let flag = $0["VolumeOwner"] as? NSNumber,
            CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue
          else { return false }
          return ($0["APFSCryptoUserUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            == guid
        })
      else { throw NativeHandoffValidationError.invalidOwner }
      try Task.checkCancellation()
      let preboot = preboots[0]
      let url = try mounts.mounted(preboot.identifier, uuid: preboot.uuid, sourcePreboot: true)
      let tree = try NativeHandoffFileTree(
        url, protected: true, owner: environment.owner,
        volumeRoot: true, volumeDevice: preboot.identifier, verifyMount: environment.verifyMount)
      guard
        let admins = try PropertyListSerialization.propertyList(
          from: tree.read(groupUUID + "/var/db/AdminUserRecoveryInfo.plist", maximum: 1 << 20),
          format: nil
        ) as? [String: [String: Any]],
        (admins[authorization.username]?["GeneratedUID"] as? String).flatMap(
          UUID.init(uuidString:))?.uuidString == guid
      else { throw NativeHandoffValidationError.invalidOwner }
      try Task.checkCancellation()
      return bootstrap
    }

    private func rootGroup() throws -> String {
      guard let group = try environment.disk("/")["APFSVolumeGroupID"] as? String else {
        throw NativeHandoffValidationError.invalidOwner
      }
      return group
    }
  }
#endif
