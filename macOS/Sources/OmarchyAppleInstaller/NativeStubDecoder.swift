#if os(macOS)
  import Darwin
  import Foundation

  enum NativeStubDecoder {
    static func run(executable: URL, input: URL, digest: String, output: URL, lease: FileHandle) throws {
      try Task.checkCancellation()
      let process = Process()
      process.executableURL = executable
      process.arguments = [input.path, digest, output.path]
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
      process.standardInput = lease
      process.standardOutput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardError = pipe
      let errors = BoundedStandardErrorCollector(limit: 16384)
      try errors.start(reading: pipe.fileHandleForReading)
      defer { errors.cancel() }
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      try process.run()
      let deadline = DispatchTime.now() + .seconds(1800)
      while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
        let cancelled = Task.isCancelled
        if cancelled || DispatchTime.now() >= deadline {
          if process.isRunning { process.terminate() }
          if exited.wait(timeout: .now() + .seconds(5)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .seconds(2))
          }
          if cancelled { throw CancellationError() }
          throw NativeStubFileError.invalidImage
        }
      }
      try Task.checkCancellation()
      _ = errors.finish()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NativeStubFileError.invalidImage
      }
    }
  }
#endif
