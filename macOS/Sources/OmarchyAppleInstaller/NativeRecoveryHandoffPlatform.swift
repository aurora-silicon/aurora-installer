#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import OpenDirectory
  import RecoveryAccountCore

  struct NativeHandoffEnvironment: Sendable {
    let snapshot: @Sendable () throws -> RemovalSnapshot
    let device: @Sendable () throws -> String
    let command: @Sendable (String, [String]) throws -> Data
    let ownerUUID: @Sendable (String) throws -> String
    let rawDigest: @Sendable (String, UInt64) throws -> String
    let verifyRecovery: @Sendable (URL, String) throws -> Void
    let owner: uid_t
    let mountRoot: URL
    let sourcePrebootMount: URL
    let verifyMount: @Sendable (Int32, URL, String) throws -> Void

    static var live: Self {
      Self(
        snapshot: { try MacRemovalDiskOperator().snapshot(maximumPartitions: 4096) },
        device: { try AppleSiliconHostInspector().inspectIdentity().deviceIdentifier },
        command: { try AccountNativeCommand.checked($0, $1) },
        ownerUUID: { name in
          let node = try ODNode(
            session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
          let user = try node.record(
            withRecordType: kODRecordTypeUsers, name: name,
            attributes: [kODAttributeTypeGUID])
          let values = try user.values(forAttribute: kODAttributeTypeGUID) as? [String]
          guard values?.count == 1, let value = values?.first, let id = UUID(uuidString: value)
          else {
            throw NativeHandoffValidationError.invalidOwner
          }
          return id.uuidString
        }, rawDigest: { try NativeHandoffRawReader.digest(partition: $0, bytes: $1) },
        verifyRecovery: { try NativeRecoveryTemplate.verify($0, requirement: $1) }, owner: 0,
        mountRoot: URL(fileURLWithPath: "/Volumes"),
        sourcePrebootMount: URL(fileURLWithPath: "/System/Volumes/Preboot"),
        verifyMount: NativeHandoffFileTree.verifyVolumeRoot)
    }

    func plist(_ arguments: [String]) throws -> [String: Any] {
      guard
        let value = try PropertyListSerialization.propertyList(
          from: command("/usr/sbin/diskutil", arguments), format: nil) as? [String: Any]
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      return value
    }
    func disk(_ identifier: String) throws -> [String: Any] {
      try plist(["info", "-plist", identifier])
    }
  }

  final class NativeHandoffMounts: @unchecked Sendable {
    let environment: NativeHandoffEnvironment
    private var owned = [String]()
    init(_ environment: NativeHandoffEnvironment) { self.environment = environment }
    deinit {
      for identifier in owned.reversed() {
        _ = try? environment.command("/usr/sbin/diskutil", ["unmount", identifier])
      }
    }
    func mounted(
      _ identifier: String, uuid: String, key: String = "VolumeUUID", sourcePreboot: Bool = false,
      writable: Bool = false
    ) throws -> URL {
      var info = try environment.disk(identifier)
      guard (info[key] as? String)?.uppercased() == uuid.uppercased() else {
        throw NativeHandoffValidationError.invalidTarget
      }
      if (info["MountPoint"] as? String)?.isEmpty != false {
        _ = try environment.command("/usr/sbin/diskutil", writable
          ? ["mount", identifier] : ["mount", "readOnly", identifier])
        owned.append(identifier)
        info = try environment.disk(identifier)
      }
      guard (info[key] as? String)?.uppercased() == uuid.uppercased(),
        let mount = info["MountPoint"] as? String,
        mount.hasPrefix(environment.mountRoot.path + "/")
          || (sourcePreboot && mount == environment.sourcePrebootMount.path),
        URL(fileURLWithPath: mount).standardizedFileURL.path == mount
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      if writable {
        guard info["WritableVolume"] as? Bool == true || info["ReadOnlyVolume"] as? Bool == false else {
          throw NativeHandoffValidationError.invalidTarget
        }
      }
      return URL(fileURLWithPath: mount, isDirectory: true)
    }
  }

  struct NativePreparedRecoveryHandoff: Sendable {
    let target: RecoveryAccountTarget
    let systemIdentifier: String
    let systemURL: URL
    let evidence: NativeHandoffEvidence
    let mounts: NativeHandoffMounts
  }

  protocol NativeRecoveryHandoffOperating: Sendable {
    func prepare(
      package: ImportedEngineHandoffPackage, snapshot: NativeRecoveryJournalSnapshot,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool
    ) async throws
      -> NativePreparedRecoveryHandoff
    func select(_ target: NativePreparedRecoveryHandoff, authorization: MachineOwnerAuthorization)
      throws
  }

  struct NativeRecoveryHandoffPlatform: NativeRecoveryHandoffOperating {
    let environment: NativeHandoffEnvironment
    let bless: @Sendable ([String], Data, Data) throws -> Void
    init() {
      environment = .live
      bless = { try MacRemovalDiskOperator.runBless($0, input: $1, secret: $2) }
    }
    init(
      environment: NativeHandoffEnvironment,
      bless: @escaping @Sendable ([String], Data, Data) throws -> Void
    ) {
      self.environment = environment
      self.bless = bless
    }

    func prepare(
      package: ImportedEngineHandoffPackage, snapshot: NativeRecoveryJournalSnapshot,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool
    ) async throws
      -> NativePreparedRecoveryHandoff
    {
      guard try environment.device() == package.deviceIdentifier,
        !AppleSiliconHostInspector.isExplicitlyUnsupported(package.deviceIdentifier)
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let metadata = try privateBytes(package.metadataURL, maximum: 65_536)
      let evidence = try NativeHandoffEvidence(snapshot: snapshot, metadata: metadata)
      let before = try environment.snapshot()
      _ = try evidence.requireLayout(before)
      guard
        let container = before.containers.first(where: {
          $0.storeUUID.lowercased() == evidence.target.uuid.lowercased()
        })
      else { throw NativeHandoffValidationError.invalidTarget }
      let group = try uuid(evidence.installed.apfsVgid)
      let systems = container.volumes.filter { $0.roles == ["System"] && $0.group == group }
      let data = container.volumes.filter { $0.roles == ["Data"] && $0.group == group }
      let preboot = container.volumes.filter { $0.roles == ["Preboot"] }
      guard systems.count == 1, data.count == 1, preboot.count == 1,
        container.volumes.filter({ $0.roles == ["Recovery"] }).count == 1,
        systems[0].identifier == evidence.installed.systemVolume
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let mounts = NativeHandoffMounts(environment)
      let systemURL = try mounts.mounted(systems[0].identifier, uuid: systems[0].uuid)
      let systemInfo = try environment.disk(systems[0].identifier)
      guard (systemInfo["APFSVolumeGroupID"] as? String)?.uppercased() == group,
        let reference = systemInfo["APFSContainerReference"] as? String,
        try environment.disk(data[0].uuid)["APFSContainerReference"] as? String == reference,
        try environment.disk(preboot[0].uuid)["APFSContainerReference"] as? String == reference
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let system = try NativeHandoffFileTree(
        systemURL, protected: true, owner: environment.owner,
        volumeRoot: true, volumeDevice: systems[0].identifier, verifyMount: environment.verifyMount)
      let configuration = try system.read(
        "Aurora/Recovery/InstallData/install-config.json", maximum: 65_536)
      guard let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        config["schema"] as? Int == 2,
        config["systemUUID"] as? String == systems[0].uuid,
        config["groupUUID"] as? String == group,
        config["prebootUUID"] as? String == preboot[0].uuid,
        (config["espUUID"] as? String)?.lowercased()
          == evidence.installed.efiPartition.lowercased(),
        config["bootMode"] as? String == "raw", config["stage2Path"] as? String == "m1n1/boot.bin",
        let name = config["volumeName"] as? String
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let target = RecoveryAccountTarget(
        volumeName: name, systemUUID: systems[0].uuid,
        dataUUID: data[0].uuid, groupUUID: group, prebootUUID: preboot[0].uuid)
      try target.validate()
      try NativeSourceOwnerAdmission(environment: environment).requireExpected(
        config: config, snapshot: before, authorization: authorization, mounts: mounts)
      try environment.verifyRecovery(
        systemURL.appendingPathComponent(InstallerProductIdentity.recoveryAppBundleName),
        requirement)

      guard
        let version = try PropertyListSerialization.propertyList(
          from: system.handoffVersion(), format: nil) as? [String: Any],
        let firmware = version["ProductVersion"] as? String, !firmware.isEmpty
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: environment.owner))
      let icon = evidence.installed.startupVolumeIcon
      guard let iconMember = archive.members.first(where: { $0.name == icon.member }),
        iconMember.sizeBytes == icon.installedBytes
      else { throw NativeHandoffValidationError.changedContent }
      let expectedIcon = try await archive.read(
        iconMember, maximumBytes: 64 << 20,
        expectedSHA256: icon.contentSha256)
      guard try system.read(".VolumeIcon.icns", maximum: 64 << 20) == expectedIcon else {
        throw NativeHandoffValidationError.changedContent
      }
      let esp = evidence.installed.populatedPartitions[0]
      let espURL = try mounts.mounted(
        esp.partitionIdentifier, uuid: esp.partitionUuid, key: "DiskUUID")
      let espTree = try NativeHandoffFileTree(
        espURL, protected: false, owner: environment.owner,
        volumeRoot: true, volumeDevice: esp.partitionIdentifier,
        verifyMount: environment.verifyMount)
      let espMembers = archive.members.filter {
        $0.name.hasPrefix("esp/") && !$0.name.hasSuffix("/")
      }
      let layout = try evidence.espLayout(members: Set(espMembers.map(\.name)), firmware: firmware)
      var treeHash = SHA256()
      var installedBytes: UInt64 = 0
      for member in espMembers.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) })
      {
        guard let relative = layout[member.name] else {
          if !layout.values.contains(String(member.name.dropFirst(4))),
            try !espTree.isAbsent(String(member.name.dropFirst(4)))
          {
            throw NativeHandoffValidationError.changedContent
          }
          continue
        }
        let expected = try await archive.read(member, maximumBytes: 64 << 20)
        guard try espTree.read(relative, maximum: 64 << 20) == expected else {
          throw NativeHandoffValidationError.changedContent
        }
        let name = Data(member.name.utf8)
        var length = UInt64(name.count).bigEndian
        treeHash.update(data: withUnsafeBytes(of: &length) { Data($0) })
        treeHash.update(data: name)
        treeHash.update(data: Data(SHA256.hash(data: expected)))
        installedBytes += UInt64(expected.count)
      }
      guard installedBytes == esp.installedBytes,
        treeHash.finalize().map({ String(format: "%02x", $0) }).joined() == esp.contentSha256
      else {
        throw NativeHandoffValidationError.changedContent
      }
      for part in evidence.installed.populatedPartitions.dropFirst() {
        guard let member = archive.members.first(where: { $0.name == part.population }),
          UInt64(member.sizeBytes) == part.installedBytes
        else {
          throw NativeHandoffValidationError.changedContent
        }
        // A fresh root write already has a flushed source-hash receipt. Retry
        // always reads back all images, including that fast initial-write path.
        if fullReadback || part.verification == "raw-prefix-sha256" {
          guard
            try environment.rawDigest(part.partitionIdentifier, part.installedBytes)
              == part.contentSha256
          else {
            throw NativeHandoffValidationError.changedContent
          }
        }
      }
      guard try environment.snapshot() == before else {
        throw NativeHandoffValidationError.changedLayout
      }
      return NativePreparedRecoveryHandoff(
        target: target, systemIdentifier: systems[0].identifier,
        systemURL: systemURL, evidence: evidence, mounts: mounts)
    }

    func select(_ prepared: NativePreparedRecoveryHandoff, authorization: MachineOwnerAuthorization)
      throws
    {
      _ = try prepared.evidence.requireLayout(environment.snapshot())
      let info = try environment.disk(prepared.systemIdentifier)
      guard (info["VolumeUUID"] as? String)?.uppercased() == prepared.target.systemUUID,
        (info["APFSVolumeGroupID"] as? String)?.uppercased() == prepared.target.groupUUID,
        info["MountPoint"] as? String == prepared.systemURL.path
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      _ = try environment.command("/sbin/mount", ["-u", "-w", prepared.systemURL.path])
      let system = try NativeHandoffFileTree(
        prepared.systemURL, protected: true, owner: environment.owner,
        volumeRoot: true, volumeDevice: prepared.systemIdentifier,
        verifyMount: environment.verifyMount)
      try system.prepareForAuthorization()
      do {
        try bless(
          [
            "--setBoot", "--device", "/dev/" + prepared.systemIdentifier,
            "--user", authorization.username, "--stdinpass",
          ], authorization.password + Data([10]), authorization.password)
      } catch { throw NativeHandoffValidationError.authorizationFailed }
      let selectedBytes = try environment.command("/usr/sbin/bless", ["--getBoot", "--plist"])
      guard
        let selection = try PropertyListSerialization.propertyList(from: selectedBytes, format: nil)
          as? [String: Any], let volume = selection["Boot Volume"] as? String
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      try RecoveryAccountHandoff.requireStartupSelection(
        prepared.target, info: environment.disk(volume))
      try system.prepareForRecovery()
    }

    private func uuid(_ value: String) throws -> String {
      guard let id = UUID(uuidString: value),
        id.uuidString != "00000000-0000-0000-0000-000000000000"
      else {
        throw NativeHandoffValidationError.invalidTarget
      }
      return id.uuidString
    }
    private func privateBytes(_ url: URL, maximum: Int) throws -> Data {
      try NativeHandoffFileTree(
        url.deletingLastPathComponent(), protected: true,
        owner: environment.owner
      ).read(url.lastPathComponent, maximum: maximum)
    }
  }
#endif
