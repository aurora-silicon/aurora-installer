#if os(macOS)
  import Foundation
  import OSLog

  /// Unregisters the helper after a completed operation. Protected execution
  /// and removal journals remain for inspection and recovery.
  public protocol HelperSelfUninstalling: Sendable {
    var shouldRetire: Bool { get }
    /// Called after the removal reply is built; it must let that reply reach
    /// the app before the helper goes away.
    func uninstallAfterRemoval()
  }

  extension HelperSelfUninstalling {
    public var shouldRetire: Bool { false }
  }

  /// For tests and any caller that is not the running helper.
  public struct NoHelperSelfUninstall: HelperSelfUninstalling {
    public init() {}
    public func uninstallAfterRemoval() {}
  }

  public struct LaunchdHelperSelfUninstaller: HelperSelfUninstalling {
    public let shouldRetire = true
    private static let logger = Logger(subsystem: "com.omarchy.installer", category: "helper")

    private let label: String
    private let jobFile: URL
    private let binary: URL
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
      delay: Duration = .seconds(2),
      unload: @escaping @Sendable (String) -> Void = LaunchdHelperSelfUninstaller.bootout,
      exitProcess: @escaping @Sendable () -> Void = { exit(0) }
    ) {
      self.label = label
      self.jobFile = jobFile
      self.binary = binary
      self.delay = delay
      self.unload = unload
      self.exitProcess = exitProcess
    }

    /// Waits for the completion reply to reach the app, then unregisters.
    public func uninstallAfterRemoval() {
      let uninstaller = self
      Task.detached {
        // The suspending clock stops while the Mac sleeps, so the delay still
        // gives the reply time to reach the app after it wakes.
        try? await Task.sleep(for: uninstaller.delay, clock: .suspending)
        uninstaller.removeFiles()
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
      for item in [jobFile, binary] {
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
