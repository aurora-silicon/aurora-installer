#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import RecoveryAccountCore

  /// Why a Stage 1 update stopped.
  enum NativeStage1UpdateError: Error, Equatable, Sendable {
    /// Recovery hasn't finished setting up this installation.
    case setupUnfinished
    /// Its records don't match the volumes and partitions on the disk.
    case changedInstallation
    /// It was set up for the other kind of Stage 1 than this Mac starts.
    case wrongBootMode
    /// This release's Stage 1 can't be installed into an existing installation.
    case unsupportedStage1
    /// The new Stage 1 is larger than the installer accepts.
    case stage1TooLarge(bytes: UInt64)
    /// The startup volume lacks the room Recovery needs to enroll it.
    case notEnoughSpace(requiredBytes: UInt64, availableBytes: UInt64)
    /// The EFI partition lacks the boot file the new Stage 1 loads.
    case missingStage2(path: String)

    var summary: String {
      func megabytes(_ bytes: UInt64) -> String { "\((bytes + 999_999) / 1_000_000) MB" }
      switch self {
      case .setupUnfinished:
        return "Finish setting up this installation in Recovery first."
      case .changedInstallation:
        return "This installation's records don't match its volumes and partitions, so its "
          + "boot loader wasn't changed."
      case .wrongBootMode:
        return
          "This installation was set up for a different kind of boot loader than this Mac uses."
      case .unsupportedStage1:
        return "This release's boot loader can't be installed into an existing installation."
      case .stage1TooLarge(let bytes):
        return
          "This release's boot loader is \(megabytes(bytes)), larger than the installer accepts."
      case .notEnoughSpace(let required, let available):
        return "The installation's startup volume has \(megabytes(available)) free, but updating "
          + "the boot loader needs \(megabytes(required))."
      case .missingStage2(let path):
        return "The EFI partition has no \(path) yet. Start Linux, install its updates, then "
          + "update the boot loader again."
      }
    }
  }

  /// A failure that says whether the stub's Recovery files had started to change.
  struct NativeStage1UpdateFailure: Error, Sendable {
    let underlying: any Error
    let diskChanged: Bool
  }

  /// The Stage 1 this release gives one installation, filled for its EFI partition.
  struct NativeStage1UpdateCandidate: Equatable, Sendable {
    static let maximumBytes = 64 << 20

    let mode: NativeRecoveryBootMode
    /// The filled raw Stage 1. Recovery keeps it in both modes.
    let raw: Data
    /// The filled Mach-O boot object, on chips that enroll one.
    let machO: Data?
    /// The ESP file it chainloads.
    let stage2Path: String
    /// The padded object's whole size, which Recovery needs free to enroll it.
    let expandedBytes: UInt64?

    /// What Recovery enrolls and records in its receipt.
    var enrolled: Data { machO ?? raw }
    var enrolledSHA256: String { NativeStubFileStore.hash(enrolled) }
    var stage1Path: String { NativeStage1Update.stage1Path(mode) }

    init(plan: NativeESPPayloadPlan, espUUID: String) throws {
      try self.init(
        stage1: plan.stage1, machO: plan.stage1MachO, windowMilliseconds: plan.windowMilliseconds,
        legacy: plan.usesLegacyStage1, espUUID: espUUID)
    }

    /// The same fill and checks as a fresh installation, then a read-back of
    /// what Recovery checks before it enrolls.
    init(
      stage1: Data, machO object: Data?, windowMilliseconds: UInt32, legacy: Bool, espUUID: String
    )
      throws
    {
      guard !legacy else { throw NativeStage1UpdateError.unsupportedStage1 }
      for bytes in [stage1, object].compactMap({ $0 }) where bytes.count > Self.maximumBytes {
        throw NativeStage1UpdateError.stage1TooLarge(bytes: UInt64(bytes.count))
      }
      let uuid = espUUID.lowercased()
      let path = AuraStage1Format.stage2Path(machO: object != nil)
      let raw = try NativeBootChain.fillStage1(
        stage1, uuid: uuid, path: path, windowMilliseconds: windowMilliseconds)
      guard let configuration = try? Stage1Configuration.read(raw),
        configuration.espUUID.lowercased() == uuid, configuration.stage2Path == path
      else { throw NativeBootChainError.invalidStage1 }
      var filled: Data?
      var expanded: UInt64?
      if let object {
        do {
          let carried = try MachOBootObject.fill(object, raw: stage1, filled: raw)
          expanded = try MachOBootObject.expandExecuteWindow(carried).size
          filled = carried
        } catch is MachOBootObject.Invalid {
          throw NativeBootChainError.invalidStage1
        }
      }
      mode = object == nil ? .raw : .macho
      self.raw = raw
      machO = filled
      stage2Path = path
      expandedBytes = expanded
    }
  }

  /// What the stub records about one installation, read from its System volume.
  struct NativeStage1UpdateRecords: @unchecked Sendable {
    let configuration: [String: Any]
    let manifest: [String: Any]
    let receipt: [String: Any]
    /// The Stage 2 path install-config.json names now.
    let stage2Path: String
    var volumeName: String { configuration["volumeName"] as? String ?? "" }
  }

  /// The identities recognition found, which the records must name.
  struct NativeStage1UpdateBinding: Equatable, Sendable {
    let systemUUID: String
    let groupUUID: String
    let prebootUUID: String
    let espUUID: String
    let machO: Bool
  }

  enum NativeStage1UpdateDecision: Equatable, Sendable {
    /// The enrolled Stage 1 and its Recovery copy are already this one.
    case unchanged
    /// It's enrolled, but Recovery holds another one an unfinished update left.
    case restage
    /// Recovery should enroll it.
    case update
  }

  enum NativeStage1Update {
    static let installData = "Aurora/Recovery/InstallData"
    static let receiptPath = "Aurora/Recovery/State/installation.json"
    static let pendingPath = "Aurora/Recovery/State/installation.pending.json"
    static let stagingPrefix = ".stage1-update-"
    /// Room kept beyond what Recovery itself needs: the new files and their copies.
    static let reserveBytes: UInt64 = 32 << 20
    static let checkpoint = "stage1-update-staged"

    static func stage1Path(_ mode: NativeRecoveryBootMode) -> String {
      mode == .raw ? "raw/aura-raw.bin" : "macho/aura-boot.macho"
    }

    /// Checks the stub's records against what recognition found. A Mach-O
    /// installation an earlier installer made still names `m1n1/boot.bin`.
    static func records(
      configuration: Data, manifest: Data, receipt: Data?, pending: Bool,
      binding: NativeStage1UpdateBinding
    ) throws -> NativeStage1UpdateRecords {
      let required: Set<String> = [
        "schema", "volumeName", "systemUUID", "groupUUID", "prebootUUID", "espUUID",
        "bootMode", "stage2Path", "bootstrap",
      ]
      guard let config = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        Set(config.keys).subtracting(["allowCustomBootArguments"]) == required,
        config["schema"] as? Int == 2,
        config["systemUUID"] as? String == binding.systemUUID,
        config["groupUUID"] as? String == binding.groupUUID,
        config["prebootUUID"] as? String == binding.prebootUUID,
        (config["espUUID"] as? String)?.uppercased() == binding.espUUID.uppercased(),
        let name = config["volumeName"] as? String, !name.isEmpty,
        let mode = (config["bootMode"] as? String).flatMap(NativeRecoveryBootMode.init),
        let path = config["stage2Path"] as? String
      else { throw NativeStage1UpdateError.changedInstallation }
      guard mode == (binding.machO ? .macho : .raw) else {
        throw NativeStage1UpdateError.wrongBootMode
      }
      let paths =
        mode == .raw
        ? [AuraStage1Format.standardStage2Path]
        : [AuraStage1Format.confinedStage2Path, AuraStage1Format.standardStage2Path]
      guard paths.contains(path) else { throw NativeStage1UpdateError.changedInstallation }
      guard let payloads = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
        payloads["schema"] as? Int == 2,
        let files = payloads["files"] as? [String: [String: Any]],
        files["raw/aura-raw.bin"] != nil, files["raw/boot.bin"] != nil
      else { throw NativeStage1UpdateError.changedInstallation }
      guard !pending, let receipt,
        let record = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
        record["status"] as? String == "installed",
        record["mode"] as? String == mode.rawValue,
        record["stage1SHA256"] is String, record["stage2Path"] is String
      else { throw NativeStage1UpdateError.setupUnfinished }
      return NativeStage1UpdateRecords(
        configuration: config, manifest: payloads, receipt: record, stage2Path: path)
    }

    static func decide(
      _ candidate: NativeStage1UpdateCandidate, records: NativeStage1UpdateRecords
    ) -> NativeStage1UpdateDecision {
      let receipt = records.receipt
      let enrolled =
        receipt["stage1SHA256"] as? String == candidate.enrolledSHA256
        && receipt["stage2Path"] as? String == candidate.stage2Path
        && receipt["mode"] as? String == candidate.mode.rawValue
      let files = records.manifest["files"] as? [String: [String: Any]] ?? [:]
      let modes = records.manifest["modes"] as? [String: [String: Any]]
      let staged =
        files[candidate.stage1Path]?["sha256"] as? String == candidate.enrolledSHA256
        && files["raw/aura-raw.bin"]?["sha256"] as? String
          == NativeStubFileStore.hash(candidate.raw)
        && records.manifest["defaultMode"] as? String == candidate.mode.rawValue
        && modes?[candidate.mode.rawValue]?["espPath"] as? String == candidate.stage2Path
        && records.stage2Path == candidate.stage2Path
      if enrolled { return staged ? .unchanged : .restage }
      return .update
    }

    /// Recovery reads the whole padded object, so the volume needs room for it
    /// as well as the new files.
    static func requireSpace(_ candidate: NativeStage1UpdateCandidate, freeBytes: UInt64) throws {
      let files = UInt64(candidate.raw.count + (candidate.machO?.count ?? 0))
      let required =
        (candidate.expandedBytes ?? UInt64(candidate.raw.count)) + files + reserveBytes
      guard freeBytes >= required else {
        throw NativeStage1UpdateError.notEnoughSpace(
          requiredBytes: required, availableBytes: freeBytes)
      }
    }

    /// The new Stage 1 loads `path`, which only the distribution writes.
    static func requireStage2(bytes: Int?, path: String) throws {
      let limit =
        path == AuraStage1Format.confinedStage2Path ? Int(ExecuteWindow.auraSlot) : 64 << 20
      guard let bytes, bytes > 0, bytes <= limit else {
        throw NativeStage1UpdateError.missingStage2(path: path)
      }
    }

    /// The installation's System, Data and Preboot volumes in its container.
    static func volumes(_ target: NativePreservedInstallTarget, snapshot: RemovalSnapshot) throws
      -> (system: RemovalVolume, data: RemovalVolume, preboot: RemovalVolume)
    {
      let containers = snapshot.containers.filter { $0.storeUUID == target.stub.uuid }
      guard containers.count == 1 else { throw NativeStage1UpdateError.changedInstallation }
      let volumes = containers[0].volumes
      let systems = volumes.filter {
        $0.roles == ["System"] && $0.group == target.group && $0.name == target.title
      }
      let data = volumes.filter { $0.roles == ["Data"] && $0.group == target.group }
      let preboot = volumes.filter { $0.roles == ["Preboot"] }
      guard systems.count == 1, data.count == 1, preboot.count == 1, !systems[0].identifier.isEmpty
      else { throw NativeStage1UpdateError.changedInstallation }
      return (systems[0], data[0], preboot[0])
    }

    /// The approved plan's transcript, then this update's evidence and outcome.
    static func transcript(
      _ base: Data, planDigest: String, staged: NativeStage1UpdateCandidate?
    ) throws -> Data {
      var result = base
      var sequence = base.split(separator: 10).count
      func append(_ type: String, _ payload: [String: Any]) throws {
        sequence += 1
        var line = try JSONSerialization.data(
          withJSONObject: [
            "schema_version": 1, "sequence": sequence, "type": type, "payload": payload,
          ], options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(10)
        result.append(line)
      }
      if let staged {
        let evidence = try JSONSerialization.data(
          withJSONObject: [
            "plan_digest": planDigest, "mode": staged.mode.rawValue,
            "stage1_sha256": staged.enrolledSHA256, "stage2_path": staged.stage2Path,
          ], options: [.sortedKeys, .withoutEscapingSlashes])
        try append(
          "checkpoint",
          [
            "plan_digest": planDigest, "identifier": checkpoint, "phase": "awaiting_recovery",
            "evidence_digest": SHA256Digest(hashing: evidence).rawValue,
          ])
      }
      try append(
        "completion",
        ["plan_digest": planDigest, "outcome": staged == nil ? "installed" : "awaiting_recovery"])
      _ = try AppleInstallerTrustCore().validateEngineTranscript(result)
      return result
    }
  }

  /// Reads and replaces the stub's Recovery inputs. The new directory is built
  /// beside the old one and swapped in with one rename, so Recovery sees either
  /// the old inputs or the new ones.
  struct NativeStage1UpdateStaging: Sendable {
    let system: NativeHandoffFileTree
    let systemRoot: URL
    var owner: uid_t = 0

    func records(binding: NativeStage1UpdateBinding) throws -> NativeStage1UpdateRecords {
      let root = NativeStage1Update.installData
      let receipt =
        try system.isAbsent(NativeStage1Update.receiptPath)
        ? nil : try system.read(NativeStage1Update.receiptPath, maximum: 65_536)
      return try NativeStage1Update.records(
        configuration: system.read(root + "/install-config.json", maximum: 65_536),
        manifest: system.read(root + "/AuraPayloads/manifest.json", maximum: 1 << 20),
        receipt: receipt, pending: !(try system.isAbsent(NativeStage1Update.pendingPath)),
        binding: binding)
    }

    /// `stage2Baseline` replaces Recovery's copy of Stage 2 when the new
    /// Stage 1 loads another path; the ESP itself is never written.
    func stage(
      _ candidate: NativeStage1UpdateCandidate, records: NativeStage1UpdateRecords,
      stage2Baseline: Data?
    ) async throws {
      var configuration = records.configuration
      configuration["stage2Path"] = candidate.stage2Path
      var manifest = records.manifest
      var files = manifest["files"] as? [String: [String: Any]] ?? [:]
      var replaced = ["raw/aura-raw.bin": candidate.raw]
      if let machO = candidate.machO { replaced["macho/aura-boot.macho"] = machO }
      if let stage2Baseline { replaced["raw/boot.bin"] = stage2Baseline }
      for (name, bytes) in replaced {
        files[name] = ["sha256": NativeStubFileStore.hash(bytes), "bytes": bytes.count]
      }
      manifest["files"] = files
      manifest["defaultMode"] = candidate.mode.rawValue
      manifest["modes"] = [candidate.mode.rawValue: ["espPath": candidate.stage2Path]]
      let configurationBytes = try json(configuration)
      let manifestBytes = try json(manifest)

      let old = try NativeHandoffFileTree(
        systemRoot.appendingPathComponent(NativeStage1Update.installData), protected: true,
        owner: owner)
      let oldStore = NativeStubFileStore(tree: old, owner: owner)
      var kept = [String: NativeStubFileIdentity]()
      for (name, entry) in files where replaced[name] == nil {
        guard let sha = entry["sha256"] as? String, let bytes = entry["bytes"] as? Int,
          try oldStore.identity("AuraPayloads/" + name, maximum: 256 << 20)
            == NativeStubFileIdentity(bytes: bytes, sha256: sha)
        else { throw NativeStage1UpdateError.changedInstallation }
        kept[name] = NativeStubFileIdentity(bytes: bytes, sha256: sha)
      }

      let name = NativeStage1Update.stagingPrefix + UUID().uuidString
      let relative = "Aurora/Recovery/" + name
      let candidateURL = systemRoot.appendingPathComponent(relative)
      try system.createDirectory(relative)
      var swapped = false
      defer {
        // Before the swap this is the new copy; after it, the old directory.
        try? FileManager.default.removeItem(at: candidateURL)
        if swapped {
          try? RecoveryFileTransaction.flushDirectory(candidateURL.deletingLastPathComponent())
        }
      }
      let tree = try NativeHandoffFileTree(candidateURL, protected: true, owner: owner)
      let store = NativeStubFileStore(tree: tree, owner: owner, namespace: name)
      var expected = [String: NativeStubFileIdentity]()
      expected["install-config.json"] = try await store.data(
        configurationBytes, at: "install-config.json", mode: 0o600)
      expected["AuraPayloads/manifest.json"] = try await store.data(
        manifestBytes, at: "AuraPayloads/manifest.json", mode: 0o600)
      for (file, bytes) in replaced {
        expected["AuraPayloads/" + file] = try await store.data(
          bytes, at: "AuraPayloads/" + file, mode: 0o600)
      }
      for (file, identity) in kept {
        expected["AuraPayloads/" + file] = try await store.file(
          old, path: "AuraPayloads/" + file, identity: identity, at: "AuraPayloads/" + file)
      }
      try verify(candidateURL, expected: expected)
      try RecoveryFileTransaction.flushTree(candidateURL)
      let (parent, leaf) = try system.writableParent(NativeStage1Update.installData)
      defer { close(parent) }
      guard renameatx_np(parent, name, parent, leaf, UInt32(RENAME_SWAP)) == 0 else {
        throw NativeStubFileError.writeFailed
      }
      swapped = true
      guard fsync(parent) == 0 else { throw NativeStubFileError.writeFailed }
    }

    private func verify(_ root: URL, expected: [String: NativeStubFileIdentity]) throws {
      let tree = try NativeHandoffFileTree(root, protected: true, owner: owner)
      let store = NativeStubFileStore(tree: tree, owner: owner)
      var actual = Set<String>()
      for name in try NativeFirmwareInputFiles.relativeEntries(root: root, maximum: 1024) {
        var info = stat()
        guard lstat(root.appendingPathComponent(name).path, &info) == 0 else {
          throw NativeHandoffValidationError.unsafePath
        }
        if info.st_mode & S_IFMT == S_IFDIR { continue }
        guard let identity = expected[name],
          try store.identity(name, maximum: 256 << 20) == identity
        else { throw NativeHandoffValidationError.changedContent }
        actual.insert(name)
      }
      guard actual == Set(expected.keys) else { throw NativeHandoffValidationError.changedContent }
    }

    private func json(_ value: [String: Any]) throws -> Data {
      try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
  }

  protocol NativeStage1UpdateExecuting: Sendable {
    func execute(_ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization)
      async throws -> Data
  }

  /// Stages this release's Stage 1 for one recognized installation and sends
  /// it to Recovery, which enrolls it with the owner's password. Linux, its
  /// partitions and every file on the EFI partition stay as they are.
  struct NativeStage1UpdateCoordinator: NativeStage1UpdateExecuting {
    var owner: uid_t = 0
    var disks: NativeAPFSPlatform = .live
    var environment: NativeHandoffEnvironment = .live
    var validatePayload: @Sendable (ImportedEngineHandoffPackage) async throws -> Void = {
      try await NativePayloadPreflight.check($0)
    }
    var validateSourceOwner:
      @Sendable (ImportedEngineHandoffPackage, MachineOwnerAuthorization) throws -> Void = {
        _ = try NativeSourceOwnerAdmission().check(package: $0, authorization: $1)
      }
    var prepareRecoveryTemplate:
      @Sendable (ImportedEngineHandoffPackage) throws -> PreparedNativeRecoveryTemplate = {
        try NativeRecoveryTemplate.prepare(package: $0)
      }
    var updateRecoveryApp: @Sendable (RecoveryAccountTarget) throws -> Void = {
      try RecoveryAccountHandoff.updateRecoveryApp(for: $0)
    }
    var bless: @Sendable ([String], Data, Data) throws -> Void = {
      try MacRemovalDiskOperator.runBless($0, input: $1, secret: $2)
    }

    func execute(_ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization)
      async throws -> Data
    {
      var changed = false
      do {
        return try await run(package, authorization: authorization, changed: &changed)
      } catch {
        throw NativeStage1UpdateFailure(underlying: error, diskChanged: changed)
      }
    }

    private func run(
      _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
      changed: inout Bool
    ) async throws -> Data {
      guard package.installationIntent == .reinstall else {
        throw NativePreservedInstallError.unavailable
      }
      let approved = try EngineHandoffPackageImporter().stage1UpdatePlan(package, owner: owner)
      try await validatePayload(package)
      try validateSourceOwner(package, authorization)
      let metadata = try NativeHandoffFileTree(
        package.packageURL, protected: true, owner: owner
      ).read(package.metadataURL.lastPathComponent, maximum: 65_536)
      guard SHA256Digest(hashing: metadata).rawValue == approved.metadataDigest else {
        throw NativePreservedInstallError.unavailable
      }
      let facts = try disks.collect()
      guard facts.deviceIdentifier == package.deviceIdentifier,
        facts.disk.snapshot.disk == approved.storeIdentifier
      else { throw NativePreservedInstallError.changedLayout }
      let firmware = try NativeFirmwareSelection.choose(
        deviceIdentifier: package.deviceIdentifier,
        facts: .init(deviceIdentifier: facts.deviceIdentifier, hardware: facts.hardware),
        metadata: NativeInstallationMetadata(data: metadata),
        policy: NativeInspectionPolicy.sealed())

      // Only an installation recognition fully confirms, at the approved extent.
      let target = try NativePreservedInstallTarget.recognize(
        facts.disk, sourceIdentifier: approved.sourceIdentifier)
      guard approved.offsetBytes == target.stub.offset,
        approved.lengthBytes == target.root.end - target.stub.offset
      else { throw NativePreservedInstallError.changedLayout }
      let base = try NativePreservedInstallAdmission.approvedTranscript(
        approved: approved, metadata: metadata, disk: facts.disk, stubBytes: firmware.stubBytes,
        identityDigest: target.identityDigest)
      let volumes = try NativeStage1Update.volumes(target, snapshot: facts.disk.snapshot)
      let machO = AuraStage1Format.usesMachO(chipID: facts.hardware.chipID)
      let binding = NativeStage1UpdateBinding(
        systemUUID: try NativeSourceBootstrap.uuid(volumes.system.uuid),
        groupUUID: try NativeSourceBootstrap.uuid(target.group),
        prebootUUID: try NativeSourceBootstrap.uuid(volumes.preboot.uuid),
        espUUID: target.esp.uuid, machO: machO)

      let archive = try await IPSWArchive.open(
        NativePayloadRangeReader(package.payloadURL, owner: owner))
      guard
        let plan = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive, device: approved.deviceIdentifier,
          firmware: firmware.version.components(separatedBy: " ")[0], machOStage1: machO)
      else { throw NativeStage1UpdateError.unsupportedStage1 }
      let candidate = try NativeStage1UpdateCandidate(plan: plan, espUUID: target.esp.uuid)

      let mounts = NativeHandoffMounts(environment)
      let systemURL = try mounts.mounted(volumes.system.identifier, uuid: volumes.system.uuid)
      let system = try NativeHandoffFileTree(
        systemURL, protected: true, owner: owner, volumeRoot: true,
        volumeDevice: volumes.system.identifier, verifyMount: environment.verifyMount)
      let staging = NativeStage1UpdateStaging(system: system, systemRoot: systemURL, owner: owner)
      let records: NativeStage1UpdateRecords
      do {
        records = try staging.records(binding: binding)
      } catch let refusal as NativeStage1UpdateError {
        throw refusal
      } catch {
        // Missing or unreadable records aren't an installation this can update.
        throw NativeStage1UpdateError.changedInstallation
      }
      let decision = NativeStage1Update.decide(candidate, records: records)
      if decision == .unchanged {
        InstallerLog.progress("The boot loader is already up to date. Nothing was changed.")
        return try NativeStage1Update.transcript(
          base, planDigest: approved.planDigest, staged: nil)
      }

      // The new Stage 1 needs its Stage 2 on the ESP, written by the distribution.
      let espURL = try mounts.mounted(
        target.esp.identifier, uuid: target.esp.uuid, key: "DiskUUID")
      let esp = try NativeHandoffFileTree(
        espURL, protected: false, owner: owner, volumeRoot: true,
        volumeDevice: target.esp.identifier, verifyMount: environment.verifyMount)
      try NativeStage1Update.requireStage2(
        bytes: try? esp.read(candidate.stage2Path, maximum: 64 << 20).count,
        path: candidate.stage2Path)
      guard
        let free = facts.disk.containers.first(where: { $0.storeUUID == target.stub.uuid })?.free
      else { throw NativeStage1UpdateError.changedInstallation }
      try NativeStage1Update.requireSpace(candidate, freeBytes: free)
      var baseline: Data?
      if records.stage2Path != candidate.stage2Path {
        guard let entry = plan.entries.first(where: { $0.path == candidate.stage2Path }) else {
          throw NativeBootChainError.missingConfinedStage2
        }
        baseline = try await archive.read(entry.member, maximumBytes: 64 << 20)
      }
      let recovery = try prepareRecoveryTemplate(package)
      defer { recovery.remove() }
      let accountTarget = RecoveryAccountTarget(
        volumeName: records.volumeName, systemUUID: binding.systemUUID,
        dataUUID: try NativeSourceBootstrap.uuid(volumes.data.uuid), groupUUID: binding.groupUUID,
        prebootUUID: binding.prebootUUID)
      try accountTarget.validate()
      // Nothing above wrote to the disk.
      _ = try environment.command("/sbin/mount", ["-u", "-w", systemURL.path])
      changed = true
      try await staging.stage(candidate, records: records, stage2Baseline: baseline)
      InstallerLog.progress(
        "Staged the new \(candidate.mode.rawValue) Stage 1 \(candidate.enrolledSHA256.prefix(12)) "
          + "for Recovery.")
      try updateRecoveryApp(accountTarget)
      if decision == .restage {
        try system.prepareForStartup()
        InstallerLog.progress("The boot loader was already enrolled; Recovery's copy now matches.")
        return try NativeStage1Update.transcript(
          base, planDigest: approved.planDigest, staged: nil)
      }
      // As the installation's own handoff: start this volume's Recovery next.
      try system.prepareForAuthorization()
      do {
        try bless(
          [
            "--setBoot", "--device", "/dev/" + volumes.system.identifier,
            "--user", authorization.username, "--stdinpass",
          ], authorization.password + Data([10]), authorization.password)
      } catch { throw NativeHandoffValidationError.authorizationFailed }
      let selected = try environment.command("/usr/sbin/bless", ["--getBoot", "--plist"])
      guard
        let selection = try PropertyListSerialization.propertyList(from: selected, format: nil)
          as? [String: Any], let volume = selection["Boot Volume"] as? String
      else { throw NativeHandoffValidationError.invalidTarget }
      try RecoveryAccountHandoff.requireStartupSelection(
        accountTarget, info: environment.disk(volume))
      try system.prepareForRecovery()
      return try NativeStage1Update.transcript(
        base, planDigest: approved.planDigest, staged: candidate)
    }
  }
#endif
