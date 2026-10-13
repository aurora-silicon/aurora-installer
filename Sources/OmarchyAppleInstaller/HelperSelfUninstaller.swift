#if os(macOS)
  import Foundation
  import OSLog

  /// Removes the helper from the Mac once a removal has completed, so no
  /// Omarchy trace is left: its launchd job file, its binary in
  /// PrivilegedHelperTools and its whole state directory, including retired
  /// install journals. A later install sets the helper up again.
  public protocol HelperSelfUninstalling: Sendable {
    /// Called after the removal reply is built; it must let that reply reach
    /// the app before the helper goes away.
    func uninstallAfterRemoval()
  }

  /// For tests and any caller that is not the running helper.
  public struct NoHelperSelfUninstall: HelperSelfUninstalling {
    public init() {}
    public func uninstallAfterRemoval() {}
  }

  public struct LaunchdHelperSelfUninstaller: HelperSelfUninstalling {
    private static let logger = Logger(subsystem: "com.omarchy.installer", category: "helper")

    private let label: String
    private let jobFile: URL
    private let binary: URL
    private let workingDirectory: URL
    private let delay: Duration
    private let unload: @Sendable (String) -> Void
    private let exitProcess: @Sendable () -> Void

    /// The defaults are the fixed, identity-derived paths; tests pass a
    /// temporary root and record `unload` and `exitProcess` instead of
    /// running them.
    public init(
      label: String = InstallerProductIdentity.helperIdentifier,
      jobFile: URL = URL(fileURLWithPath: InstallerProductIdentity.systemLaunchDaemonPath),
      binary: URL = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools/"
          + InstallerProductIdentity.helperIdentifier),
      workingDirectory: URL = URL(
        fileURLWithPath: InstallerProductIdentity.helperWorkingDirectory, isDirectory: true),
      delay: Duration = .seconds(2),
      unload: @escaping @Sendable (String) -> Void = LaunchdHelperSelfUninstaller.bootout,
      exitProcess: @escaping @Sendable () -> Void = { exit(0) }
    ) {
      self.label = label
      self.jobFile = jobFile
      self.binary = binary
      self.workingDirectory = workingDirectory
      self.delay = delay
      self.unload = unload
      self.exitProcess = exitProcess
    }

    /// Deletes the files at once, so the app sees no helper from this moment
    /// and a later install blesses a fresh one (which replaces this job and
    /// ends this process), then unloads and exits after the delay that lets
    /// the removal reply reach the app.
    public func uninstallAfterRemoval() {
      removeFiles()
      let uninstaller = self
      Task.detached {
        // The suspending clock stops while the Mac sleeps, so the delay still
        // gives the reply time to reach the app after it wakes.
        try? await Task.sleep(for: uninstaller.delay, clock: .suspending)
        uninstaller.unloadAndExit()
      }
    }

    func uninstallNow() {
      removeFiles()
      unloadAndExit()
    }

    private func unloadAndExit() {
      unload(label)
      exitProcess()
    }

    private func removeFiles() {
      for item in [jobFile, binary, workingDirectory] {
        do {
          if FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.removeItem(at: item)
          }
        } catch {
          Self.logger.error(
            "could not remove \(item.path, privacy: .public): \(String(describing: error), privacy: .public)"
          )
        }
      }
    }

    /// Asks launchd to unload the helper's own job. launchd then stops this
    /// process, so the request is started, not waited on.
    public static func bootout(_ label: String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["bootout", "system/\(label)"]
      try? process.run()
      Thread.sleep(forTimeInterval: 1)
    }
  }
#endif
