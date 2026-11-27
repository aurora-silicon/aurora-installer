#if os(macOS)
  import Darwin
  import Foundation
  import Security
  import ServiceManagement

  /// Starts the helper bundled in the app for this session with
  /// `SMJobSubmit`. launchd runs a root-owned copy of the helper as root and
  /// serves its Mach service, but holds the job in memory only: nothing is
  /// written to the LaunchDaemons folders, so macOS shows no background item
  /// notice, and the job is gone after a restart until the next authorized
  /// action starts it again.
  ///
  /// The app first copies the helper into its own private temporary folder,
  /// which a root job can read wherever the app runs from, then has launchd
  /// copy that into `/Library/PrivilegedHelperTools` as root. The root-owned
  /// copy is checked against the helper's code signing requirement, and the
  /// job launchd runs is the one linked into that copy, as with `SMJobBless`.
  public struct SessionHelperLauncher: InstallerHelperBlessing {
    /// The right `SMJobSubmit` and `SMJobRemove` need for the system domain.
    static let modifyDaemonsRight = "com.apple.ServiceManagement.daemons.modify"
    /// The longest a root step (a copy or a removal) may take.
    static let stepTimeout: Duration = .seconds(60)

    private let label: String
    private let bundledHelper: URL
    private let helperRequirement: @Sendable () throws -> String

    /// - Parameter helperRequirement: the code signing requirement the
    ///   root-owned copy must meet, from the release configuration; the same
    ///   one the app holds the helper to over XPC.
    public init(
      label: String = InstallerProductIdentity.helperIdentifier,
      bundledHelper: URL = SessionHelperLauncher.bundledHelperURL(),
      helperRequirement: @escaping @Sendable () throws -> String
    ) {
      self.label = label
      self.bundledHelper = bundledHelper
      self.helperRequirement = helperRequirement
    }

    /// Where the app carries its helper, named by its label.
    public static func bundledHelperURL(
      in bundle: Bundle = .main,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> URL {
      bundle.bundleURL
        .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        .appendingPathComponent(label, isDirectory: false)
    }

    /// Whether this build can start its helper. Builds with a real signing
    /// identity declare the helper and the requirement it must meet in
    /// `SMPrivilegedExecutables`, Apple's key for an app's privileged
    /// helpers; ad hoc builds leave it out and rely on the installer package.
    public static func isDeclared(
      in bundle: Bundle = .main,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> Bool {
      let executables = bundle.infoDictionary?["SMPrivilegedExecutables"] as? [String: String]
      return executables?[label]?.isEmpty == false
    }

    public func blessSilently(
      with authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      await start(credentials: authorization, allowingDialog: false, confirm: confirm)
    }

    public func blessWithDialog(
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      await start(credentials: nil, allowingDialog: true, confirm: confirm)
    }

    /// Authorizes (a dialog may take minutes), then confirms, then replaces
    /// at once, so the confirmation describes the helper that is replaced.
    private func start(
      credentials: MachineOwnerAuthorization?,
      allowingDialog: Bool,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      let authorized = await Task.detached {
        LaunchAuthorization.authorize(
          right: Self.modifyDaemonsRight, credentials: credentials,
          allowingDialog: allowingDialog)
      }.value
      let rights: LaunchAuthorization
      switch authorized {
      case .success(let granted):
        rights = granted
      case .failure(let result):
        return result.value
      }
      guard await confirm() else {
        return .declined
      }
      let label = label
      let bundledHelper = bundledHelper
      let helperRequirement = helperRequirement
      return await Task.detached {
        do {
          let launchd = SystemLaunchd(authorization: rights)
          try Self.replace(
            label: label, bundledHelper: bundledHelper,
            helperRequirement: try helperRequirement(), launchd: launchd)
          return .blessed
        } catch {
          return .failed(String(describing: error))
        }
      }.value
    }

    /// Unloads whatever answers to the label (the provisioner has checked it
    /// is idle), removes a startup job an earlier version left, puts the
    /// checked copy in place and submits its job.
    static func replace(
      label: String, bundledHelper: URL, helperRequirement: String,
      launchd: any SessionLaunchd,
      installed: String = InstallerProductIdentity.installedHelperPath,
      persistentJob: String = InstallerProductIdentity.systemLaunchDaemonPath,
      owner: uid_t = 0
    ) throws {
      let setup = setupLabel(label)
      launchd.remove(label)
      if launchd.isLoaded(label) {
        // A job loaded from a file in /Library/LaunchDaemons.
        try launchd.runAsRoot(["/bin/launchctl", "bootout", "system/\(label)"], label: setup)
      }
      guard !launchd.isLoaded(label) else {
        throw SessionHelperLaunchError.stillLoaded
      }
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: persistentJob) {
        try launchd.runAsRoot(["/bin/rm", "-f", persistentJob], label: setup)
      }
      let directory = (installed as NSString).deletingLastPathComponent
      if !fileManager.fileExists(atPath: directory) {
        try launchd.runAsRoot(["/bin/mkdir", "-p", directory], label: setup)
      }
      // A root job can read the app's own temporary folder wherever the app
      // runs from; folders such as Downloads would need the person's consent.
      let staging = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try fileManager.createDirectory(
        at: staging, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? fileManager.removeItem(at: staging) }
      let staged = staging.appendingPathComponent(label, isDirectory: false)
      try fileManager.copyItem(at: bundledHelper, to: staged)
      try launchd.runAsRoot(["/bin/cp", "-X", staged.path, installed], label: setup)
      try verifyInstalledCopy(installed, requirement: helperRequirement, owner: owner)
      guard
        let embedded = MachOSection.contents(
          segment: "__TEXT", section: "__launchd_plist",
          of: try Data(contentsOf: URL(fileURLWithPath: installed)))
      else {
        throw SessionHelperLaunchError.noJob
      }
      try launchd.submit(job(embedded: embedded, label: label, program: installed))
    }

    /// The label of the short root jobs that prepare the helper's copy.
    static func setupLabel(_ label: String) -> String {
      label + ".setup"
    }

    /// The helper's job: the one linked into the checked copy, with `Program`
    /// set to that copy, which is what `SMJobBless` wrote to
    /// /Library/LaunchDaemons. It must be this helper's, serve its Mach
    /// service and name the app it accepts.
    static func job(embedded: Data, label: String, program: String) throws -> [String: Any] {
      guard
        var job = try? PropertyListSerialization.propertyList(from: embedded, format: nil)
          as? [String: Any],
        job["Label"] as? String == label,
        (job["MachServices"] as? [String: Any])?[label] as? Bool == true,
        let environment = job["EnvironmentVariables"] as? [String: Any],
        let client = environment[InstallerProductIdentity.clientRequirementEnvironmentVariable]
          as? String,
        EngineCodeSigningRequirement.isValid(client),
        job["Program"] == nil, job["ProgramArguments"] == nil, job["BundleProgram"] == nil
      else {
        throw SessionHelperLaunchError.noJob
      }
      job["Program"] = program
      return job
    }

    /// A root-owned regular file in a directory only root can change, with
    /// one link, signed to meet `requirement`. Checked after launchd copied
    /// it, so nothing that could change it afterwards was checked.
    static func verifyInstalledCopy(_ path: String, requirement: String, owner: uid_t) throws {
      var status = stat()
      guard lstat(path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG, status.st_uid == owner, status.st_nlink == 1,
        status.st_mode & 0o022 == 0, status.st_mode & S_IXUSR != 0
      else {
        throw SessionHelperLaunchError.unsafeCopy(path)
      }
      let directory = (path as NSString).deletingLastPathComponent
      guard lstat(directory, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == owner,
        status.st_mode & 0o022 == 0
      else {
        throw SessionHelperLaunchError.unsafeCopy(directory)
      }
      let arguments = ["--verify", "--strict", "-R=" + requirement, path]
      let result = SystemInstallerHelperProbe.runWithStatus("/usr/bin/codesign", arguments)
      guard result.status == 0 else {
        throw SessionHelperLaunchError.signatureRejected
      }
    }

    /// From `launchctl print`: the exit status of a job that has run and
    /// stopped, -1 for one a signal stopped, or nil while it has not finished.
    /// launchd names well-known codes after the number ("78: EX_CONFIG") and
    /// prints "(never exited)" before the first run ends.
    static func exitStatus(launchctlPrint output: String) -> Int32? {
      let lines = output.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard lines.contains("state = not running") else {
        return nil
      }
      if lines.contains(where: { $0.hasPrefix("last terminating signal = ") }) {
        return -1
      }
      let prefix = "last exit code = "
      guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else {
        return nil
      }
      return Int32(line.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber })
    }
  }

  public enum SessionHelperLaunchError: Error, Equatable, CustomStringConvertible {
    /// The job that answered to the label could not be unloaded.
    case stillLoaded
    case unsafeCopy(String)
    case signatureRejected
    case noJob
    case submitFailed(String)
    case stepFailed(String, Int32)
    case stepTimedOut(String)

    public var description: String {
      switch self {
      case .stillLoaded:
        return "The helper that is running could not be stopped."
      case .unsafeCopy(let path):
        return "\(path) is not a root-owned file that only root can change."
      case .signatureRejected:
        return "The helper's copy is not signed as this app's helper."
      case .noJob:
        return "The helper does not carry a launchd job for its service and this app."
      case .submitFailed(let message):
        return "launchd did not take the helper's job: \(message)"
      case .stepFailed(let program, let status):
        return "\(program) failed as root (status \(status))."
      case .stepTimedOut(let program):
        return "\(program) did not finish as root in time."
      }
    }
  }

  /// What the launcher asks of launchd; tests record the calls.
  protocol SessionLaunchd: Sendable {
    /// Unloads the job and waits for its process to stop; quiet when there
    /// is no such job.
    func remove(_ label: String)
    func isLoaded(_ label: String) -> Bool
    func submit(_ job: [String: Any]) throws
    /// Runs one program as root in its own short job and waits for it.
    func runAsRoot(_ arguments: [String], label: String) throws
  }

  struct SystemLaunchd: SessionLaunchd {
    let authorization: LaunchAuthorization

    func remove(_ label: String) {
      var error: Unmanaged<CFError>?
      _ = SMJobRemove(
        kSMDomainSystemLaunchd, label as CFString, authorization.reference, true, &error)
      error?.release()
    }

    func isLoaded(_ label: String) -> Bool {
      SystemInstallerHelperProbe.runWithStatus("/bin/launchctl", ["print", "system/\(label)"])
        .status == 0
    }

    func submit(_ job: [String: Any]) throws {
      var error: Unmanaged<CFError>?
      guard
        SMJobSubmit(kSMDomainSystemLaunchd, job as CFDictionary, authorization.reference, &error)
      else {
        let message = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
        throw SessionHelperLaunchError.submitFailed(message)
      }
    }

    func runAsRoot(_ arguments: [String], label: String) throws {
      remove(label)
      try submit([
        "Label": label,
        "ProgramArguments": arguments,
        "RunAtLoad": true,
        "LaunchOnlyOnce": true,
      ])
      defer { remove(label) }
      let program = arguments.first ?? ""
      let clock = ContinuousClock()
      let deadline = clock.now + SessionHelperLauncher.stepTimeout
      while clock.now < deadline {
        let printed = SystemInstallerHelperProbe.runWithStatus(
          "/bin/launchctl", ["print", "system/\(label)"])
        if printed.status == 0,
          let status = SessionHelperLauncher.exitStatus(launchctlPrint: printed.output)
        {
          guard status == 0 else {
            throw SessionHelperLaunchError.stepFailed(program, status)
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      throw SessionHelperLaunchError.stepTimedOut(program)
    }
  }
#endif
