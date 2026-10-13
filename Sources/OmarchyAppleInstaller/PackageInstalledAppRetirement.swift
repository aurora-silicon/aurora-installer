#if os(macOS)
  import Darwin
  import Foundation

  /// Removes the installer app that the installer package put in
  /// `/Applications`, under the current or the legacy name, once the app has
  /// installed its own helper. It only ever looks at those fixed paths, and
  /// keeps any bundle that is a link, carries another bundle identifier, is
  /// not owned by root (so the person put it there, not the package), or has
  /// a process running from it. Every refusal is reported, never thrown: the
  /// install it follows must not fail because of it.
  public struct PackageInstalledAppRetirement: Sendable {
    public enum Result: Equatable, Sendable {
      case removed
      case absent
      case keptLink
      case keptNotABundle
      case keptForeignIdentifier(String)
      case keptNotInstalledByPackage
      case keptRunning
      case keptRemovalFailed(String)
    }

    private let applicationsDirectory: URL
    private let privateDirectory: URL
    private let appNames: [String]
    private let bundleIdentifier: String
    private let packageOwner: uid_t
    /// Nil when the process list can't be verified.
    private let runningExecutablePaths: @Sendable () -> [String]?

    /// - Parameter privateDirectory: where a candidate is moved before it is
    ///   checked again and deleted. It is writable only by root, on the same
    ///   volume as `applicationsDirectory`, and deliberately not inside the
    ///   helper's state directory, which self-uninstall deletes: a bundle
    ///   that has to stay aside, say after a crash mid-move, is never swept
    ///   up with it. It is created as needed and removed once empty.
    public init(
      applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
      privateDirectory: URL = URL(
        fileURLWithPath: InstallerProductIdentity.helperWorkingDirectory + ".aside",
        isDirectory: true),
      appNames: [String] = [
        InstallerProductIdentity.appName, InstallerProductIdentity.legacyAppName,
      ],
      bundleIdentifier: String = InstallerProductIdentity.appIdentifier,
      packageOwner: uid_t = 0,
      runningExecutablePaths: @escaping @Sendable () -> [String]? = {
        // A copy of the installer whose path can't be read could be running
        // from the very bundle being retired, so the list proves nothing.
        guard let processes = PackageInstalledAppRetirement.runningProcesses(),
          !processes.contains(where: { $0.path == nil && $0.mayBeInstaller })
        else { return nil }
        return processes.compactMap(\.path)
      }
    ) {
      self.applicationsDirectory = applicationsDirectory
      self.privateDirectory = privateDirectory
      self.appNames = appNames
      self.bundleIdentifier = bundleIdentifier
      self.packageOwner = packageOwner
      self.runningExecutablePaths = runningExecutablePaths
    }

    /// A one-line account of `run()` for logs.
    public static func summary(_ results: [String: Result]) -> String {
      results.keys.sorted().map { "\($0): \(results[$0].map { "\($0)" } ?? "")" }
        .joined(separator: "; ")
    }

    /// One result per candidate path, keyed by the bundle's file name.
    public func run() -> [String: Result] {
      var results: [String: Result] = [:]
      for name in appNames {
        let bundle = applicationsDirectory.appendingPathComponent(name + ".app", isDirectory: true)
        results[bundle.lastPathComponent] = retire(bundle)
      }
      // Leaves nothing behind unless a bundle had to stay aside.
      rmdir(privateDirectory.path)
      return results
    }

    /// Moves the candidate out of `/Applications` first, then checks and
    /// deletes only what it moved. `/Applications` is writable by the admin
    /// group, so checking in place and then deleting by name would let an
    /// admin process swap another root-owned app in between; the private
    /// directory is out of that process's reach.
    private func retire(_ bundle: URL) -> Result {
      var status = stat()
      guard lstat(bundle.path, &status) == 0 else {
        return .absent
      }
      if status.st_mode & S_IFMT == S_IFLNK {
        return .keptLink
      }
      guard status.st_mode & S_IFMT == S_IFDIR else {
        return .keptNotABundle
      }
      if isRunning(from: bundle) {
        return .keptRunning
      }
      // Only this app, as the package installed it, is ever moved; checked
      // again on what was moved.
      if let verdict = identity(of: bundle, owner: status.st_uid) {
        return verdict
      }
      guard preparePrivateDirectory() else {
        return .keptRemovalFailed("no private directory to move it into")
      }
      let moved = privateDirectory.appendingPathComponent(
        ".retiring-\(UUID().uuidString).app", isDirectory: true)
      // Atomic, never replacing anything, and never following a link.
      guard renamex_np(bundle.path, moved.path, UInt32(RENAME_EXCL)) == 0 else {
        return .keptRemovalFailed("could not move aside: \(String(cString: strerror(errno)))")
      }
      let verdict = check(moved, originallyAt: bundle)
      guard verdict == nil else {
        // Put it back as it was; if something has since taken its name, it
        // stays aside rather than replacing that.
        if renamex_np(moved.path, bundle.path, UInt32(RENAME_EXCL)) != 0 {
          return .keptRemovalFailed("kept aside at \(moved.path): name taken")
        }
        return verdict!
      }
      do {
        try FileManager.default.removeItem(at: moved)
        return .removed
      } catch {
        return .keptRemovalFailed(String(describing: error))
      }
    }

    /// Nil when the moved bundle is exactly what may be removed.
    private func check(_ moved: URL, originallyAt bundle: URL) -> Result? {
      var status = stat()
      guard lstat(moved.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
        return .keptNotABundle
      }
      if let verdict = identity(of: moved, owner: status.st_uid) {
        return verdict
      }
      // A process started from it just before the move now runs from the
      // moved path.
      if isRunning(from: moved) || isRunning(from: bundle) {
        return .keptRunning
      }
      return nil
    }

    /// Nil when the bundle carries this app's identifier and the package's
    /// owner.
    private func identity(of bundle: URL, owner: uid_t) -> Result? {
      let info = bundle.appendingPathComponent("Contents/Info.plist")
      guard let data = try? Data(contentsOf: info),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else {
        return .keptNotABundle
      }
      let identifier = plist["CFBundleIdentifier"] as? String ?? ""
      guard identifier == bundleIdentifier else {
        return .keptForeignIdentifier(identifier)
      }
      guard owner == packageOwner else {
        return .keptNotInstalledByPackage
      }
      return nil
    }

    /// The private directory exists as a real directory owned like the
    /// package's apps (root) and closed to everyone else.
    private func preparePrivateDirectory() -> Bool {
      if mkdir(privateDirectory.path, 0o700) != 0 && errno != EEXIST {
        return false
      }
      var status = stat()
      return lstat(privateDirectory.path, &status) == 0
        && status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == packageOwner
        && status.st_mode & 0o077 == 0
    }

    /// An unverifiable process list counts as running: a bundle is never
    /// removed on a guess.
    private func isRunning(from bundle: URL) -> Bool {
      let contents = bundle.appendingPathComponent("Contents", isDirectory: true).path + "/"
      guard let paths = runningExecutablePaths() else { return true }
      return paths.contains { $0.hasPrefix(contents) }
    }

    /// The installer app's executable, by which its processes are found.
    public static let installerExecutableName = "OmarchyAppleInstallerApp"

    /// One running process. `path` is nil when the kernel can't give it, as
    /// for a live process whose executable was deleted or replaced on disk;
    /// `name` is then the kernel's record of it (the first 16 characters).
    public struct RunningProcess: Sendable {
      public let pid: pid_t
      public let path: String?
      public let name: String

      /// Could be a copy of the installer: by path, or by name when the path
      /// is gone.
      public var mayBeInstaller: Bool {
        if let path {
          return path.hasSuffix(".app/Contents/MacOS/" + installerExecutableName)
        }
        return name == String(installerExecutableName.prefix(Int(MAXCOMLEN)))
      }
    }

    /// The executable path of every process this process can see.
    public static func runningExecutablePaths() -> [String] {
      runningProcesses()?.compactMap(\.path) ?? []
    }

    /// Every running process, or nil when the list can't be verified. A
    /// process whose path can't be read is looked up again: if it has exited
    /// or is a zombie it has no executable and is left out; if it is live, it
    /// is kept with its kernel name; if even that can't be read, the list is
    /// unverified.
    public static func runningProcesses() -> [RunningProcess]? {
      let capacity = proc_listallpids(nil, 0)
      guard capacity > 0 else {
        return nil
      }
      var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
      // Returns the number of process IDs written.
      let listed = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
      }
      guard listed > 0 else {
        return nil
      }
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      var processes: [RunningProcess] = []
      for pid in pids.prefix(min(Int(listed), pids.count)) where pid > 0 {
        let length = path.withUnsafeMutableBufferPointer { buffer in
          proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        if length > 0 {
          let bytes = path.prefix(Int(length)).map { UInt8(bitPattern: $0) }
          processes.append(
            RunningProcess(pid: pid, path: String(decoding: bytes, as: UTF8.self), name: ""))
          continue
        }
        switch kernelRecord(of: pid) {
        case .gone:
          continue
        case .live(let name):
          processes.append(RunningProcess(pid: pid, path: nil, name: name))
        case .unreadable:
          return nil
        }
      }
      return processes
    }

    private enum KernelRecord {
      case gone
      case live(name: String)
      case unreadable
    }

    /// The kernel's record of a process, readable by any user.
    private static func kernelRecord(of pid: pid_t) -> KernelRecord {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
        return .unreadable
      }
      guard size > 0, info.kp_proc.p_stat != SZOMB else {
        return .gone
      }
      let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      return .live(name: name)
    }
  }
#endif
