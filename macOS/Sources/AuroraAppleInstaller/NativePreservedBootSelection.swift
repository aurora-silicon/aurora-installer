#if os(macOS)
  import Darwin
  import Foundation

  struct NativePreservedBootSelectionFailure: Error {
    let operation: any Error
    let cleanup: any Error
  }

  /// Selects an already enrolled Stage 1 group. No new Recovery enrollment or
  /// replacement of its boot image is permitted in this path.
  struct NativePreservedBootSelector: Sendable {
    let baseline: RemovalSnapshot
    let expectedStage1: NativeStubFileIdentity
    var environment: NativeHandoffEnvironment = .live
    var owner: uid_t = 0
    var bless: @Sendable ([String], Data, Data) throws -> Void = {
      try MacRemovalDiskOperator.runBless($0, input: $1, secret: $2)
    }

    func select(_ target: NativePreservedInstallTarget, authorization: MachineOwnerAuthorization)
      throws
    {
      let system = try admittedSystem(target)
      let mounts = NativeHandoffMounts(environment)
      let systemURL = try mounts.mounted(
        system.identifier, uuid: system.uuid)
      try verifySystemInfo(system, target: target, mount: systemURL)
      _ = try environment.command("/sbin/mount", ["-u", "-w", systemURL.path])
      let writableInfo = try environment.disk(system.identifier)
      guard
        (writableInfo["VolumeUUID"] as? String)?.uppercased()
          == system.uuid.uppercased(),
        writableInfo["MountPoint"] as? String == systemURL.path,
        writableInfo["WritableVolume"] as? Bool == true
          || writableInfo["ReadOnlyVolume"] as? Bool == false
      else { throw NativeHandoffValidationError.invalidTarget }
      let tree = try NativeHandoffFileTree(
        systemURL, protected: true, owner: owner,
        volumeRoot: true, volumeDevice: system.identifier,
        verifyMount: environment.verifyMount)
      try verifyStage1(tree)
      do {
        try tree.prepareForAuthorization()
        do {
          try bless(
            [
              "--setBoot", "--device", "/dev/" + system.identifier,
              "--user", authorization.username, "--stdinpass",
            ], authorization.password + Data([10]), authorization.password)
        } catch { throw NativeHandoffValidationError.authorizationFailed }
        try tree.prepareForRecovery()
      } catch {
        let operation = error
        do { try tree.prepareForRecovery() } catch {
          throw NativePreservedBootSelectionFailure(operation: operation, cleanup: error)
        }
        throw operation
      }
      try verifyStage1(tree)
      try verify(target)
    }

    func verify(_ target: NativePreservedInstallTarget) throws {
      let system = try admittedSystem(target)
      let mounts = NativeHandoffMounts(environment)
      let systemURL = try mounts.mounted(system.identifier, uuid: system.uuid)
      try verifySystemInfo(system, target: target, mount: systemURL)
      let tree = try NativeHandoffFileTree(
        systemURL, protected: true, owner: owner,
        volumeRoot: true, volumeDevice: system.identifier,
        verifyMount: environment.verifyMount)
      try verifyStage1(tree)
      let selected = try environment.command("/usr/sbin/bless", ["--getBoot", "--plist"])
      guard
        let plist = try PropertyListSerialization.propertyList(
          from: selected, format: nil) as? [String: Any],
        let volume = plist["Boot Volume"] as? String, !volume.isEmpty
      else { throw NativeHandoffValidationError.invalidTarget }
      let info = try environment.disk(volume)
      guard
        (info["APFSVolumeGroupID"] as? String)?.uppercased()
          == target.group.uppercased()
      else { throw NativeHandoffValidationError.invalidTarget }
      guard try environment.snapshot() == baseline else {
        throw NativePreservedInstallError.changedLayout
      }
    }

    private func admittedSystem(_ target: NativePreservedInstallTarget) throws -> RemovalVolume {
      guard baseline.disk == target.disk,
        baseline.partitions.contains(where: {
          $0.identifier == target.stub.identifier && $0.uuid == target.stub.uuid
            && $0 == target.stub
        }),
        let container = baseline.containers.first(where: { $0.storeUUID == target.stub.uuid }),
        baseline.containers.filter({ $0.storeUUID == target.stub.uuid }).count == 1,
        let system = container.volumes.first(where: {
          $0.roles == ["System"] && $0.group == target.group && $0.name == target.title
        }),
        container.volumes.filter({
          $0.roles == ["System"] && $0.group == target.group
        }).count == 1,
        try environment.snapshot() == baseline
      else { throw NativePreservedInstallError.changedLayout }
      return system
    }

    private func verifySystemInfo(
      _ system: RemovalVolume, target: NativePreservedInstallTarget, mount: URL
    ) throws {
      let info = try environment.disk(system.identifier)
      guard (info["VolumeUUID"] as? String)?.uppercased() == system.uuid.uppercased(),
        (info["APFSVolumeGroupID"] as? String)?.uppercased() == target.group.uppercased(),
        info["MountPoint"] as? String == mount.path
      else { throw NativeHandoffValidationError.invalidTarget }
    }

    private func verifyStage1(_ tree: NativeHandoffFileTree) throws {
      let bytes = try tree.read(
        "Finish Installation.app/Contents/Resources/boot.bin", maximum: 64 << 20)
      let observed = NativeStubFileIdentity(
        bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
      guard observed == expectedStage1 else { throw NativeBootChainError.invalidStage1 }
    }
  }
#endif
