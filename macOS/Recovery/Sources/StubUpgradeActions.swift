import Darwin
import Foundation
import IOKit

/// The stub volumes an upgrade request names, as Recovery finds them.
struct StubUpgradeVolumes {
  let systemUUID: String
  let groupUUID: String
  let prebootUUID: String
  let recoveryUUID: String
  let dataUUID: String
  /// The APFS container's physical store (e.g. disk0s3).
  let physicalStore: String
}

/// Everything an upgrade has checked before it changes anything.
struct StubUpgradePreparation {
  let request: StubUpgradeRequest
  let volumes: StubUpgradeVolumes
  let facts: StubUpgradeFacts
  let esp: URL
  let preboot: URL
  let recovery: URL
  let plan: RestoreImageStubPlan
  let directory: RestoreImageDirectory
  let read: RestoreImageDirectory.Read
  let journal: RestoreImageStubUpgrade.Journal?
  let stage1: StubUpgradeStage1
}

/// The staged Stage 1 filled for this EFI partition and checked, with the
/// keys the installation recorded.
struct StubUpgradeStage1 {
  let mode: AuraBootMode
  let stage2Path: String
  let enrolled: Data
  let update: Stage1Reenrollment
}

/// The in-place startup firmware upgrade (UPGRADE-FLOW.md section 4.2): the
/// checks (StubUpgradeCheck), the files (RestoreImageStubUpgrade), then the
/// same commands setup and Update startup software run: `bless` with the
/// owner (as repairRecoveryBoot), `bputil -nc` and `kmutil configure-boot`
/// of the staged Stage 1 filled for this EFI partition (stageStage1,
/// RecoveryBootPolicy, AuraBootMode.enrollmentArguments, through
/// `authorized`), then the receipts, `asahi/stub_info.json`, and the launcher
/// disarmed as reenrollStage1 disarms it.
extension RecoveryActions {
  static var upgradeConfig: URL { volume.appendingPathComponent(StubUpgradeRequest.configPath) }
  static var upgradeJournal: URL { state.appendingPathComponent("upgrade-journal.json") }
  static var upgradeReceipt: URL { state.appendingPathComponent("upgrade.json") }

  /// A regular file (not a link) of at most `limit` bytes; nil when absent.
  /// Linux's APFS driver writes the request, so its owner isn't required.
  static func boundedRead(_ url: URL, limit: Int) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw RecoveryFailure(message: "Couldn't read \(url.lastPathComponent).")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit
    else { throw RecoveryFailure(message: "\(url.lastPathComponent) is not a file Aurora reads.") }
    return try handle.readToEnd() ?? Data()
  }

  /// `.IAPhysicalMedia` is there and opens this app.
  static var launcherArmed: Bool {
    guard
      let bytes = try? boundedRead(volume.appendingPathComponent(".IAPhysicalMedia"), limit: 65536),
      let launch = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any]
    else { return false }
    return launch["AppName"] as? String == "Aurora Installer.app"
  }

  /// The upgrade Linux staged on this volume, while the launcher is armed for it.
  static func pendingStubUpgrade() -> StubUpgradeRequest? {
    guard launcherArmed, let bytes = try? boundedRead(upgradeConfig, limit: 65536) else {
      return nil
    }
    return try? StubUpgradeRequest.decode(bytes)
  }

  /// This app's System volume and its group's other volumes, checked against the request.
  static func stubUpgradeVolume() throws -> StubUpgradeVolumes {
    guard let request = pendingStubUpgrade() else { throw StubUpgradeCheck.Refusal.notStaged }
    let info = try disk(volume.path)
    guard let system = (info["VolumeUUID"] as? String)?.uppercased(),
      let group = (info["APFSVolumeGroupID"] as? String)?.uppercased(),
      info["MountPoint"] as? String == volume.path,
      let container = info["APFSContainerReference"] as? String
    else { throw RecoveryFailure(message: "Cannot identify the selected volume.") }
    guard group == request.group else { throw StubUpgradeCheck.Refusal.otherVolume }
    let bytes = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
    guard
      let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any],
      let matches = (tree["Containers"] as? [[String: Any]])?.filter({
        $0["ContainerReference"] as? String == container
      }), matches.count == 1, let store = matches[0]["DesignatedPhysicalStore"] as? String
    else { throw RecoveryFailure(message: "Cannot inspect this volume's APFS container.") }
    let volumes = matches[0]["Volumes"] as? [[String: Any]] ?? []
    func only(_ role: String) throws -> String {
      let found = volumes.filter { ($0["Roles"] as? [String] ?? []).contains(role) }
      guard found.count == 1, let id = (found[0]["APFSVolumeUUID"] as? String)?.uppercased() else {
        throw RecoveryFailure(message: "This startup container has no single \(role) volume.")
      }
      return id
    }
    return StubUpgradeVolumes(
      systemUUID: system, groupUUID: group, prebootUUID: try only("Preboot"),
      recoveryUUID: try only("Recovery"),
      dataUUID: try RecoveryAccountInstaller.pairedDataUUID(systemUUID: system, groupUUID: group),
      physicalStore: store)
  }

  /// The volume `uuid` mounted, read-write when `writable`.
  static func mountedVolume(_ uuid: String, writable: Bool) throws -> URL {
    var info = try disk(uuid)
    if (info["MountPoint"] as? String)?.isEmpty != false {
      try run("/usr/sbin/diskutil", writable ? ["mount", uuid] : ["mount", "readOnly", uuid])
      info = try disk(uuid)
    }
    guard (info["VolumeUUID"] as? String)?.uppercased() == uuid,
      let mount = info["MountPoint"] as? String, mount.hasPrefix("/")
    else { throw RecoveryFailure(message: "Cannot mount a volume of this startup container.") }
    if writable, info["WritableVolume"] as? Bool == false {
      try run("/sbin/mount", ["-u", "-w", mount])
    }
    return URL(fileURLWithPath: mount)
  }

  /// A property of an IODeviceTree node.
  static func deviceTree(_ path: String, _ name: String) -> Data? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? Data
  }
  static func deviceTreeStrings(_ path: String, _ name: String) -> [String] {
    (deviceTree(path, name) ?? Data()).split(separator: 0).map {
      String(decoding: $0, as: UTF8.self)
    }
  }
  /// This Mac's board, as the boot firmware reports it.
  static func boardID() -> UInt64? {
    guard let bytes = deviceTree("IODeviceTree:/chosen", "board-id"), [4, 8].contains(bytes.count)
    else { return nil }
    return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
  }

  /// Whether an attached disk image is the stub's Recovery image: removing
  /// it then frees nothing until Recovery stops.
  static func recoveryImageHeld(group: String) -> Bool {
    guard let bytes = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
      let info = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any]
    else {
      InstallerLog.shared.append(
        "hdiutil info failed; counting the old Recovery image as freed when removed.",
        level: .error)
      return false
    }
    let suffix = "/" + group + "/" + RestoreImageStubFiles.recoveryImagePath
    return (info["images"] as? [[String: Any]] ?? []).contains {
      ($0["image-path"] as? String)?.hasSuffix(suffix) == true
    }
  }

  /// Every check of UPGRADE-FLOW.md section 4.2 step 1, before any change:
  /// the request against this volume, chip, board and EFI partition, the
  /// system firmware floor, the Stage 1, Apple's image against the pin and
  /// the space. Mounts are read-only unless `writable`.
  static func prepareStubUpgrade(writable: Bool) throws -> StubUpgradePreparation {
    try check(inRecovery && geteuid() == 0, "Open Aurora Installer in its paired Recovery.")
    guard let config = try boundedRead(upgradeConfig, limit: 65536) else {
      throw StubUpgradeCheck.Refusal.notStaged
    }
    let volumes = try stubUpgradeVolume()
    let request = try StubUpgradeRequest.decode(config)
    let preboot = try mountedVolume(volumes.prebootUUID, writable: writable)
    let recovery = try mountedVolume(volumes.recoveryUUID, writable: writable)
    // The partition the request names, on this container's disk.
    var esp: URL?
    if let found = try? self.esp(request.espPartitionUUID.uppercased()),
      let disk = try? disk(found.path)["ParentWholeDisk"] as? String,
      disk == (try? self.disk(volumes.physicalStore)["ParentWholeDisk"] as? String)
    {
      esp = found
    }
    let image = recovery.appendingPathComponent(
      volumes.groupUUID + "/" + RestoreImageStubFiles.recoveryImagePath)
    var imageInfo = stat()
    let imageBytes =
      lstat(image.path, &imageInfo) == 0 && imageInfo.st_mode & S_IFMT == S_IFREG
      ? UInt64(imageInfo.st_blocks) * 512 : 0
    let core = volume.appendingPathComponent("System/Library/CoreServices")
    let fm = FileManager.default
    let facts = StubUpgradeFacts(
      group: volumes.groupUUID, chipID: chipID(),
      deviceClass: deviceTreeStrings("IODeviceTree:/", "compatible").first?.lowercased(),
      espPartitionUUID: esp == nil ? nil : request.espPartitionUUID,
      espRequest: try esp.flatMap {
        try boundedRead($0.appendingPathComponent(StubUpgradeRequest.espRequestPath), limit: 65536)
      },
      stubInfo: try esp.flatMap {
        try boundedRead($0.appendingPathComponent("asahi/stub_info.json"), limit: 1 << 20)
      },
      espFreeBytes: try esp.map(freeBytes) ?? 0,
      systemFirmware: deviceTreeStrings("IODeviceTree:/chosen", "system-firmware-version").first,
      stage1: try boundedRead(
        volume.appendingPathComponent(
          StubUpgradeRequest.stage1Directory + "/" + request.stage1Path),
        limit: Stage1Reenrollment.maximumBytes),
      containerFreeBytes: try freeBytes(recovery), recoveryImageBytes: imageBytes,
      recoveryImageReleasable: imageBytes == 0 || !recoveryImageHeld(group: volumes.groupUUID),
      systemVersionVisible: fm.fileExists(
        atPath: core.appendingPathComponent("SystemVersion.plist").path),
      systemVersionHidden: fm.fileExists(
        atPath: core.appendingPathComponent("SystemVersion-disabled.plist").path),
      launchedByMarker: launcherArmed)
    _ = try StubUpgradeCheck.verify(config: config, facts: facts)
    guard let espRoot = esp else { throw StubUpgradeCheck.Refusal.otherPartition }
    let stage1 = try stubUpgradeStage1(request, stage1: facts.stage1!, esp: espRoot)
    let journal = try RestoreImageStubUpgrade.Journal.load(upgradeJournal)
      .flatMap { $0.planSHA256 == request.planSHA256 ? $0 : nil }
    // Apple's image, read where it is: size and manifest against the pin.
    InstallerLog.shared.append(
      "Reading Apple's restore image: \(request.target.url.absoluteString)")
    let remote: (size: Int, read: RestoreImageDirectory.Read)
    let directory: RestoreImageDirectory
    do {
      remote = try RestoreImageRemote.image(request.target.url)
      directory = try RestoreImageDirectory.read(archiveSize: remote.size, read: remote.read)
    } catch RestoreImageRemote.Failure.unreachable(let reason) {
      throw RecoveryFailure(
        message:
          "Couldn't reach Apple's server (\(reason)). Join Wi-Fi from the menu bar, then try again. Nothing was changed."
      )
    }
    guard let board = boardID() else {
      throw RecoveryFailure(message: "Could not read this Mac's board, so nothing was changed.")
    }
    let plan = try StubUpgradeCheck.plan(
      request, directory: directory, read: remote.read, boardID: board)
    try StubUpgradeCheck.verify(plan: plan, facts: facts, phase: journal?.phase)
    return StubUpgradePreparation(
      request: request, volumes: volumes, facts: facts, esp: espRoot, preboot: preboot,
      recovery: recovery, plan: plan, directory: directory, read: remote.read, journal: journal,
      stage1: stage1)
  }

  /// The staged Stage 1 filled for this EFI partition with the code setup
  /// uses, checked as Update startup software checks it, holding the keys the
  /// installation recorded (Aurora's when there is no record).
  static func stubUpgradeStage1(_ request: StubUpgradeRequest, stage1 unfilled: Data, esp: URL)
    throws -> StubUpgradeStage1
  {
    guard let chip = chipID() else {
      throw RecoveryFailure(message: "Could not read this Mac's chip, so nothing was changed.")
    }
    let mode = AuraBootMode.required(chipID: chip)
    let path = AuraStage1Format.stage2Path(executeWindow: mode == .macho)
    let filled = try Stage1Configuration.filled(
      unfilled, espUUID: request.espPartitionUUID, stage2Path: path)
    let target = esp.appendingPathComponent(path)
    let stage2Bytes = (try? FileManager.default.attributesOfItem(atPath: target.path))
      .flatMap { $0[.type] as? FileAttributeType == .typeRegular ? $0[.size] as? Int : nil }
    guard
      let update = try Stage1Reenrollment.verify(
        stage1: filled, mode: mode, chipID: chip, espUUID: request.espPartitionUUID,
        stage2Path: path, receipt: [:], stage2Bytes: stage2Bytes)
    else { throw RecoveryFailure(message: "The staged Stage 1 could not be checked.") }
    let record = try? installed()
    let lab = (try? configuration.get())?.secureBootLabKey == true
    let keys: StartupKeys?
    do {
      keys = try StartupKeys.recorded(
        receipt: record ?? [:], aurora: AuroraStage2Keys.trusted(lab: lab))
    } catch {
      throw RecoveryFailure(
        message:
          "This installation's startup security keys are recorded wrongly. Nothing was changed.")
    }
    let holdsKeys = Stage1KeyBlock.isPresent(in: filled)
    try check(
      holdsKeys || keys.map({ $0.owner == .aurora }) ?? true,
      "The new startup software can't hold this Mac's own key. Nothing was changed.")
    let enrolled = try (holdsKeys ? keys?.filled(filled) : nil) ?? filled
    return StubUpgradeStage1(mode: mode, stage2Path: path, enrolled: enrolled, update: update)
  }

  /// The owner who approves the upgrade: setup's when the installer recorded
  /// one (install-config.json), else the stub's copied administrator who
  /// owns it or one of this Mac's macOS volume groups.
  static func stubUpgradeOwner() throws -> RecoveryOwner {
    if (try? configuration.get()) != nil { return try resolveOwner() }
    let volumes = try stubUpgradeVolume()
    let preboot = try mountedVolume(volumes.prebootUUID, writable: false)
    let metadata = preboot.appendingPathComponent(
      volumes.groupUUID + "/var/db/AdminUserRecoveryInfo.plist")
    guard let bytes = try boundedRead(metadata, limit: 1 << 20),
      let admins = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any]
    else { throw RecoveryOwnerError.noOwner }
    func users(_ data: String) throws -> [String: Any] {
      let bytes = try run("/usr/sbin/diskutil", ["apfs", "listUsers", data, "-plist"])
      guard
        let users = try PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any]
      else { throw RecoveryOwnerError.noOwner }
      return users
    }
    let target = (try? users(volumes.dataUUID)) ?? [:]
    var sources = [[String: Any]]()
    let listing = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
    let tree =
      try PropertyListSerialization.propertyList(from: listing, format: nil)
      as? [String: Any]
    for container in tree?["Containers"] as? [[String: Any]] ?? [] {
      for item in container["Volumes"] as? [[String: Any]] ?? [] {
        guard (item["Roles"] as? [String] ?? []).contains("System"),
          let id = (item["APFSVolumeUUID"] as? String)?.uppercased(), id != volumes.systemUUID,
          let group = (try? disk(id))?["APFSVolumeGroupID"] as? String,
          let data = try? RecoveryAccountInstaller.pairedDataUUID(
            systemUUID: id, groupUUID: group.uppercased()),
          let found = try? users(data)
        else { continue }
        sources.append(found)
      }
    }
    let owner = try RecoveryOwnerResolver.resolve(
      admins: admins, targetUsers: target, sources: sources)
    InstallerLog.shared.append("Authorizing owner: \(owner.username) (\(owner.uuid.uuidString))")
    return owner
  }

  /// The environment check and owner for the upgrade screen.
  static func checkStubUpgradeEnvironment() throws -> RecoveryOwner {
    guard let request = pendingStubUpgrade() else { throw StubUpgradeCheck.Refusal.notStaged }
    try requireEnrollmentEnvironment(group: request.group) { _ = try stubUpgradeVolume() }
    return try stubUpgradeOwner()
  }

  /// `aura upgrade --dry-run`: every check and the plan; nothing is written.
  static func stubUpgradeDryRun() throws -> String {
    let p = try prepareStubUpgrade(writable: false)
    let owner = try stubUpgradeOwner()
    let r = p.request
    let need = StubUpgradeCheck.neededBytes(plan: p.plan, facts: p.facts, phase: p.journal?.phase)
    let preboot = p.plan.copies.filter { $0.role == "Preboot" }
    let mb = { (bytes: UInt64) in "\(bytes / 1_000_000) MB" }
    var lines = [
      "Startup firmware upgrade, dry run: nothing was written.",
      "  Volume group      \(r.group)",
      "  Startup firmware  macOS \(r.currentVersion) (\(r.currentBuild)) -> macOS \(r.target.version) (\(r.target.build))",
      "  Mac               \(r.deviceClass), chip 0x\(String(r.chipID, radix: 16)), system firmware \(p.facts.systemFirmware ?? "?") (needs \(r.target.minimumBoot))",
      "  Restore image     \(r.target.url.absoluteString): \(r.target.sourceBytes) bytes, manifest and build \(r.target.build) as pinned",
      "  EFI partition     \(r.espPartitionUUID) at \(p.esp.path): request.json is this plan (\(r.planSHA256.prefix(12)))",
      "  Space             needs \(mb(need)) of \(mb(p.facts.containerFreeBytes)) free (old Recovery image \(mb(p.facts.recoveryImageBytes)), \(p.facts.recoveryImageReleasable ? "freed when removed" : "held open: not counted as freed"))",
      "  Stage 1           \(r.stage1Version) \(p.stage1.update.stage1SHA256.prefix(12)), \(p.stage1.mode == .macho ? "padded" : "unpadded"), loads \(p.stage1.stage2Path) from this EFI partition",
      "  Owner             \(owner.username) (\(owner.uuid.uuidString))",
      "  Progress          \(p.journal.map { "recorded up to \($0.phase.rawValue)" } ?? "not started")",
      "Steps:",
      "  1. Preboot: write \(r.group)/\(p.plan.restorePath)\(RestoreImageStubUpgrade.newSuffix) (\(preboot.count + 1) files), then \(p.plan.restorePath) -> \(p.plan.restorePath)\(RestoreImageStubUpgrade.oldSuffix), \(p.plan.restorePath)\(RestoreImageStubUpgrade.newSuffix) -> \(p.plan.restorePath); \(r.group)/boot is not touched",
      "  2. Recovery: remove the old \(RestoreImageStubFiles.recoveryImagePath), then write \(p.plan.recoveryMember.name) (\(mb(UInt64(p.plan.recoveryMember.size)))) decoded and compressed",
      "  3. System: bootcaches.plist, PlatformSupport.plist, \(p.facts.systemVersionHidden ? "SystemVersion-disabled.plist" : "SystemVersion.plist") (\(r.target.version)), the Restore link",
      "  4. bless --setBoot with \(owner.username)'s password",
      "  5. bputil -nc -v \(r.group); kmutil \(p.stage1.mode.enrollmentArguments(stage1: "<Stage 1>", volume: volume.path).joined(separator: " "))",
      "  6. remove \(p.plan.restorePath)\(RestoreImageStubUpgrade.oldSuffix), write the receipts and asahi/stub_info.json, disarm the launcher, restart",
    ]
    if !r.target.caution.isEmpty { lines.append("Known for this Mac: " + r.target.caution) }
    return lines.joined(separator: "\n")
  }

  /// The upgrade: files in place, bless, enrolment, receipts, disarm.
  static func upgradeStub(
    owner: RecoveryOwner, password: String, progress: @escaping (Double, String) -> Void
  ) throws {
    guard let staged = pendingStubUpgrade() else { throw StubUpgradeCheck.Refusal.notStaged }
    try requireEnrollmentEnvironment(group: staged.group) { _ = try stubUpgradeVolume() }
    try RecoveryOwnerResolver.verify(owner, current: stubUpgradeOwner())
    progress(0.02, "Checking the startup firmware upgrade")
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let fm = FileManager.default
    try fm.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // A finished earlier upgrade's journal is kept under its plan's name.
    if let earlier = try RestoreImageStubUpgrade.Journal.load(upgradeJournal),
      earlier.planSHA256 != staged.planSHA256
    {
      try check(
        earlier.phase == .finished,
        "Another startup firmware upgrade didn't finish on this volume. Nothing was changed.")
      try fm.moveItem(
        at: upgradeJournal,
        to: state.appendingPathComponent("upgrade-journal-\(earlier.planSHA256.prefix(16)).json"))
    }
    let p = try prepareStubUpgrade(writable: true)
    let request = p.request
    let operation = state.appendingPathComponent("upgrade-" + UUID().uuidString)
    try fm.createDirectory(
      at: operation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    InstallerLog.shared.persist(to: operation.appendingPathComponent("installer.log"))
    let keys = RestoreImageRemote.ArchiveKeys()
    let steps: [RestoreImageStubUpgrade.Phase: (Double, String)] = [
      .started: (0.05, "Writing the new startup firmware"),
      .prebootWritten: (0.2, "Replacing the restore bundle"),
      .prebootSwapped: (0.22, "Removing the old Recovery image"),
      .recoveryRemoved: (0.25, "Writing the new Recovery image. This can take several minutes."),
      .recoveryWritten: (0.5, "Updating the startup volume"),
      .systemWritten: (0.55, "Approving the new startup firmware"),
    ]
    var journal = try RestoreImageStubUpgrade.run(
      plan: p.plan, directory: p.directory, read: p.read,
      roots: ["System": volume, "Preboot": p.preboot, "Recovery": p.recovery],
      group: request.group, planSHA256: request.planSHA256, build: request.target.build,
      journal: upgradeJournal,
      archiveKey: { entry, metadata in
        let key = try keys.key(entry, metadata: metadata)
        InstallerLog.shared.append("Archive key for \(entry.name) opened.")
        return key
      },
      checkpoint: { phase in
        if let (amount, text) = steps[phase] { progress(amount, text) }
      })
    if journal.phase < .blessed {
      // Apple personalizes the new boot files for this Mac (network).
      try authorized(
        "/usr/sbin/bless", ["--mount", volume.path, "--setBoot", "--user", owner.username],
        owner: owner, password: password)
      try RestoreImageStubUpgrade.record(.blessed, &journal, at: upgradeJournal)
    }
    let stage1 = p.stage1
    if journal.phase < .enrolled {
      let stage1Path = operation.appendingPathComponent("stage1")
      try Stage1ReenrollmentRunner.run(
        stage: {
          progress(0.6, "Checking the new Stage 1")
          try stageStage1(stage1.enrolled, mode: stage1.mode, at: stage1Path)
        },
        authorizePolicy: {
          progress(0.65, "Authorizing the boot environment")
          try authorized(
            "/usr/bin/bputil",
            RecoveryBootPolicy.authorizationArguments(
              groupUUID: request.group,
              allowCustomBootArguments: (try? configuration.get())?.allowCustomBootArguments
                == true),
            owner: owner, password: password)
        },
        enroll: {
          progress(0.7, stage1.mode == .macho ? slowEnrollment : "Installing the startup software")
          try authorized(
            "/usr/bin/kmutil",
            stage1.mode.enrollmentArguments(stage1: stage1Path.path, volume: volume.path),
            owner: owner, password: password)
        },
        record: {
          journal.stage1SHA256 = hash(stage1.enrolled)
          try RestoreImageStubUpgrade.record(.enrolled, &journal, at: upgradeJournal)
        },
        finish: {})
      try? fm.removeItem(at: stage1Path)
    }
    progress(0.9, "Finishing the upgrade")
    try finishStubUpgrade(p, journal: &journal)
    InstallerLog.shared.append(
      "Startup firmware upgraded to macOS \(request.target.version) (\(request.target.build)); Stage 1 \(stage1.update.stage1SHA256.prefix(12)) loads \(stage1.stage2Path)."
    )
    progress(1, "Upgrade complete")
  }

  /// After enrolment: the old bundle goes, the receipts and stub_info.json
  /// name the new firmware, the launcher is disarmed. Each step can run again.
  static func finishStubUpgrade(
    _ p: StubUpgradePreparation, journal: inout RestoreImageStubUpgrade.Journal
  ) throws {
    let request = p.request
    let fm = FileManager.default
    try RecoveryDirectorySwap.discard(
      backup: p.preboot.appendingPathComponent(
        request.group + "/" + p.plan.restorePath + RestoreImageStubUpgrade.oldSuffix))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let receipt: [String: Any] = [
      "schema": 1, "status": "upgraded", "planSHA256": request.planSHA256,
      "group": request.group,
      "from": ["version": request.currentVersion, "build": request.currentBuild],
      "to": ["version": request.target.version, "build": request.target.build],
      "mode": p.stage1.mode.rawValue, "stage1SHA256": journal.stage1SHA256 ?? "",
      "stage1Version": request.stage1Version, "stage2Path": p.stage1.stage2Path,
      "files": try JSONSerialization.jsonObject(with: encoder.encode(journal.installed)),
    ]
    try RecoveryFileTransaction.write(
      JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
      to: upgradeReceipt)
    // An installation the Aurora installer made records its Stage 1 as Update startup software does.
    if let record = try? installed() {
      try RecoveryFileTransaction.write(
        JSONSerialization.data(
          withJSONObject: p.stage1.update.receipt(
            after: record, stage2SHA256: record["stage2SHA256"] as? String ?? ""),
          options: [.prettyPrinted, .sortedKeys]), to: self.receipt)
    }
    // asahi/stub_info.json, as the installer writes it, for the new firmware.
    let infoURL = p.esp.appendingPathComponent("asahi/stub_info.json")
    guard let old = try boundedRead(infoURL, limit: 1 << 20),
      var info = try JSONSerialization.jsonObject(with: old) as? [String: Any],
      let new = try JSONSerialization.jsonObject(with: p.plan.stubInfo) as? [String: Any]
    else { throw StubUpgradeCheck.Refusal.noStubInfo }
    info["system_version"] = new["system_version"]
    info["manifest_info"] = new["manifest_info"]
    info["vgid"] = request.group
    try atomic(
      JSONSerialization.data(
        withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes]),
      to: infoURL)
    // The request's journal on the EFI partition, for aurora-upgrade finish.
    let espJournal = p.esp.appendingPathComponent(StubUpgradeRequest.espJournalPath)
    if let bytes = try boundedRead(espJournal, limit: 1 << 20),
      var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    {
      var steps = value["steps"] as? [[String: Any]] ?? []
      if steps.last?["kind"] as? String != "recovery-upgraded" {
        steps.append([
          "kind": "recovery-upgraded", "time": Int(Date().timeIntervalSince1970),
          "build": request.target.build, "group": request.group,
        ])
      }
      value["steps"] = steps
      value["state"] = "upgraded"
      try atomic(
        JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]), to: espJournal)
    }
    // The volume starts its new Stage 1 again instead of this app.
    try RecoveryVersionMetadata.showForStartupDisk(system: volume)
    try RecoveryFileTransaction.flushDirectory(
      volume.appendingPathComponent("System/Library/CoreServices"))
    let marker = volume.appendingPathComponent(".IAPhysicalMedia")
    if fm.fileExists(atPath: marker.path) {
      try RecoveryFileTransaction.write(
        Data(contentsOf: marker),
        to: volume.appendingPathComponent("IAPhysicalMedia-disabled.plist"))
      try fm.removeItem(at: marker)
      try RecoveryFileTransaction.flushDirectory(volume)
    }
    try RestoreImageStubUpgrade.record(.finished, &journal, at: upgradeJournal)
  }

  /// Restarts into Linux once the upgrade is recorded and this volume is the startup disk.
  static func restartAfterStubUpgrade(group: String) throws {
    try check(inRecovery && geteuid() == 0, "Open Aurora Installer in its paired Recovery.")
    guard let journal = try RestoreImageStubUpgrade.Journal.load(upgradeJournal),
      journal.phase == .finished, journal.group == group
    else {
      throw RecoveryFailure(
        message:
          "The startup firmware upgrade didn't finish. Open Aurora Installer again to finish it.")
    }
    try check(
      try isDefaultBoot(group: group),
      "This volume is not the startup disk. Choose it in Apple menu → Startup Disk, then restart.")
    InstallerLog.shared.append("Startup firmware upgraded. Restarting now.")
    _ = try run("/sbin/shutdown", ["-r", "now"])
  }
}
