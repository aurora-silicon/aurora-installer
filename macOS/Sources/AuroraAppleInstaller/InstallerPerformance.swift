#if os(macOS)
  import Darwin
  import Foundation
  import OSLog

  /// Logs each measured step and adds it to the current attempt's timing and
  /// to the Installer Log. Outermost steps are progress lines; the steps
  /// inside them are debug lines.
  enum InstallerPerformance {
    private static let logger = Logger(
      subsystem: InstallerProductIdentity.appIdentifier, category: "performance")
    @TaskLocal private static var depth = 0

    @discardableResult
    static func measure<T>(
      _ phase: String, bytes: UInt64? = nil, _ action: () throws -> T
    ) rethrows -> T {
      InstallerTimingRecorder.current?.begin(phase)
      let level = started(phase)
      let start = InstallerTimingRecorder.now()
      let cpuStart = processCPUTime()
      var completed = false
      defer {
        finish(
          phase, start: start, cpuStart: cpuStart, bytes: bytes, completed: completed, level: level)
      }
      let result = try $depth.withValue(depth + 1) { try action() }
      completed = true
      return result
    }

    @discardableResult
    static func measuring<T>(
      _ phase: String, bytes: UInt64? = nil, _ action: () async throws -> T
    ) async rethrows -> T {
      InstallerTimingRecorder.current?.begin(phase)
      let level = started(phase)
      let start = InstallerTimingRecorder.now()
      let cpuStart = processCPUTime()
      var completed = false
      defer {
        finish(
          phase, start: start, cpuStart: cpuStart, bytes: bytes, completed: completed, level: level)
      }
      let result = try await $depth.withValue(depth + 1) { try await action() }
      completed = true
      return result
    }

    private static func started(_ phase: String) -> InstallerLogLevel {
      let level: InstallerLogLevel = depth == 0 ? .progress : .debug
      let title = InstallerStepTitles.title(for: phase).map { " (\($0))" } ?? ""
      InstallerLog.record(level, "Started \(phase)\(title)")
      return level
    }

    private static func processCPUTime() -> UInt64? {
      var time = timespec()
      guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else { return nil }
      return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    private static func finish(
      _ phase: String, start: UInt64, cpuStart: UInt64?, bytes: UInt64?, completed: Bool,
      level: InstallerLogLevel
    ) {
      let end = InstallerTimingRecorder.now()
      let wall = end - min(start, end)
      let seconds = Double(wall) / 1_000_000_000
      var metrics = "phase=\(phase) wall_ns=\(wall) completed=\(completed)"
      // Concurrent and nested spans can include the same CPU work.
      if let cpuStart, let cpuEnd = processCPUTime(), cpuEnd >= cpuStart {
        metrics += " process_cpu_ns=\(cpuEnd - cpuStart)"
      }
      if let bytes { metrics += " expected_bytes=\(bytes)" }
      InstallerLog.record(.debug, source: "performance", metrics)
      logger.notice("phase=\(phase, privacy: .public) seconds=\(seconds) completed=\(completed)")
      InstallerTimingRecorder.current?.step(phase, start: start, end: end, completed: completed)
      let elapsed = InstallerLog.duration(nanoseconds: end - min(start, end))
      if completed {
        InstallerLog.record(level, "Finished \(phase) in \(elapsed)")
      } else {
        InstallerLog.record(.error, "Stopped \(phase) after \(elapsed)")
      }
    }
  }

  /// Plain titles for the steps a person most often reads in the log.
  public enum InstallerStepTitles {
    public static func title(for step: String) -> String? {
      switch step {
      case "credential_validation": "checking the macOS account"
      case "helper_import": "importing the approved plan"
      case "app_handoff": "packaging the approved plan for the helper"
      case "recovery_template": "preparing the Recovery template"
      case "restore_helper_check": "checking the restore helper"
      case "source_owner": "checking the macOS volume owner"
      case "payload_preflight": "checking the installation images"
      case "firmware_preparation": "preparing firmware"
      case "peripheral_inputs": "preparing peripheral firmware"
      case "apfs_preflight": "preflight: APFS container"
      case "stub_files_preflight": "preflight: stub files"
      case "os_partitions_preflight": "preflight: OS partitions"
      case "payload_images_preflight": "preflight: payload images"
      case "esp_files_preflight": "preflight: ESP files"
      case "finishing_preflight": "preflight: finishing"
      case "staging_space": "checking free space on macOS"
      case "apfs_preparation": "changing the disk: APFS container"
      case "stub_files": "changing the disk: stub files"
      case "os_partitions": "changing the disk: OS partitions"
      case "payload_images": "changing the disk: payload images"
      case "esp_files": "changing the disk: ESP files"
      case "finishing": "publishing firmware and Recovery"
      case "recovery_handoff": "preparing the Recovery handoff"
      case "preserved_reinstall": "reinstalling, keeping Stage 1"
      default: nil
      }
    }
  }
#endif
