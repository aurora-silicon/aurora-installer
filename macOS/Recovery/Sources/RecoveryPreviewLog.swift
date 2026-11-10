import AppKit

#if AURORA_STEP2_PREVIEW
  /// Preview builds only: Installer Log lines shaped like a real Recovery
  /// run, so the log window can be reviewed. Volume names and identifiers are
  /// fictitious and nothing here runs a command.
  enum PreviewLog {
    static let group = "5C1A7E2B-93D4-4F0A-8B6E-2D7C9A1F3E58"
    static let system = "A3B9F1C2-6D4E-4F8A-9C1B-7E2D5A8F0B34"
    static let data = "D7E2C4A1-1B9F-4C3D-8E5A-6F0B2D9C7A13"
    static let volume = "/Volumes/Aurora Fedora Remix"

    static func command(
      _ executable: String, _ arguments: [String], output: [String] = [], status: Int32 = 0,
      reason: String? = nil, seconds: Double, log: InstallerLog
    ) {
      let command = CommandLog(executable, arguments, log: log)
      command.output(output.map { $0 + "\n" }.joined())
      command.finish(status: status, reason: reason, elapsed: seconds)
    }

    /// The launch check: Recovery, the target volume, its paired boot
    /// policy and the owner who authorizes enrollment.
    static func check(passed: Bool, log: InstallerLog = .shared) {
      log.append("Checking the Recovery environment, the target volume and its boot policy")
      command(
        "/usr/sbin/diskutil", ["info", "-plist", volume], output: ["<?xml version=\"1.0\"?>"],
        seconds: 0.18, log: log)
      command(
        "/usr/bin/bputil", ["-d", "-v", group],
        output: [
          "Current local policy:", "OS Type                                       : macOS",
          "Security Mode: Permissive Security",
          "1TR / Paired Recovery                       : Yes",
        ], status: passed ? 0 : 1, seconds: 0.62, log: log)
      guard passed else {
        log.append(
          "Recovery preflight failed: This Mac couldn’t be checked (simulated).", level: .error)
        return
      }
      log.append("Recovery environment verified. Resolving the installation owner.")
      command(
        "/usr/sbin/diskutil", ["apfs", "listUsers", data, "-plist"], output: ["<plist>"],
        seconds: 0.27, log: log)
      log.append("Authorizing owner: preview (8B4F2C1A-0D3E-4A6B-9C5D-1E7F3A2B6C90)")
    }

    /// One simulated setup step. Steps that authorize or enroll run a
    /// command for the whole step; it returns the command to finish.
    static func step(_ name: String, log: InstallerLog = .shared) -> CommandLog? {
      log.append(name + " (simulated)")
      switch name {
      case "Authorizing the boot environment":
        return CommandLog("/usr/bin/bputil", ["-nc", "-v", group], log: log)
      case "Installing the startup software":
        return CommandLog(
          "/usr/bin/kmutil",
          AuraBootMode.standard.enrollmentArguments(
            stage1: "/Volumes/Aurora Fedora Remix/Aurora/Recovery/State/operation-1/stage1",
            volume: volume), log: log)
      default: return nil
      }
    }

    /// A run that has reached enrollment: the check passed and kmutil runs.
    static func running(log: InstallerLog) {
      check(passed: true, log: log)
      log.append("Recovery environment verified. Checking the installation’s recovery account.")
      log.append("Verifying the installation files (simulated)")
      command(
        "/sbin/mount", ["-u", "-w", volume], seconds: 0.09, log: log)
      log.append("Authorizing the boot environment (simulated)")
      command(
        "/usr/bin/bputil", ["-nc", "-v", group],
        output: ["Enter password for preview:", "Authorized boot policy change."], seconds: 6.4,
        log: log)
      log.append("bputil: completed")
      _ = step("Installing the startup software", log: log)
    }

    /// A run that stopped: the owner's password was refused by bputil.
    static func failed(log: InstallerLog) {
      check(passed: true, log: log)
      log.append("Recovery environment verified. Checking the installation’s recovery account.")
      log.append("Authorizing the boot environment (simulated)")
      command(
        "/usr/bin/bputil", ["-nc", "-v", group],
        output: [
          "Enter password for preview:", "password: preview-password",
          "bputil: the owner’s credentials could not be verified (0xe00002d8)",
        ], status: 2, reason: "Authorization failed: the owner password was not accepted",
        seconds: 3.1, log: log)
      log.append(
        "bputil: the owner password was not accepted", level: .error)
      log.append(
        "Setup failed: bputil failed: the owner password was not accepted. "
          + "Open Window → Installer Log for the command output.", level: .error)
    }
  }

  /// `--render-log=DIRECTORY`: draws the Installer Log window offscreen at
  /// each filter level, while a command runs and after a failure, then quits.
  /// No window is shown.
  enum RecoveryLogRenderer {
    static func run(directory: URL) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-log-render-" + UUID().uuidString)
      try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      var number = 0
      func save(_ log: InstallerLog, _ filter: InstallerLogFilter, _ search: String, _ name: String)
      {
        number += 1
        let controller = InstallerLogWindowController(log: log, filter: filter)
        controller.apply(filter: filter, search: search)
        let url = directory.appendingPathComponent(String(format: "%02d-%@.png", number, name))
        guard let window = controller.window, let frame = window.contentView?.superview,
          capture(frame, to: url)
        else {
          FileHandle.standardError.write(Data("render-log: \(name) failed\n".utf8))
          return
        }
        print(url.path)
      }
      let running = InstallerLog(directory: scratch)
      PreviewLog.running(log: running)
      settle()
      save(running, .all, "", "recovery-log-all-running-command")
      save(running, .errorsAndProgress, "", "recovery-log-progress-running-command")
      let failed = InstallerLog(directory: scratch)
      PreviewLog.failed(log: failed)
      settle()
      save(failed, .errorsOnly, "", "recovery-log-errors-after-failure")
      save(failed, .errorsAndProgress, "", "recovery-log-progress-after-failure")
      save(failed, .all, "", "recovery-log-all-after-failure")
      save(failed, .all, "bputil", "recovery-log-search-bputil")
    }

    /// Lets the log publish its lines to the main queue.
    private static func settle() {
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    private static func capture(_ view: NSView, to url: URL) -> Bool {
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      view.layoutSubtreeIfNeeded()
      view.display()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return false
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let bytes = bitmap.representation(using: .png, properties: [:]) else { return false }
      return (try? bytes.write(to: url)) != nil
    }
  }
#endif
