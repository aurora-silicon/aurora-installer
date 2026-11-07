import Darwin
import Foundation
import IOKit
import RecoveryAuthorization

struct RecoveryFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Set once by the timer that stops a command, read after the command exits.
final class CommandTimeout: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var fired: Bool { lock.withLock { value } }
  func fire() { lock.withLock { value = true } }
}

enum RecoveryActions {
  // The engine writes this only after the new System volume and ESP exist.
  // Keep loading independent of diskutil so Recovery can show the window first.
  static let configuration: Result<InstallConfiguration, Error> = Result {
    return try InstallConfiguration.decode(
      RecoveryAccountInstaller.protectedRead(
        RecoveryInstallData.directory(system: volume).appendingPathComponent("install-config.json"),
        limit: 65536))
  }
  static var volume: URL {
    #if AURORA_STEP2_PREVIEW
      return URL(fileURLWithPath: "/Volumes/Aurora")
    #else
      // The launch contract puts the app directly in the target System volume.
      // Resolve its actual mount point, not a name that Recovery might suffix.
      return Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    #endif
  }
  static var systemUUID: String { (try? configuration.get().systemUUID) ?? "" }
  static var groupUUID: String { (try? configuration.get().groupUUID) ?? "" }
  static var prebootUUID: String { (try? configuration.get().prebootUUID) ?? "" }
  static var espUUID: String { (try? configuration.get().espUUID) ?? "" }
  static var volumeName: String { (try? configuration.get().volumeName) ?? "Aurora" }
  static var allowsCustomBootArguments: Bool {
    (try? configuration.get().allowCustomBootArguments) == true
  }
  /// The boot mode the installer recorded for this Mac (AuraStage1Format).
  static var configuredBootMode: AuraBootMode {
    (try? configuration.get()).flatMap { AuraBootMode(rawValue: $0.bootMode) } ?? .raw
  }
  /// This Mac's chip, as the boot firmware reports it.
  static func chipID() -> UInt64? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    guard
      let bytes = IORegistryEntryCreateCFProperty(
        entry, "chip-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
      [4, 8].contains(bytes.count)
    else { return nil }
    return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
  }
  /// Checks a Mach-O Stage 1 before anything changes: its layout and this Mac's
  /// chip. What kmutil derives is checked on the padded file it enrolls.
  static func verifyMachOStage1(_ stage1: Data) throws {
    try MachOBootObject.check(stage1)
    guard let chip = chipID(), AuraStage1Format.usesMachO(chipID: chip) else {
      throw RecoveryFailure(message: "This Mac starts from the raw startup software, not Mach-O.")
    }
  }
  /// Bytes this volume's APFS container can still give to a file, or to kmutil in Preboot.
  static func freeBytes(_ path: URL) throws -> UInt64 {
    var status = statfs()
    guard statfs(path.path, &status) == 0 else {
      throw RecoveryFailure(message: "Could not read this volume's free space.")
    }
    return UInt64(status.f_bavail) * UInt64(status.f_bsize)
  }
  /// Pads the Stage 1 and checks what kmutil derives from the file it will enroll.
  static func stageExpandedStage1(_ stage1: Data, window: UInt64, at path: URL) throws {
    let usage = try run("/usr/bin/kmutil", ["configure-boot", "--help"], timeout: 60)
    try check(
      String(decoding: usage, as: UTF8.self).contains("--compress"),
      "This Recovery's kmutil cannot compress startup software, which this Mac needs.")
    let expanded = try MachOBootObject.expandExecuteWindow(stage1, window: window)
    try expanded.requireSpace(freeBytes: freeBytes(path.deletingLastPathComponent()))
    try expanded.write(to: path)
    let output: Data
    do {
      output = try run(
        "/usr/bin/kmutil", ["inspect", "-z", "-B", path.path, "--show-mach-boot-properties"],
        timeout: 300)
    } catch {
      throw RecoveryFailure(
        message:
          "This Recovery's kmutil could not check the startup software, so it was not enrolled. Open Window → Installer Log for its output."
      )
    }
    let used = try MachOBootObject.checkInspection(
      String(decoding: output, as: UTF8.self), readOnlySize: expanded.readOnlySize)
    InstallerLog.shared.append("Startup software padded and checked by kmutil: \(used).")
  }
  static var inRecovery: Bool {
    #if AURORA_STEP2_RECOVERY
      return FileManager.default.fileExists(atPath: "/System/Installation/CDIS")
    #else
      return false
    #endif
  }
  static var isPreview: Bool {
    #if AURORA_STEP2_PREVIEW
      return CommandLine.arguments.contains("--preview")
        || CommandLine.arguments.contains("--recovery-preview")
    #else
      return false
    #endif
  }
  static func requireEnrollmentEnvironment() throws {
    // Check cheap prerequisites before querying a target policy.
    if !inRecovery { throw EnrollmentGateIssue.notRecovery }
    if geteuid() != 0 { throw EnrollmentGateIssue.rootRequired }
    try verifyVolume()
    let report: Data
    do { report = try run("/usr/bin/bputil", ["-d", "-v", groupUUID]) } catch {
      throw EnrollmentGateIssue.cannotVerify
    }
    if let issue = EnrollmentGate.issue(
      isRecovery: true, isRoot: true,
      policy: String(decoding: report, as: UTF8.self))
    {
      InstallerLog.shared.append(
        "Recovery environment rejected: \(issue.title). \(issue.message)", level: .error)
      throw issue
    }
  }
  static func payloadRoot() throws -> URL {
    try RecoveryInstallData.payloadDirectory(system: volume)
  }
  static var state: URL { volume.appendingPathComponent("Aurora/Recovery/State") }
  static var receipt: URL { state.appendingPathComponent("installation.json") }
  static var pendingInstallation: URL { state.appendingPathComponent("installation.pending.json") }
  static var recovering: Bool {
    FileManager.default.fileExists(atPath: receipt.path)
      && !FileManager.default.fileExists(atPath: pendingInstallation.path)
  }

  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw RecoveryFailure(message: message) }
  }
  static func hash(_ bytes: Data) -> String {
    RecoveryDigest.sha256(bytes)
  }
  /// `timeout` stops a command that hangs; a stopped command counts as failed.
  @discardableResult static func run(
    _ path: String, _ args: [String], timeout: TimeInterval? = nil
  ) throws -> Data {
    let logged = path != "/usr/sbin/nvram"
    let log = logged ? CommandLog(path, args) : nil
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch {
      log?.finish(status: -1, reason: "Could not launch: " + error.localizedDescription)
      throw error
    }
    let stopped = CommandTimeout()
    let timer = timeout.map { seconds in
      let item = DispatchWorkItem {
        if process.isRunning {
          stopped.fire()
          process.terminate()
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
      return item
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer?.cancel()
    let name = URL(fileURLWithPath: path).lastPathComponent
    log?.output(String(decoding: data, as: UTF8.self))
    if stopped.fired, let timeout {
      log?.finish(status: process.terminationStatus, reason: "Stopped after \(Int(timeout)) s")
      throw RecoveryFailure(message: "\(name) did not finish within \(Int(timeout)) seconds.")
    }
    log?.finish(status: process.terminationStatus)
    try check(
      process.terminationStatus == 0, "\(name) failed (\(process.terminationStatus)).")
    return data
  }
  static func disk(_ path: String) throws -> [String: Any] {
    let data = try run("/usr/sbin/diskutil", ["info", "-plist", path])
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw RecoveryFailure(message: "Cannot identify the selected volume.")
    }
    return info
  }
  static func verifyVolume() throws {
    _ = try configuration.get()
    let info = try disk(volume.path)
    try check(
      (info["VolumeUUID"] as? String)?.uppercased() == systemUUID
        && (info["APFSVolumeGroupID"] as? String)?.uppercased() == groupUUID
        && (info["MountPoint"] as? String) == volume.path,
      "The selected volume does not match this installation.")
  }
  static func resolveOwner() throws -> RecoveryOwner {
    try verifyVolume()
    let selected = try RecoveryAccountInstaller.selectedOwner(system: volume)
    let dataUUID = try RecoveryAccountInstaller.pairedDataUUID(
      systemUUID: systemUUID, groupUUID: groupUUID)
    let userData = try run("/usr/sbin/diskutil", ["apfs", "listUsers", dataUUID, "-plist"])
    guard
      let cryptoUsers = try PropertyListSerialization.propertyList(from: userData, format: nil)
        as? [String: Any]
    else {
      throw RecoveryOwnerError.noOwner
    }
    var pendingAccount: RecoveryOwner?
    if let selected {
      guard let uuid = UUID(uuidString: selected.generatedUID) else {
        throw RecoveryOwnerError.noOwner
      }
      let account = RecoveryOwner(username: selected.username, uuid: uuid)
      if RecoveryOwnerResolver.isOwner(account, users: cryptoUsers) { return account }
      guard ["prepared", "awaiting-ownership"].contains(selected.phase) else {
        throw RecoveryOwnerError.noOwner
      }
      pendingAccount = account
    }
    var preboot = try disk(prebootUUID)
    if (preboot["MountPoint"] as? String)?.isEmpty != false {
      try run("/usr/sbin/diskutil", ["mount", "readOnly", prebootUUID])
      preboot = try disk(prebootUUID)
    }
    guard (preboot["VolumeUUID"] as? String)?.uppercased() == prebootUUID,
      let mount = preboot["MountPoint"] as? String, mount.hasPrefix("/")
    else {
      throw RecoveryOwnerError.noOwner
    }
    let metadata = URL(fileURLWithPath: mount).appendingPathComponent(
      groupUUID + "/var/db/AdminUserRecoveryInfo.plist")
    // Read only identity fields; never log the recovery metadata contents.
    guard
      let admins = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: metadata), format: nil) as? [String: Any]
    else {
      throw RecoveryOwnerError.noOwner
    }
    let bootstrap = try configuration.get().bootstrap
    let owner = try RecoveryOwnerResolver.resolve(
      admins: admins, targetUsers: cryptoUsers, bootstrap: bootstrap,
      pendingAccount: pendingAccount,
      source: {
        guard let bootstrap else { throw RecoveryOwnerError.noOwner }
        let bytes = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        guard
          let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
            as? [String: Any]
        else { throw RecoveryOwnerError.noOwner }
        var candidates = [[String: Any]]()
        for container in tree["Containers"] as? [[String: Any]] ?? [] {
          for volume in container["Volumes"] as? [[String: Any]] ?? [] {
            let roles = volume["Roles"] as? [String] ?? []
            guard roles.contains("System"), let id = volume["APFSVolumeUUID"] as? String else {
              continue
            }
            var info = try disk(id)
            guard (info["VolumeUUID"] as? String)?.uppercased() == id.uppercased() else {
              throw RecoveryOwnerError.noOwner
            }
            info["Roles"] = roles
            candidates.append(info)
          }
        }
        let info = try RecoveryOwnerResolver.sourceSystem(
          group: bootstrap.sourceGroupUUID, candidates: candidates)
        guard let id = info["VolumeUUID"] as? String else { throw RecoveryOwnerError.noOwner }
        var snapshots = Set<String>()
        if id.uppercased() != bootstrap.sourceSystemUUID {
          if (info["MountPoint"] as? String)?.isEmpty != false {
            try run("/usr/sbin/diskutil", ["mount", "readOnly", id])
          }
          let bytes = try run("/usr/sbin/diskutil", ["apfs", "listSnapshots", id, "-plist"])
          guard
            let listing = try PropertyListSerialization.propertyList(from: bytes, format: nil)
              as? [String: Any]
          else { throw RecoveryOwnerError.noOwner }
          snapshots = RecoveryOwnerResolver.snapshotUUIDs(listing)
          guard snapshots.contains(bootstrap.sourceSystemUUID) else {
            throw RecoveryOwnerError.noOwner
          }
        }
        let sourceDataUUID = try RecoveryAccountInstaller.pairedDataUUID(
          systemUUID: id.uppercased(), groupUUID: bootstrap.sourceGroupUUID)
        let data = try run(
          "/usr/sbin/diskutil", ["apfs", "listUsers", sourceDataUUID, "-plist"])
        guard
          let users = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { throw RecoveryOwnerError.noOwner }
        return (info, users, snapshots)
      })
    InstallerLog.shared.append("Authorizing owner: \(owner.username) (\(owner.uuid.uuidString))")
    return owner
  }
  static func recoveryOnly() throws {
    try check(inRecovery && geteuid() == 0, "Open Aurora Installer in its paired Recovery.")
    try verifyVolume()
  }
  static func esp() throws -> URL {
    var info = try disk(espUUID)
    try check(
      (info["DiskUUID"] as? String)?.uppercased() == espUUID
        && (info["Content"] as? String) == "EFI",
      "The startup partition does not match this installation.")
    if (info["MountPoint"] as? String)?.isEmpty != false {
      try run("/usr/sbin/diskutil", ["mount", espUUID])
      info = try disk(espUUID)
    }
    guard let path = info["MountPoint"] as? String, path.hasPrefix("/"), !path.isEmpty else {
      throw RecoveryFailure(message: "Cannot mount the startup partition.")
    }
    let mounted = try disk(path)
    try check(
      (mounted["DiskUUID"] as? String)?.uppercased() == espUUID,
      "The mounted startup partition does not match this installation.")
    return URL(fileURLWithPath: path)
  }
  static func manifest() throws -> [String: Any] {
    let path = try payloadRoot().appendingPathComponent("manifest.json")
    guard
      let m = try JSONSerialization.jsonObject(
        with: RecoveryAccountInstaller.protectedRead(path, limit: 1 << 20)) as? [String: Any],
      m["schema"] as? Int == 2
    else { throw RecoveryFailure(message: "The recovery payload manifest is invalid.") }
    return m
  }
  static func asset(_ name: String, manifest: [String: Any]) throws -> Data {
    try RecoveryBaseline.asset(
      name, manifest: manifest, root: payloadRoot())
  }
  static func atomic(_ bytes: Data, to target: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: target, options: .atomic)
    let fd = open(target.path, O_RDONLY | O_NOFOLLOW)
    try check(fd >= 0, "Cannot verify the saved file.")
    defer { close(fd) }
    try check(fsync(fd) == 0, "Could not flush the saved file.")
    try check(try Data(contentsOf: target) == bytes, "Saved file verification failed.")
    sync()
  }
  static func saveJSON(_ object: [String: Any], to path: URL) throws {
    try atomic(
      JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      to: path)
  }
  static func authorized(
    _ executable: String, _ arguments: [String], owner: RecoveryOwner, password: String
  ) throws {
    let log = CommandLog(executable, arguments, secrets: [password])
    let context = Unmanaged.passUnretained(log).toOpaque()
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { for p in argv { if let p { free(p) } } }
    let result = argv.withUnsafeBufferPointer { pointers in
      executable.withCString { command in
        owner.username.withCString { user in
          password.withCString { secret in
            aurora_authorized_command_logged(
              command, pointers.baseAddress, user, secret,
              { text, context in
                guard let text, let context else { return }
                Unmanaged<CommandLog>.fromOpaque(context).takeUnretainedValue().output(
                  String(cString: text))
              }, context)
          }
        }
      }
    }
    let name = URL(fileURLWithPath: executable).lastPathComponent
    let reason =
      result < 0 ? String(cString: aurora_authorization_failure(result)) : "exit status \(result)"
    log.finish(status: result, reason: result < 0 ? "Authorization failed: " + reason : nil)
    InstallerLog.shared.append(
      "\(name): \(result == 0 ? "completed" : reason)", level: result == 0 ? .progress : .error)
    try check(
      result == 0,
      "\(name) failed: \(reason). Open Window → Installer Log for the command output.")
  }
  static func install(
    selection: BootSelection, owner: RecoveryOwner, password: String,
    progress: @escaping (Double, String) -> Void
  ) throws {
    // Repeat the check here so bypassing the GUI cannot reach any write.
    try requireEnrollmentEnvironment()
    InstallerLog.shared.append(
      "Recovery environment verified. Checking the installation’s recovery account.")
    if let selected = try RecoveryAccountInstaller.selectedOwner(system: volume) {
      if owner.uuid.uuidString == selected.generatedUID {
        InstallerLog.shared.append(
          "Verifying the recovery account and completing its ownership metadata.")
        let final = try RecoveryAccountInstaller.finalize(
          selected.target, password: Data(password.utf8), installationPending: true)
        try RecoveryAccountInstaller.requireOwnership(final)
        InstallerLog.shared.append("Recovery account ownership verified.")
      } else {
        try check(
          ["prepared", "awaiting-ownership"].contains(selected.phase),
          "The recovery account is not ready for initial enrollment.")
        InstallerLog.shared.append(
          "Initial enrollment uses the recorded macOS owner. Authorize the new recovery account in Startup Disk after setup."
        )
      }
    }
    let config = try configuration.get()
    // The installer chose the mode for this Mac's chip.
    try check(
      selection.mode.rawValue == config.bootMode,
      "This installation uses \(config.bootMode) boot mode only.")
    guard let chip = chipID() else {
      throw RecoveryFailure(message: "Could not read this Mac's chip, so nothing was changed.")
    }
    try check(
      AuraBootMode.required(chipID: chip) == selection.mode,
      "This Mac cannot start from the startup software in this installation's files. Run the Aurora installer again."
    )
    try RecoveryOwnerResolver.verify(owner, current: resolveOwner())
    progress(0.05, "Verifying the installation files")
    let m = try manifest()
    try check(
      m["defaultMode"] as? String == config.bootMode,
      "The recovery payload does not match this installation's boot mode.")
    let stage1 = try asset(selection.mode.stage1Path, manifest: m)
    let stage2 = try asset(selection.mode.stage2Path, manifest: m)
    if selection.mode == .macho {
      try verifyMachOStage1(stage1)
      try check(
        (try? Stage1Configuration.read(stage1).stage2Path) == config.stage2Path,
        "The startup software in these files doesn't load this installation's Stage 2. Run the Aurora installer again."
      )
    }
    // A successful setup must retain a usable per-device repair baseline.
    _ = try RecoveryBaseline.firmware(
      manifest: m, root: payloadRoot())
    let modes = m["modes"] as? [String: [String: Any]]
    guard let entry = modes?[selection.mode.rawValue],
      let destination = entry["espPath"] as? String, destination == config.stage2Path
    else {
      throw RecoveryFailure(
        message: "This boot mode’s complete startup bundle has not been staged yet.")
    }
    progress(0.15, "Checking the recovery environment")
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let fm = FileManager.default
    try fm.createDirectory(
      at: state, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let target = try esp().appendingPathComponent(destination)
    let marker = volume.appendingPathComponent(".IAPhysicalMedia")
    let disabledMarker = volume.appendingPathComponent("IAPhysicalMedia-disabled.plist")
    let core = volume.appendingPathComponent("System/Library/CoreServices")
    let visibleVersion = core.appendingPathComponent("SystemVersion.plist")
    let hiddenVersion = core.appendingPathComponent("SystemVersion-disabled.plist")
    let files = [target, marker, disabledMarker, visibleVersion, hiddenVersion, receipt]
    let isc = URL(fileURLWithPath: "/System/Volumes/iSCPreboot/" + groupUUID)
    let iscVar = isc.appendingPathComponent("var")
    var journal: RecoveryInstallationJournal
    var transaction: RecoveryFileTransaction
    var operation: URL
    if fm.fileExists(atPath: pendingInstallation.path) {
      journal = try JSONDecoder().decode(
        RecoveryInstallationJournal.self,
        from: RecoveryAccountInstaller.protectedRead(pendingInstallation, limit: 65536))
      try journal.validate(
        system: systemUUID, group: groupUUID, esp: espUUID,
        stage1: hash(stage1), stage2: hash(stage2))
      journal.executeWindowSize = selection.mode.executeWindowSize
      operation = state.appendingPathComponent(journal.operation)
      transaction = try RecoveryFileTransaction.resume(
        directory: operation.appendingPathComponent("files"), files: files,
        originalFiles: journal.originalFiles.map { URL(fileURLWithPath: $0) })
      if journal.phase.mayRestoreFiles {
        try transaction.restore()
        try restoreISC(journal, at: iscVar)
        journal.phase = .prepared
      }
      InstallerLog.shared.append("Resuming the recorded startup setup.")
    } else {
      operation = state.appendingPathComponent("operation-" + UUID().uuidString)
      try fm.createDirectory(
        at: operation, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      transaction = try RecoveryFileTransaction(
        directory: operation.appendingPathComponent("files"), files: files, dataOnly: [target])
      journal = RecoveryInstallationJournal(
        operation: operation.lastPathComponent, systemUUID: systemUUID, groupUUID: groupUUID,
        espUUID: espUUID, stage1SHA256: hash(stage1), stage2SHA256: hash(stage2),
        originalFiles: files.map(\.path),
        replacedISC: fm.fileExists(atPath: isc.appendingPathComponent("boot").path),
        iscVarWasPresent: fm.fileExists(atPath: iscVar.path), phase: .prepared,
        executeWindowSize: selection.mode.executeWindowSize)
    }
    let executeWindow = selection.mode.executeWindowSize
    func record(_ phase: RecoveryInstallationPhase) throws {
      journal.phase = phase
      try RecoveryFileTransaction.write(try JSONEncoder().encode(journal), to: pendingInstallation)
    }
    try record(journal.phase)
    InstallerLog.shared.persist(to: operation.appendingPathComponent("installer.log"))
    let stage1Path = operation.appendingPathComponent("stage1")
    if executeWindow == nil { try RecoveryFileTransaction.write(stage1, to: stage1Path) }
    do {
      try RecoveryInstallationCoordinator.run(
        phase: journal.phase, persist: record,
        stage: {
          // Inside this block so that a refusal restores the files and clears the journal.
          if let executeWindow {
            try stageExpandedStage1(stage1, window: executeWindow, at: stage1Path)
          }
        },
        authorizePolicy: {
          try transaction.clearImmutableFlags()
          progress(0.3, "Authorizing the boot environment")
          try authorized(
            "/usr/bin/bputil",
            RecoveryBootPolicy.authorizationArguments(
              groupUUID: groupUUID, allowCustomBootArguments: allowsCustomBootArguments),
            owner: owner, password: password)
        },
        installBundle: {
          if journal.replacedISC {
            try run("/usr/sbin/diskutil", ["mount", prebootUUID])
            let preboot = try disk(prebootUUID)
            guard (preboot["VolumeUUID"] as? String)?.uppercased() == prebootUUID,
              let mount = preboot["MountPoint"] as? String
            else {
              throw RecoveryFailure(message: "Cannot identify the mounted Preboot volume.")
            }
            try replaceISC(
              journal,
              source: URL(fileURLWithPath: mount)
                .appendingPathComponent(groupUUID + "/var"), at: iscVar)
          }
          try atomic(stage2, to: target)
        },
        verifyBundle: {
          try check(
            try Data(contentsOf: target) == stage2,
            "The pending startup bundle changed; its recovery record was preserved.")
        },
        enroll: {
          progress(
            0.55, selection.mode == .macho ? slowEnrollment : "Installing the startup software")
          try authorized(
            "/usr/bin/kmutil",
            selection.mode.enrollmentArguments(stage1: stage1Path.path, volume: volume.path),
            owner: owner, password: password)
        },
        finalize: {
          progress(0.85, "Finishing installation")
          // Keep autolaunch until both version metadata and receipt are durable.
          try RecoveryVersionMetadata.showForStartupDisk(system: volume)
          try RecoveryFileTransaction.flushDirectory(core)
          var installation: [String: Any] = [
            "schema": 1, "mode": selection.mode.rawValue, "stage2Path": destination,
            "stage1SHA256": hash(stage1), "stage2SHA256": hash(stage2),
            "status": "installed", "recoveryAccountRequired": true, "operation": operation.path,
          ]
          // A raw installation's receipt keeps its shape.
          if selection.mode == .raw { installation["nestedVirtualization"] = false }
          if let executeWindow { installation["executeWindowSize"] = executeWindow }
          try RecoveryFileTransaction.write(
            try JSONSerialization.data(
              withJSONObject: installation, options: [.prettyPrinted, .sortedKeys]), to: receipt)
          if fm.fileExists(atPath: marker.path) {
            try RecoveryFileTransaction.write(Data(contentsOf: marker), to: disabledMarker)
            try fm.removeItem(at: marker)
            try RecoveryFileTransaction.flushDirectory(volume)
          }
        },
        commit: {
          try transaction.commit(relocated: [
            marker.standardizedFileURL.path: disabledMarker,
            hiddenVersion.standardizedFileURL.path: visibleVersion,
          ])
        })
      if journal.replacedISC {
        try RecoveryDirectorySwap.commit(target: iscVar, operation: journal.operation)
      }
      try fm.removeItem(at: pendingInstallation)
      try RecoveryFileTransaction.flushDirectory(state)
    } catch {
      let original = error
      if journal.phase.mayRestoreFiles {
        do {
          try transaction.restore()
          try restoreISC(journal, at: iscVar)
          try fm.removeItem(at: pendingInstallation)
          try RecoveryFileTransaction.flushDirectory(state)
        } catch {
          throw RecoveryFailure(
            message:
              "Setup stopped and file recovery needs review. Keep the saved operation at \(operation.path)."
          )
        }
        InstallerLog.shared.append(
          "Startup files restored. An authorized LocalPolicy change is not undone by file recovery."
        )
      } else {
        InstallerLog.shared.append(
          "The matching startup bundle and pending operation were retained. Continue again to finish this setup."
        )
      }
      throw original
    }
    progress(1, "Installation complete")
  }
  static let slowEnrollment =
    "Installing the startup software. This can take several minutes."

  private static func replaceISC(
    _ journal: RecoveryInstallationJournal, source: URL, at target: URL
  ) throws {
    try RecoveryDirectorySwap.replace(
      source: source, target: target, operation: journal.operation,
      wasPresent: journal.iscVarWasPresent,
      copy: {
        _ = try run("/usr/bin/ditto", [$0.path, $1.path])
      })
  }

  private static func restoreISC(_ journal: RecoveryInstallationJournal, at target: URL) throws {
    guard journal.replacedISC else { return }
    try RecoveryDirectorySwap.restore(
      target: target, operation: journal.operation,
      wasPresent: journal.iscVarWasPresent)
  }

  static func targetIsDefaultBoot() throws -> Bool {
    let bytes = try run("/usr/sbin/bless", ["--getBoot", "--plist"])
    guard
      let info = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any],
      let boot = info["Boot Volume"] as? String
    else {
      throw RecoveryFailure(
        message: "Couldn’t read the default startup volume. The Mac has not been shut down.")
    }
    return (try disk(boot)["APFSVolumeGroupID"] as? String)?.uppercased() == groupUUID
  }

  // Returns false when owner authorization is needed. This repair deliberately
  // does not require paired 1TR: its purpose is to get the user into that mode.
  static func repairRecoveryBoot(password: String? = nil, owner: RecoveryOwner? = nil) throws
    -> Bool
  {
    try recoveryOnly()
    if try !targetIsDefaultBoot(), password == nil { return false }
    do {
      try RecoveryBootRepair.perform(
        isTargetDefault: targetIsDefaultBoot,
        selectTarget: {
          guard let password, let owner else {
            throw RecoveryFailure(
              message:
                "The startup selection changed. Try again to authorize Aurora as the startup disk."
            )
          }
          try RecoveryOwnerResolver.verify(owner, current: resolveOwner())
          try authorized(
            "/usr/sbin/bless", ["--mount", volume.path, "--setBoot", "--user", owner.username],
            owner: owner, password: password)
        },
        shutDown: {
          try run("/sbin/shutdown", ["-h", "now"])
        })
    } catch RecoveryBootRepair.Failure.selectionNotVerified {
      throw RecoveryFailure(
        message: "Aurora was not confirmed as the startup disk. The Mac has not been shut down.")
    }
    return true
  }

  static func prepareStartupDiskHandoff() throws -> URL {
    try recoveryOnly()
    _ = try installed()
    try RecoveryVersionMetadata.showForStartupDisk(system: volume)
    let application = URL(fileURLWithPath: "/System/Applications/Utilities/Startup Disk.app")
    try check(
      FileManager.default.fileExists(atPath: application.path),
      "Startup Disk is unavailable. Choose Apple menu → Startup Disk.")
    return application
  }

  static func accountTarget() throws -> RecoveryAccountTarget {
    try recoveryOnly()
    _ = try installed()
    let system = try disk(systemUUID)
    guard let containerID = system["APFSContainerReference"] as? String else {
      throw RecoveryFailure(message: "Cannot identify this installation’s APFS container.")
    }
    let bytes = try run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
    guard
      let tree = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any], let containers = tree["Containers"] as? [[String: Any]]
    else { throw RecoveryFailure(message: "Cannot inspect the installation volumes.") }
    let matches = containers.filter { $0["ContainerReference"] as? String == containerID }
    guard matches.count == 1 else {
      throw RecoveryFailure(message: "The installation’s APFS container is ambiguous.")
    }
    let volumes = matches[0]["Volumes"] as? [[String: Any]] ?? []
    for (id, role) in [(systemUUID, "System"), (prebootUUID, "Preboot")] {
      try check(
        volumes.filter {
          ($0["APFSVolumeUUID"] as? String)?.uppercased() == id
            && ($0["Roles"] as? [String] ?? []).contains(role)
        }.count == 1,
        "The installation’s \(role) volume does not match its configuration.")
    }
    var candidates = [String]()
    for volume in volumes {
      guard (volume["Roles"] as? [String] ?? []).contains("Data"),
        let id = volume["APFSVolumeUUID"] as? String
      else { continue }
      let info = try disk(id)
      if (info["APFSVolumeGroupID"] as? String)?.uppercased() == groupUUID,
        info["APFSContainerReference"] as? String == containerID
      {
        candidates.append(id.uppercased())
      }
    }
    guard candidates.count == 1 else {
      throw RecoveryFailure(message: "Cannot identify this installation’s Data volume.")
    }
    let target = RecoveryAccountTarget(
      volumeName: volumeName, systemUUID: systemUUID, dataUUID: candidates[0],
      groupUUID: groupUUID, prebootUUID: prebootUUID)
    try target.validate()
    return target
  }

  static func recoveryAccount() throws -> RecoveryAccountRecord? {
    let record = try RecoveryAccountInstaller.inspect(accountTarget())
    if let record, record.phase == "finalized" {
      try RecoveryAccountInstaller.requireOwnership(record)
    }
    return record
  }

  static func accountCreationRequired() throws -> Bool {
    try installed()["recoveryAccountRequired"] as? Bool == true
  }

  static func restartCompletedSetup() throws {
    try recoveryOnly()
    let record = try installed()
    try RecoveryDirectRestart.perform(
      receipt: record,
      hasPendingInstallation: FileManager.default.fileExists(atPath: pendingInstallation.path),
      verifyBundle: {
        let config = try configuration.get()
        let expected = try asset("raw/boot.bin", manifest: manifest())
        let target = try esp().appendingPathComponent(config.stage2Path)
        try check(
          try Data(contentsOf: target) == expected,
          "The installed startup bundle changed. Restore it before restarting.")
      },
      isTargetDefault: targetIsDefaultBoot,
      restart: {
        InstallerLog.shared.append("Setup complete. Restarting now.")
        _ = try run("/sbin/shutdown", ["-r", "now"])
      })
  }

  static func skipRecoveryAccountAndRestart() throws {
    try recoveryOnly()
    let record = try installed()
    let config = try configuration.get()
    let expected = try asset("raw/boot.bin", manifest: manifest())
    let target = try esp().appendingPathComponent(config.stage2Path)
    try check(
      try Data(contentsOf: target) == expected,
      "The installed startup bundle changed. Restore it before restarting.")
    try RecoveryAccountRestart.perform(
      receipt: record,
      hasPendingInstallation: FileManager.default.fileExists(atPath: pendingInstallation.path),
      isTargetDefault: targetIsDefaultBoot,
      persist: {
        try run("/sbin/mount", ["-u", "-w", volume.path])
        try RecoveryFileTransaction.write(
          JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]),
          to: receipt)
      },
      restart: {
        InstallerLog.shared.append("Recovery account deferred by request. Restarting now.")
        _ = try run("/sbin/shutdown", ["-r", "now"])
      })
  }

  static func createRecoveryAccount(username: String, password: Data) throws
    -> RecoveryAccountRecord
  {
    try requireEnrollmentEnvironment()
    let target = try accountTarget()
    try RecoveryAccountInstaller.refreshMountedGroup(target)
    _ = try RecoveryAccountInstaller.prepare(target, username: username, password: password)
    // Startup Disk can leave a matching APFS credential before ownership is
    // granted. Reconcile that proven credential before sending the user back.
    // With no credential yet, finalize leaves the prepared account unchanged.
    return try RecoveryAccountInstaller.finalize(target, password: password)
  }
}

extension RecoveryActions {
  static func installed() throws -> [String: Any] {
    guard recovering,
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt))
        as? [String: Any],
      value["status"] as? String == "installed"
    else {
      throw RecoveryFailure(message: "Complete Aurora installation first.")
    }
    return value
  }
  static func readBootArguments() throws -> String {
    let data = try run("/usr/sbin/nvram", ["-x", "-p"])
    guard
      let values = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw RecoveryFailure(message: "Cannot read firmware boot arguments.")
    }
    if let string = values["boot-args"] as? String { return string }
    if let bytes = values["boot-args"] as? Data, let string = String(data: bytes, encoding: .utf8) {
      return string
    }
    try check(values["boot-args"] == nil, "Firmware boot arguments have an unexpected encoding.")
    return ""
  }
  static func bootArguments(_ current: String, flag: String, enabled: Bool) -> String {
    precondition(flag == "aura-debug" || flag == "aura-proxy")
    let regex = try! NSRegularExpression(
      pattern: "(?<!\\S)" + NSRegularExpression.escapedPattern(for: flag) + "(?!\\S)")
    let cleaned = regex.stringByReplacingMatches(
      in: current, range: NSRange(current.startIndex..., in: current), withTemplate: "")
    if enabled {
      return cleaned + (cleaned.isEmpty || cleaned.last!.isWhitespace ? "" : " ") + flag
    }
    return cleaned
  }
  static func cli(_ arguments: [String]) throws {
    try recoveryOnly()
    try run("/sbin/mount", ["-u", "-w", volume.path])
    switch arguments {
    case ["recover"]:
      let record = try installed()
      // Its Stage 2 belongs to the staged Stage 1, which isn't enrolled yet.
      try check(
        pendingStage1Update() == nil,
        "A startup software update is waiting. Open Aurora Installer to finish it first.")
      guard let name = record["mode"] as? String, let mode = AuraBootMode(rawValue: name),
        let path = record["stage2Path"] as? String,
        path == (try configuration.get()).stage2Path
      else {
        throw RecoveryFailure(message: "The installed boot mode is not recorded.")
      }
      let m = try manifest()
      try check(
        hash(try asset(mode.stage1Path, manifest: m)) == record["stage1SHA256"] as? String,
        "The recovery baseline does not match the enrolled stage 1.")
      let bytes = try asset(mode.stage2Path, manifest: m)
      var files = try RecoveryBaseline.firmware(
        manifest: m, root: payloadRoot())
      files[path] = bytes
      let destination = try esp()
      let backup = state.appendingPathComponent("recover-" + UUID().uuidString + ".before")
      try RecoveryBaseline.restore(
        files: files, root: destination, backup: backup, stage2Path: path
      ) {
        try atomic($0, to: $1)
      }
      print("Stage 2 and device firmware restored.")
    case ["debug", "on"], ["debug", "off"], ["proxy", "on"], ["proxy", "off"]:
      let before = try readBootArguments()
      let after = bootArguments(before, flag: "aura-" + arguments[0], enabled: arguments[1] == "on")
      try atomic(
        Data(before.utf8),
        to: state.appendingPathComponent("boot-args-" + UUID().uuidString + ".before"))
      try run("/usr/sbin/nvram", ["boot-args=" + after])
      try check(try readBootArguments() == after, "Firmware boot arguments did not verify.")
      print("Aura \(arguments[0]) \(arguments[1]) for the next boot.")
    default:
      throw RecoveryFailure(
        message: "Usage: aura [recover | debug on/off | proxy on/off]")
    }
  }
  static func installCommand() throws {
    guard inRecovery else { return }
    try recoveryOnly()
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let fm = FileManager.default
    guard let executable = Bundle.main.executableURL else {
      throw InstallConfigurationError.invalid
    }
    // Single-quote the runtime path; volume names may contain shell metacharacters.
    let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let script =
      "#!/bin/sh\nif [ \"$#\" -eq 0 ]; then\n  exec \(command)\nfi\nexec \(command) --aura-command \"$@\"\n"
    let persistent = volume.appendingPathComponent("aura")
    try atomic(Data(script.utf8), to: persistent)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: persistent.path)
    // Recovery's root can be read-only. Try its conventional local bin,
    // then install into its writable home and initialize new shell sessions.
    let local = URL(fileURLWithPath: "/usr/local/bin")
    do {
      try fm.createDirectory(at: local, withIntermediateDirectories: true)
      let link = local.appendingPathComponent("aura")
      if !fm.fileExists(atPath: link.path) {
        try fm.createSymbolicLink(at: link, withDestinationURL: persistent)
      }
      if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == persistent.path { return }
    } catch {}
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let bin = home.appendingPathComponent("bin")
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let link = bin.appendingPathComponent("aura")
    if !fm.fileExists(atPath: link.path) {
      try fm.createSymbolicLink(at: link, withDestinationURL: persistent)
    }
    try check(
      (try? fm.destinationOfSymbolicLink(atPath: link.path)) == persistent.path,
      "An existing aura command was left unchanged.")
    let line = "\n# Aurora Recovery command\nexport PATH=\"$HOME/bin:$PATH\"\n"
    for name in [".zprofile", ".zshrc", ".bash_profile", ".profile"] {
      let file = home.appendingPathComponent(name)
      let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      if !old.contains("# Aurora Recovery command") {
        try atomic(Data((old + line).utf8), to: file)
      }
    }
  }
}

extension RecoveryActions {
  /// The stub files that name the enrolled Stage 1, which a later Reset reads.
  static let stubStage1Path = "Finish Installation.app/Contents/Resources/boot.bin"
  static let stubStage1MachOPath = "Finish Installation.app/Contents/Resources/boot.macho"

  /// A Stage 1 the macOS installer staged that isn't enrolled yet.
  static func pendingStage1Update() -> Stage1Reenrollment? {
    guard recovering, let config = try? configuration.get() else { return nil }
    return Stage1Reenrollment.pending(
      receipt: try? installed(),
      hasPendingInstallation: FileManager.default.fileExists(atPath: pendingInstallation.path),
      bootMode: config.bootMode, stage2Path: config.stage2Path, manifest: try? manifest())
  }

  /// Enrolls the staged Stage 1 for this installation with the owner's
  /// password, as setup does. Returns false when it was already enrolled.
  @discardableResult static func reenrollStage1(
    owner: RecoveryOwner, password: String, progress: @escaping (Double, String) -> Void
  ) throws -> Bool {
    // Repeat the check here so bypassing the GUI cannot reach any write.
    try requireEnrollmentEnvironment()
    try RecoveryOwnerResolver.verify(owner, current: resolveOwner())
    let config = try configuration.get()
    let record = try installed()
    try check(
      !FileManager.default.fileExists(atPath: pendingInstallation.path),
      "Setup hasn't finished. Continue setup instead.")
    guard let chip = chipID() else {
      throw RecoveryFailure(message: "Could not read this Mac's chip, so nothing was changed.")
    }
    progress(0.05, "Verifying the new startup software")
    let m = try manifest()
    guard let mode = AuraBootMode(rawValue: config.bootMode),
      m["defaultMode"] as? String == config.bootMode,
      (m["modes"] as? [String: [String: Any]])?[config.bootMode]?["espPath"] as? String
        == config.stage2Path
    else {
      throw RecoveryFailure(
        message: "The recovery payload does not match this installation's boot mode.")
    }
    let stage1 = try asset(mode.stage1Path, manifest: m)
    let raw = try asset(AuraBootMode.raw.stage1Path, manifest: m)
    let stage2 = try asset(mode.stage2Path, manifest: m)
    let target = try esp().appendingPathComponent(config.stage2Path)
    let stage2Bytes = (try? FileManager.default.attributesOfItem(atPath: target.path))
      .flatMap { $0[.type] as? FileAttributeType == .typeRegular ? $0[.size] as? Int : nil }
    guard
      let update = try Stage1Reenrollment.verify(
        stage1: stage1, mode: mode, chipID: chip, espUUID: config.espUUID,
        stage2Path: config.stage2Path, receipt: record, stage2Bytes: stage2Bytes)
    else {
      InstallerLog.shared.append("This startup software is already enrolled. Nothing was changed.")
      return false
    }
    progress(0.15, "Checking the recovery environment")
    try run("/sbin/mount", ["-u", "-w", volume.path])
    let fm = FileManager.default
    try fm.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let operation = state.appendingPathComponent("stage1-update-" + UUID().uuidString)
    try fm.createDirectory(
      at: operation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    InstallerLog.shared.persist(to: operation.appendingPathComponent("installer.log"))
    let stage1Path = operation.appendingPathComponent("stage1")
    let marker = volume.appendingPathComponent(".IAPhysicalMedia")
    let disabledMarker = volume.appendingPathComponent("IAPhysicalMedia-disabled.plist")
    try Stage1ReenrollmentRunner.run(
      stage: {
        if let window = mode.executeWindowSize {
          try stageExpandedStage1(stage1, window: window, at: stage1Path)
        } else {
          try RecoveryFileTransaction.write(stage1, to: stage1Path)
        }
      },
      authorizePolicy: {
        progress(0.3, "Authorizing the boot environment")
        try authorized(
          "/usr/bin/bputil",
          RecoveryBootPolicy.authorizationArguments(
            groupUUID: groupUUID, allowCustomBootArguments: allowsCustomBootArguments),
          owner: owner, password: password)
      },
      enroll: {
        progress(0.55, mode == .macho ? slowEnrollment : "Installing the startup software")
        try authorized(
          "/usr/bin/kmutil", mode.enrollmentArguments(stage1: stage1Path.path, volume: volume.path),
          owner: owner, password: password)
      },
      record: {
        progress(0.85, "Finishing the update")
        try RecoveryFileTransaction.write(
          JSONSerialization.data(
            withJSONObject: update.receipt(after: record, stage2SHA256: hash(stage2)),
            options: [.prettyPrinted, .sortedKeys]), to: receipt)
        // A later Reset compares these with the payload's Stage 1.
        try RecoveryFileTransaction.write(raw, to: volume.appendingPathComponent(stubStage1Path))
        if mode == .macho {
          try RecoveryFileTransaction.write(
            stage1, to: volume.appendingPathComponent(stubStage1MachOPath))
        }
      },
      finish: {
        // The volume starts its new Stage 1 again instead of this app.
        try RecoveryVersionMetadata.showForStartupDisk(system: volume)
        try RecoveryFileTransaction.flushDirectory(
          volume.appendingPathComponent("System/Library/CoreServices"))
        if fm.fileExists(atPath: marker.path) {
          try RecoveryFileTransaction.write(Data(contentsOf: marker), to: disabledMarker)
          try fm.removeItem(at: marker)
          try RecoveryFileTransaction.flushDirectory(volume)
        }
      })
    try? fm.removeItem(at: stage1Path)
    InstallerLog.shared.append(
      "Startup software updated: \(mode.rawValue) Stage 1 \(update.stage1SHA256.prefix(12)), loading \(update.stage2Path)."
    )
    progress(1, "Startup software updated")
    return true
  }

  /// Restarts after an update, which leaves Stage 2 to the distribution, so
  /// unlike setup it doesn't compare Stage 2 with the recovery copy.
  static func restartAfterStage1Update() throws {
    try recoveryOnly()
    _ = try installed()
    try check(
      pendingStage1Update() == nil,
      "The startup software update didn't finish. Open Aurora Installer again to finish it.")
    InstallerLog.shared.append("Startup software updated. Restarting now.")
    _ = try run("/sbin/shutdown", ["-r", "now"])
  }
}
