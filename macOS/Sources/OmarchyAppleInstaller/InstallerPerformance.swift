#if os(macOS)
  import Foundation
  import OSLog

  /// Logs each measured step and adds it to the current attempt's timing.
  enum InstallerPerformance {
    private static let logger = Logger(subsystem: "com.omarchy.installer", category: "performance")

    @discardableResult
    static func measure<T>(_ phase: String, _ action: () throws -> T) rethrows -> T {
      InstallerTimingRecorder.current?.begin(phase)
      let start = InstallerTimingRecorder.now()
      var completed = false
      defer { finish(phase, start: start, completed: completed) }
      let result = try action()
      completed = true
      return result
    }

    @discardableResult
    static func measuring<T>(_ phase: String, _ action: () async throws -> T) async rethrows -> T {
      InstallerTimingRecorder.current?.begin(phase)
      let start = InstallerTimingRecorder.now()
      var completed = false
      defer { finish(phase, start: start, completed: completed) }
      let result = try await action()
      completed = true
      return result
    }

    private static func finish(_ phase: String, start: UInt64, completed: Bool) {
      let end = InstallerTimingRecorder.now()
      let seconds = Double(end - min(start, end)) / 1_000_000_000
      logger.notice("phase=\(phase, privacy: .public) seconds=\(seconds) completed=\(completed)")
      InstallerTimingRecorder.current?.step(phase, start: start, end: end, completed: completed)
    }
  }
#endif
