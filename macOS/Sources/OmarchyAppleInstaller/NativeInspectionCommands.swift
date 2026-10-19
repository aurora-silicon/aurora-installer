#if os(macOS)
  import Darwin
  import Foundation

  enum NativeInspectionCommands {
    /// Fixed read-only disk verbs, plus temporary read-only volume access.
    /// Never accepts a peer-supplied tool or a partition-changing command.
    static func run(_ arguments: [String], cleanup: Bool = false) throws -> Data {
      guard permitted(arguments) else { throw NativeInspectionError.invalidLayout }
      if !cleanup { try Task.checkCancellation() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
      process.arguments = arguments
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
      process.standardInput = FileHandle.nullDevice
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      let output = BoundedStandardErrorCollector(limit: 8_388_608)
      let errors = BoundedStandardErrorCollector(limit: 16_384)
      try output.start(reading: outputPipe.fileHandleForReading)
      defer { output.cancel() }
      try errors.start(reading: errorPipe.fileHandleForReading)
      defer { errors.cancel() }
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      try process.run()
      let deadline = DispatchTime.now() + .seconds(cleanup ? 15 : 120)
      while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
        let cancelled = !cleanup && Task.isCancelled
        if cancelled || DispatchTime.now() >= deadline {
          if process.isRunning { process.terminate() }
          if exited.wait(timeout: .now() + .seconds(5)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .seconds(2))
          }
          if cancelled { throw CancellationError() }
          throw NativeInspectionError.queryTimedOut
        }
      }
      if !cleanup { try Task.checkCancellation() }
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NativeInspectionError.queryFailed
      }
      let result = output.finish()
      guard !result.truncated else { throw NativeInspectionError.invalidLayout }
      return result.data
    }

    static func identifier(_ value: String) -> Bool {
      guard
        let range = value.range(of: #"^disk[0-9]+(?:s[0-9]+){0,2}$"#, options: .regularExpression)
      else {
        return false
      }
      return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }

    static func permitted(_ a: [String]) -> Bool {
      if a == ["list", "-plist", "internal", "physical"]
        || a == ["apfs", "list", "-plist"] || a == ["apfs", "listVolumeGroups", "-plist"]
      {
        return true
      }
      if a.count == 3, a[0] == "info", a[1] == "-plist", a[2] == "/" || identifier(a[2]) {
        return true
      }
      if a.count == 5, a[0] == "apfs", a[1] == "resizeContainer",
        identifier(a[2]), a[3] == "limits", a[4] == "-plist"
      {
        return true
      }
      if a.count == 6, Array(a.prefix(4)) == ["mount", "readOnly", "nobrowse", "-mountPoint"],
        a[4].hasPrefix("/"), !a[4].utf8.contains(0), identifier(a[5])
      {
        return true
      }
      return a.count == 2 && a[0] == "unmount" && identifier(a[1])
    }
  }
#endif
