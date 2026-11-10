#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import IOKit

  protocol NativeStubFilesExecuting: Sendable {
    var firmwarePlan: NativeStubFilePlan? { get }
    /// Refuses, before the first disk change, a stage macOS lacks the free
    /// space for. Throws `MacOSFreeSpaceShortfall` with the stage's needs.
    func requireStagingSpace(journal: URL) throws
    /// Refuses, before the first disk change, a stub too small for the padded
    /// Stage 1 Recovery enrolls there.
    func requireRoom(forExpandedStage1 bytes: UInt64) throws
    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap) async throws
  }
  extension NativeStubFilesExecuting {
    var firmwarePlan: NativeStubFilePlan? { nil }
    func requireStagingSpace(journal: URL) throws {}
    func requireRoom(forExpandedStage1 bytes: UInt64) throws {}
  }

  /// Room on the stub for what Recovery adds after the restore. The padded file is
  /// sparse, but kmutil reads and compresses all of it, so its whole size counts.
  enum NativeEnrollmentSpace {
    /// The Recovery app and the installation data kept beside it.
    static let recoveryDataBytes: UInt64 = 512 << 20

    static func require(stubBytes: UInt64, restoredBytes: UInt64, expandedStage1: UInt64) throws {
      let (kept, overflowed) = restoredBytes.addingReportingOverflow(recoveryDataBytes)
      let (needed, overflow) = kept.addingReportingOverflow(expandedStage1)
      guard !overflowed, !overflow, needed <= stubBytes else {
        throw NativeStubFileError.noRoomForStage1(
          requiredBytes: overflowed || overflow ? .max : needed, stubBytes: stubBytes)
      }
    }
  }

  protocol NativeStubFilesPreparing: Sendable {
    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeStubFilesExecuting
    )?
  }

  struct NativeStubFilePlatform: Sendable {
    var environment: NativeHandoffEnvironment
    var boardID: @Sendable () throws -> UInt64
    var configureSystem: @Sendable (URL) throws -> Void
    var protectAdmin: @Sendable (URL) throws -> Void
    var decode: @Sendable (URL, String, URL, URL, FileHandle) async throws -> Void

    static var live: Self {
      Self(
        environment: .live,
        boardID: {
          let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
          guard entry != 0 else { throw NativeStubFileError.invalidPlan }
          defer { IOObjectRelease(entry) }
          guard
            let bytes = IORegistryEntryCreateCFProperty(
              entry, "board-id" as CFString,
              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data, [4, 8].contains(bytes.count)
          else { throw NativeStubFileError.invalidPlan }
          return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        },
        configureSystem: { root in
          var flags = Data(repeating: 0, count: 32)
          flags[8] = 4
          let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          guard descriptor >= 0 else { throw NativeStubFileError.unsafeFile }
          defer { close(descriptor) }
          guard
            flags.withUnsafeBytes({
              fsetxattr(descriptor, "com.apple.FinderInfo", $0.baseAddress, flags.count, 0, 0)
            }) == 0
          else { throw NativeStubFileError.writeFailed }
          var command: Int32 = 1
          guard fsctl(root.path, 0xc004_4a57, &command, 0) == 0 else {
            throw NativeStubFileError.writeFailed
          }
        },
        protectAdmin: { url in
          let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          guard descriptor >= 0 else { throw NativeStubFileError.unsafeFile }
          defer { close(descriptor) }
          guard fchflags(descriptor, UInt32(SF_IMMUTABLE)) == 0 else {
            throw NativeStubFileError.writeFailed
          }
        },
        decode: { input, digest, output, executable, lease in
          let task = Task.detached {
            try NativeStubDecoder.run(
              executable: executable, input: input, digest: digest, output: output, lease: lease)
          }
          try await withTaskCancellationHandler {
            try await task.value
          } onCancel: {
            task.cancel()
          }
        })
    }
  }

  struct NativeStubFilesPreparer: NativeStubFilesPreparing {
    let owner: uid_t
    let platform: NativeStubFilePlatform
    let facts: @Sendable () throws -> NativeFirmwareSelection.Facts

    init(
      owner: uid_t = 0, platform: NativeStubFilePlatform = .live,
      facts: @escaping @Sendable () throws -> NativeFirmwareSelection.Facts = { try .live() }
    ) {
      self.owner = owner
      self.platform = platform
      self.facts = facts
    }

    func preflight(_ package: ImportedEngineHandoffPackage) async throws -> (
      any NativeStubFilesExecuting
    )? {
      guard package.installationIntent == .fresh else { return nil }
      let approved = try EngineHandoffPackageImporter().executionPlan(package, owner: owner)
      let files = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try files.read(package.metadataURL.lastPathComponent, maximum: 65536)
      guard SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest else {
        throw NativeStubFileError.invalidPlan
      }
      let facts = try facts()
      let firmware = try NativeFirmwareSelection.choose(
        deviceIdentifier: package.deviceIdentifier,
        facts: facts, metadata: NativeInstallationMetadata(data: metadata),
        policy: NativeInspectionPolicy.sealed())
      // A restore image or a full update archive. The plan also requires the
      // archive to have the layout its URL names.
      guard NativeRestoreSourceLayout(sourceURL: firmware.sourceURL) != nil else {
        throw NativeFirmwareSelectionError.invalidSource
      }
      let source = try await IPSWHTTPRangeReader.discover(url: firmware.sourceURL)
      let identity = try NativeStubRestoreCache.identity(
        url: firmware.sourceURL, bytes: source.sizeBytes)
      let directory = package.packageURL.deletingLastPathComponent()
      let cache = NativeStubRestoreCache.root(in: directory, identity: identity)
      NativeStubRestoreCache.prune(
        in: directory, current: cache, selectable: NativeStubRestoreCache.selectableSources(),
        owner: owner)
      let reader = try NativeStubRestoreCache(
        source: source, root: cache, owner: owner, identity: identity)
      let boardID = try platform.boardID()
      let plan: NativeStubFilePlan
      do {
        let archive = try await IPSWArchive.open(reader)
        plan = try await NativeStubFilePlan(
          archive: archive, source: firmware,
          deviceClass: String(package.deviceIdentifier.dropFirst(6)) + "ap",
          boardID: boardID, chipID: facts.hardware.chipID)
      } catch let shortfall as MacOSFreeSpaceShortfall {
        // The cache refused a planning read. Name what the whole stage needs,
        // worked out from the image without caching, not that read's floor.
        guard
          let whole = try? await NativeStubStagingRequirement.estimate(
            source: source, firmware: firmware, deviceIdentifier: package.deviceIdentifier,
            boardID: boardID, chipID: facts.hardware.chipID)
        else { throw shortfall }
        throw MacOSFreeSpaceShortfall(
          requiredBytes: max(whole.requiredFreeBytes, shortfall.requiredBytes),
          availableBytes: shortfall.availableBytes)
      }
      // What earlier attempts already cached for this image is on disk.
      let cached = try await reader.cachedBytes(
        overlapping: NativeStubStagingRequirement.spans(plan.readMembers))
      let staging = NativeStubStagingRequirement(
        plan: plan, decoded: try await NativeStubStagingRequirement.decodedMembers(of: plan),
        includingPlanningReads: false
      ).remaining(cachedBytes: cached)
      return NativeStubFilesExecution(
        package: package, approved: approved,
        plan: plan, owner: owner, platform: platform, cache: reader, staging: staging,
        stagingCachedBytes: cached)
    }
  }

  struct NativeStubFilesExecution: NativeStubFilesExecuting {
    struct Installed: Codable, Equatable, Sendable {
      let role: String
      let path: String
      let installerDataName: String?
      let identity: NativeStubFileIdentity
    }
    let package: ImportedEngineHandoffPackage
    let approved: ValidatedEnginePlan
    let plan: NativeStubFilePlan
    let owner: uid_t
    let platform: NativeStubFilePlatform
    let cache: NativeStubRestoreCache?
    /// What the stage still needs free on macOS, from this plan's members.
    var staging: NativeStubStagingRequirement? = nil
    /// What the cache held for those members when `staging` was counted.
    var stagingCachedBytes: UInt64 = 0
    var freeBytes: @Sendable (URL) -> UInt64? = { NativeStubRestoreCache.freeBytes($0) }
    var firmwarePlan: NativeStubFilePlan? { plan }

    /// The free bytes the stage needs now, or nil once it completed.
    static func stagingFreeBytes(_ stage: UInt64, checkpoints: [String], pendingShrink: UInt64)
      -> UInt64?
    {
      if checkpoints.contains("stub-and-esp-installed") { return nil }
      let (sum, overflow) = stage.addingReportingOverflow(pendingShrink)
      return overflow ? .max : sum
    }

    /// The part of a macOS resize not yet done, read from the partition map:
    /// the macOS container still covering the new partition's extent.
    static func pendingShrinkBytes(
      kind: String, source: RemovalPartition?, macOSStoreUUID: String, offsetBytes: UInt64,
      lengthBytes: UInt64
    ) -> UInt64 {
      guard kind == "resize", let source, source.uuid == macOSStoreUUID,
        source.end > offsetBytes
      else { return 0 }
      return min(lengthBytes, source.end - offsetBytes)
    }

    func requireRoom(forExpandedStage1 bytes: UInt64) throws {
      try NativeEnrollmentSpace.require(
        stubBytes: plan.source.stubBytes, restoredBytes: plan.estimatedStubBytes,
        expandedStage1: bytes)
    }

    func requireStagingSpace(journal: URL) throws {
      guard let staging else { return }
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let saved = try file.readJournal()
      let checkpoints =
        saved.isEmpty
        ? []
        : try AppleInstallerTrustCore().validateEngineTranscript(saved).checkpoints.map(
          \.identifier)
      var pending: UInt64 = 0
      if approved.candidateKind == "resize" {
        let snapshot = try platform.environment.snapshot()
        pending = Self.pendingShrinkBytes(
          kind: approved.candidateKind,
          source: snapshot.partitions.first { $0.identifier == approved.sourceIdentifier },
          macOSStoreUUID: snapshot.macOSStoreUUID, offsetBytes: approved.offsetBytes,
          lengthBytes: approved.lengthBytes)
      }
      guard
        let required = Self.stagingFreeBytes(
          staging.requiredFreeBytes, checkpoints: checkpoints, pendingShrink: pending)
      else { return }
      guard let free = freeBytes(package.packageURL.deletingLastPathComponent()) else {
        throw NativeStubFileError.freeSpaceUnavailable
      }
      guard free >= required else {
        throw MacOSFreeSpaceShortfall(requiredBytes: required, availableBytes: free)
      }
    }

    func prepare(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap
    ) async throws {
      do {
        try await populate(
          journal: journal, authorization: authorization, sourceBootstrap: sourceBootstrap)
      } catch let shortfall as MacOSFreeSpaceShortfall {
        throw try await stillNeeded(after: shortfall)
      }
    }

    /// A floor reached mid-stage names one read's need; report what the
    /// rest of the stage needs, decode included, when that is more.
    private func stillNeeded(after shortfall: MacOSFreeSpaceShortfall) async throws
      -> MacOSFreeSpaceShortfall
    {
      guard let staging else { return shortfall }
      let spans = NativeStubStagingRequirement.spans(plan.readMembers)
      let cached = try await cache?.cachedBytes(overlapping: spans) ?? 0
      let rest = staging.remaining(
        cachedBytes: cached - min(cached, stagingCachedBytes)
      ).requiredFreeBytes
      return MacOSFreeSpaceShortfall(
        requiredBytes: max(rest, shortfall.requiredBytes), availableBytes: shortfall.availableBytes)
    }

    private func populate(
      journal: URL, authorization: MachineOwnerAuthorization,
      sourceBootstrap: NativeSourceBootstrap
    ) async throws {
      let file = try NativeInstallJournalFile(url: journal, package: package, owner: owner)
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(file.readJournal())
      guard transcript.plan == approved else { throw NativeStubFileError.invalidPlan }
      // Later stages legitimately rename the version marker and finalize the
      // Recovery launch files. Their existing checkpoint validator owns retry.
      if transcript.checkpoints.contains(where: { $0.identifier == "stub-and-esp-installed" }) {
        return
      }
      guard transcript.checkpoints.map(\.identifier) == ["apfs-target-prepared"],
        try file.diskPreparationCanResume()
      else { throw NativeStubFileError.invalidPlan }
      let targetBytes = try file.readEvidence("apfs-target-prepared")
      guard transcript.checkpoints[0].evidenceDigest == SHA256Digest(hashing: targetBytes).rawValue
      else {
        throw NativeStubFileError.invalidPlan
      }
      let target = try NativeAPFSTargetEvidence.read(targetBytes)
      let snapshot = try platform.environment.snapshot()
      guard target.planDigest == approved.planDigest, target.offsetBytes == approved.offsetBytes,
        target.sizeBytes <= approved.lengthBytes, snapshot.disk == approved.storeIdentifier,
        let partition = snapshot.partitions.first(where: {
          $0.uuid == target.uuid && $0.identifier == target.partitionIdentifier
            && $0.offset == target.offsetBytes
            && $0.size == target.sizeBytes && $0.type == "Apple_APFS"
        })
      else { throw NativeStubFileError.invalidPlan }
      let volumes = try NativeStubVolumes.read(
        file.readEvidence(NativeStubVolumes.evidenceIdentifier))
      try volumes.validate(plan: approved.planDigest, target: partition, snapshot: snapshot)
      // The owner is resolved from this pass's layout, which is read again
      // right after.
      guard
        try NativeSourceOwnerAdmission(environment: platform.environment).check(
          package: package, authorization: authorization, layout: snapshot) == sourceBootstrap,
        try platform.environment.snapshot() == snapshot
      else { throw NativeHandoffValidationError.invalidOwner }
      let mounts = NativeHandoffMounts(platform.environment)
      let liveVolumes = snapshot.containers.first(where: { $0.storeUUID == target.uuid })!.volumes
      let group = liveVolumes.first(where: { $0.roles == ["System"] })!.group!
      var roots = [String: URL]()
      var stores = [String: NativeStubFileStore]()
      for role in ["System", "Data", "Preboot", "Recovery"] {
        let volume = liveVolumes.first { $0.roles == [role] }!
        let root = try mounts.mounted(volume.identifier, uuid: volume.uuid, writable: true)
        let tree = try NativeHandoffFileTree(
          root, protected: true, owner: owner,
          volumeRoot: true, volumeDevice: volume.identifier,
          verifyMount: platform.environment.verifyMount)
        roots[role] = root
        stores[role] = NativeStubFileStore(tree: tree, owner: owner, namespace: approved.planDigest)
      }
      let sourceNames = Set(plan.copies.map(\.member) + [plan.recoveryMember.name])
      let sourceMembers = plan.archive.members.filter { sourceNames.contains($0.name) }.sorted {
        $0.name < $1.name
      }
      .map {
        [
          "name": $0.name, "bytes": $0.sizeBytes, "compressed": $0.compressedSize,
          "crc32": $0.crc32,
        ] as [String: Any]
      }
      let binding = try JSONSerialization.data(
        withJSONObject: [
          "plan": approved.planDigest, "partition": target.uuid, "container": volumes.containerUUID,
          "group": group, "source": plan.source.sourceURL.absoluteString,
          "manifest": NativeStubFileStore.hash(plan.manifest), "firmware": plan.source.version,
          "members": sourceMembers,
          "bootstrap": sourceBootstrap.configuration,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
      try file.publishEvidence(binding, identifier: "native-stub-file-binding")
      let members = Dictionary(uniqueKeysWithValues: plan.archive.members.map { ($0.name, $0) })
      var installed = [Installed]()

      func fullPath(_ role: String, _ path: String) -> String {
        ["Preboot", "Recovery"].contains(role) ? group + "/" + path : path
      }
      func copy(
        _ role: String, _ path: String, dataName: String? = nil, linkTarget: String? = nil,
        produce: (NativeStubFileStore, String) async throws -> NativeStubFileIdentity
      ) async throws {
        try Task.checkCancellation()
        let relative = fullPath(role, path)
        let store = stores[role]!
        let identifier = "native-stub-file-" + String(installed.count)
        let saved: Installed
        if try file.containsEvidence(identifier) {
          saved = try JSONDecoder().decode(Installed.self, from: file.readEvidence(identifier))
          guard saved.role == role, saved.path == relative, saved.installerDataName == dataName,
            try
              (linkTarget.map { target in
                guard try store.tree.relativeLinkTarget(relative) == target else {
                  throw NativeStubFileError.changedFile
                }
                let bytes = Data(target.utf8)
                return NativeStubFileIdentity(
                  bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
              } ?? store.identity(relative)) == saved.identity
          else { throw NativeStubFileError.changedFile }
        } else {
          let identity = try await produce(store, relative)
          saved = Installed(
            role: role, path: relative, installerDataName: dataName, identity: identity)
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
          try file.publishEvidence(encoder.encode(saved), identifier: identifier)
        }
        installed.append(saved)
      }

      try stores["Data"]!.tree.createDirectory("private/var/db/dslocal")
      try stores["System"]!.tree.createDirectory("Finish Installation.app/Contents/Resources")
      for operation in plan.copies {
        let topLevelRestore = plan.isTopLevelRestore(operation)
        if let target = plan.linkTargets[operation.member] {
          try await copy(operation.role, operation.path, linkTarget: target) { store, path in
            try store.tree.relativeLink(path, target: target)
            let bytes = Data(target.utf8)
            return NativeStubFileIdentity(
              bytes: bytes.count, sha256: NativeStubFileStore.hash(bytes))
          }
        } else if topLevelRestore {
          try await restore(
            members[operation.member]!, role: operation.role, path: operation.path,
            compressed: false, dataName: operation.installerDataName)
        } else {
          try await copy(operation.role, operation.path, dataName: operation.installerDataName) {
            store, path in
            try await store.member(members[operation.member]!, archive: plan.archive, at: path)
          }
        }
      }
      try await copy(
        "Preboot", plan.restorePath + "/BuildManifest.plist", dataName: "BuildManifest.plist"
      ) {
        try await $0.data(plan.manifest, at: $1)
      }
      guard
        let sourceContainer = snapshot.containers.first(where: {
          $0.uuid == snapshot.macOSContainerUUID
        }),
        sourceContainer.volumes.contains(where: {
          $0.uuid == sourceBootstrap.systemUUID && $0.group == sourceBootstrap.groupUUID
        }),
        sourceContainer.volumes.filter({ $0.roles == ["Preboot"] }).count == 1,
        let sourcePreboot = sourceContainer.volumes.first(where: { $0.roles == ["Preboot"] })
      else { throw NativeHandoffValidationError.invalidOwner }
      let source = try mounts.mounted(
        sourcePreboot.identifier,
        uuid: sourcePreboot.uuid, sourcePreboot: true)
      let sourceTree = try NativeHandoffFileTree(
        source, protected: true, owner: owner,
        volumeRoot: true, volumeDevice: sourcePreboot.identifier,
        verifyMount: platform.environment.verifyMount)
      let admin = try sourceTree.sourceOwnerMetadata(groupUUID: sourceBootstrap.groupUUID)
      // The owner proof looks the account up under its own short name, which
      // a name typed in another case or as an alias resolves to.
      guard
        let account = try? platform.environment.ownerName(authorization.username),
        let users = try PropertyListSerialization.propertyList(from: admin, format: nil)
          as? [String: [String: Any]],
        (users[account]?["GeneratedUID"] as? String).flatMap(UUID.init(uuidString:))?
          .uuidString
          == sourceBootstrap.ownerUUID
      else { throw NativeHandoffValidationError.invalidOwner }
      try await copy(
        "Preboot", "var/db/AdminUserRecoveryInfo.plist", dataName: "AdminUserRecoveryInfo.plist"
      ) {
        try await $0.data(admin, at: $1, mode: 0o600)
      }
      try platform.protectAdmin(
        roots["Preboot"]!.appendingPathComponent(group + "/var/db/AdminUserRecoveryInfo.plist"))
      try stores["System"]!.tree.link(
        plan.restorePath,
        destination: roots["Preboot"]!.appendingPathComponent(group + "/" + plan.restorePath).path,
        admittedRoot: roots["Preboot"]!)

      func restore(
        _ member: IPSWArchiveMember, role: String, path: String, compressed: Bool,
        dataName: String? = nil
      ) async throws {
        // A completed entry has a protected per-file receipt. Recheck its
        // on-volume identity before considering another archive download or
        // decode; the copy helper rejects a changed path or content.
        if try file.containsEvidence("native-stub-file-" + String(installed.count)) {
          try await copy(role, path, dataName: dataName) { _, _ in
            throw NativeStubFileError.invalidPlan
          }
          return
        }
        // An update archive's Recovery image decodes as it streams, with no
        // copy staged on macOS.
        if member == plan.recoveryMember, let image = plan.recoveryImage {
          try await copy(role, path, dataName: dataName) {
            try await $0.updateImage(
              member, image: image, archive: plan.archive, at: $1, compressed: compressed)
          }
          return
        }
        let prefix = try await plan.archive.readPrefix(member, maximumBytes: 4)
        if prefix != Data("AEA1".utf8) {
          try await copy(role, path, dataName: dataName) {
            try await $0.member(member, archive: plan.archive, at: $1, compressed: compressed)
          }
          return
        }
        let directory = package.packageURL.deletingLastPathComponent()
          .appendingPathComponent("native-stub-decode-" + approved.planDigest)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
          throw NativeStubFileError.unsafeFile
        }
        let tree = try NativeHandoffFileTree(directory, protected: true, owner: owner)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & 0o077 == 0 else {
          throw NativeStubFileError.unsafeFile
        }
        try NativeStubDecoder.requireInactiveWorkspaces(directory, owner: owner)
        let staging = NativeStubFileStore(tree: tree, owner: owner, namespace: approved.planDigest)
        let input = directory.appendingPathComponent("input.aea")
        let output = directory.appendingPathComponent("output.dmg")
        defer {
          do {
            try NativeStubDecoder.requireInactiveWorkspaces(directory, owner: owner)
            try FileManager.default.removeItem(at: directory)
          } catch {
            // Keep a live decoder's private workspace and inputs.
          }
        }
        if try !tree.isAbsent("output.dmg") {
          let descriptor = try tree.fileDescriptor("output.dmg")
          defer { close(descriptor) }
          var info = stat()
          guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == owner, info.st_mode & 0o022 == 0, info.st_nlink == 1
          else { throw NativeStubFileError.unsafeFile }
          try FileManager.default.removeItem(at: output)
        }
        let identity = try await staging.member(
          member, archive: plan.archive, at: "input.aea", mode: 0o600)
        guard let executable = package.restoreImageURL else {
          throw NativeStubFileError.invalidImage
        }
        guard let free = freeBytes(directory) else {
          throw NativeStubFileError.freeSpaceUnavailable
        }
        let needed = NativeStubStagingRequirement.decodeFreeBytes(
          memberBytes: UInt64(member.sizeBytes))
        guard free >= needed else {
          throw MacOSFreeSpaceShortfall(requiredBytes: needed, availableBytes: free)
        }
        let lease = try file.leaseForChild()
        defer { try? lease.close() }
        try await platform.decode(input, identity.sha256, output, executable, lease)
        if compressed {
          let descriptor = open(output.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          guard descriptor >= 0 else { throw NativeStubFileError.invalidImage }
          defer { close(descriptor) }
          var info = stat()
          var trailer = [UInt8](repeating: 0, count: 4)
          guard fstat(descriptor, &info) == 0, info.st_size >= 512,
            pread(descriptor, &trailer, 4, info.st_size - 512) == 4, trailer == Array("koly".utf8)
          else { throw NativeStubFileError.invalidImage }
        }
        try await copy(role, path, dataName: dataName) {
          try await $0.local(output, at: $1, compressed: compressed)
        }
      }
      try await restore(
        plan.recoveryMember, role: "Recovery", path: "usr/standalone/firmware/arm64eBaseSystem.dmg",
        compressed: true)
      try await copy(
        "System", "System/Library/CoreServices/SystemVersion.plist", dataName: "SystemVersion.plist"
      ) {
        try await $0.data(plan.systemVersion, at: $1)
      }
      let launcher =
        "#!/bin/sh\nset -eu\nresources=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n"
        + "exec \"$resources/../../../\(InstallerProductIdentity.recoveryAppBundleName)/\(PublishedContractNames.recoveryExecutablePath)\" \"$@\"\n"
      try await copy("System", "Finish Installation.app/Contents/Resources/step2.sh") {
        try await $0.data(Data(launcher.utf8), at: $1, mode: 0o755)
      }
      let marker = try PropertyListSerialization.data(
        fromPropertyList: [
          "AppName": InstallerProductIdentity.recoveryAppBundleName,
          "ProductBuildVersion": "00A191", "ProductVersion": "12.1",
        ],
        format: .xml, options: 0)
      try await copy("System", ".IAPhysicalMedia") { try await $0.data(marker, at: $1) }
      try platform.configureSystem(roots["System"]!)
      guard let metadata = try JSONSerialization.jsonObject(with: plan.stubInfo) as? [String: Any]
      else { throw NativeStubFileError.invalidPlan }
      var info = metadata
      info["vgid"] = group
      info["admin_users"] = try users.mapValues { value -> [String: Any] in
        guard let uid = value["GeneratedUID"], let name = value["RealName"] else {
          throw NativeHandoffValidationError.invalidOwner
        }
        return ["uid": uid, "real_name": name]
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let linkPaths = Set(
        plan.copies.filter { plan.linkTargets[$0.member] != nil }.map {
          fullPath($0.role, $0.path)
        })
      let links = installed.filter { linkPaths.contains($0.path) }
      // The compatibility consumer's file list is deliberately regular-only.
      // Native-owned links retain separate protected evidence and are checked
      // through the same per-entry receipts before each continuation.
      if !links.isEmpty {
        let targets = Dictionary(
          uniqueKeysWithValues: plan.copies.compactMap { operation -> (String, String)? in
            guard let target = plan.linkTargets[operation.member] else { return nil }
            return (fullPath(operation.role, operation.path), target)
          })
        try file.publishEvidence(
          JSONSerialization.data(
            withJSONObject: [
              "plan_digest": approved.planDigest, "group_uuid": group,
              "binding_sha256": NativeStubFileStore.hash(binding), "targets": targets,
              "links": try JSONSerialization.jsonObject(with: encoder.encode(links)),
            ], options: [.sortedKeys, .withoutEscapingSlashes]), identifier: "native-stub-links")
      }
      let receipt: [String: Any] = [
        "schema": 1, "plan_digest": approved.planDigest,
        "binding_sha256": NativeStubFileStore.hash(binding), "group_uuid": group,
        "source_url": plan.source.sourceURL.absoluteString, "firmware_version": plan.source.version,
        "files": try JSONSerialization.jsonObject(
          with: encoder.encode(installed.filter { !linkPaths.contains($0.path) })),
        "stub_info": info,
      ]
      try file.publishEvidence(
        JSONSerialization.data(
          withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes]),
        identifier: "native-stub-files")
    }
  }
#endif
