#if os(macOS)
  import Foundation
  import OSLog

  /// Unregisters the helper after a completed operation. Protected execution
  /// and removal journals remain for inspection and recovery.
  public protocol HelperSelfUninstalling: Sendable {
    var shouldRetire: Bool { get }
    /// Called after the completion reply is sent; the helper goes away once
    /// `delivered` reports that the reply reached the app.
    func uninstallAfterRemoval(delivered: HelperReplyDelivery)
  }

  /// Fires once the app's connection that carried a reply has closed.
  ///
  /// The app invalidates each connection as soon as its reply arrives, and a
  /// connection is also invalidated when the app quits or crashes, so the
  /// close is the receipt the helper waits for before it unregisters.
  public final class HelperReplyDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// A delivery that has already happened, for callers with no connection.
    public static var immediate: HelperReplyDelivery {
      let delivery = HelperReplyDelivery()
      delivery.fire()
      return delivery
    }

    public var hasFired: Bool { lock.withLock { delivered } }

    public func fire() {
      let resumed = lock.withLock {
        delivered = true
        defer { waiters.removeAll() }
        return Array(waiters.values)
      }
      for waiter in resumed { waiter.resume() }
    }

    /// Returns when the delivery fires or the waiting task is cancelled.
    public func wait() async {
      let id = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let ready = lock.withLock {
            if delivered || Task.isCancelled { return true }
            waiters[id] = continuation
            return false
          }
          if ready { continuation.resume() }
        }
      } onCancel: {
        lock.withLock { waiters.removeValue(forKey: id) }?.resume()
      }
    }
  }

  extension HelperSelfUninstalling {
    public var shouldRetire: Bool { false }
  }

  /// For tests and any caller that is not the running helper.
  public struct NoHelperSelfUninstall: HelperSelfUninstalling {
    public init() {}
    public func uninstallAfterRemoval(delivered: HelperReplyDelivery) {}
  }

  public struct LaunchdHelperSelfUninstaller: HelperSelfUninstalling {
    public let shouldRetire = true
    private static let logger = Logger(
      subsystem: InstallerProductIdentity.appIdentifier, category: "helper")

    private let label: String
    private let jobFile: URL
    private let binary: URL
    private let deliveryDeadline: Duration
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
      deliveryDeadline: Duration = LaunchdHelperSelfUninstaller.defaultDeliveryDeadline,
      unload: @escaping @Sendable (String) -> Void = LaunchdHelperSelfUninstaller.bootout,
      exitProcess: @escaping @Sendable () -> Void = { exit(0) }
    ) {
      self.label = label
      self.jobFile = jobFile
      self.binary = binary
      self.deliveryDeadline = deliveryDeadline
      self.unload = unload
      self.exitProcess = exitProcess
    }

    /// How long a helper waits for an app that keeps its connection open
    /// after the completion reply. The app closes it on receipt, and quitting
    /// or crashing closes it too, so only a hung app reaches this bound.
    public static let defaultDeliveryDeadline: Duration = .seconds(30)

    /// Waits for the completion reply to reach the app, then unregisters.
    public func uninstallAfterRemoval(delivered: HelperReplyDelivery) {
      let uninstaller = self
      Task.detached {
        // The suspending clock stops while the Mac sleeps, so a Mac that
        // sleeps right after the reply still gets the whole bound once awake.
        let deadline = Task.detached {
          try? await Task.sleep(for: uninstaller.deliveryDeadline, clock: .suspending)
          if !Task.isCancelled {
            Self.logger.notice("the app did not close its connection; retiring anyway")
            delivered.fire()
          }
        }
        await delivered.wait()
        deadline.cancel()
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

    /// Asks launchd to unload the helper's own job. launchd stops this
    /// process as part of the bootout, so normally the wait never returns;
    /// when the bootout fails, launchctl exits and the helper exits itself.
    public static func bootout(_ label: String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["bootout", "system/\(label)"]
      do {
        try process.run()
      } catch {
        logger.error(
          "could not run launchctl bootout: \(String(describing: error), privacy: .public)")
        return
      }
      process.waitUntilExit()
      if process.terminationStatus != 0 {
        logger.error("launchctl bootout exited \(process.terminationStatus, privacy: .public)")
      }
    }
  }
#endif
