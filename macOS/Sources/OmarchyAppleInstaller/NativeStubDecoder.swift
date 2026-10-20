#if os(macOS)
  import Darwin
  import Foundation

  enum NativeStubDecoder {
    static func run(executable: URL, input: URL, digest: String, output: URL, lease: FileHandle)
      throws
    {
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
        var space = statfs()
        let lowSpace = statfs(output.deletingLastPathComponent().path, &space) != 0
          || UInt64(space.f_bavail) * UInt64(space.f_bsize) < (10 << 30)
        if cancelled || lowSpace || DispatchTime.now() >= deadline {
          if process.isRunning { process.terminate() }
          if exited.wait(timeout: .now() + .seconds(5)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .seconds(2))
          }
          if cancelled { throw CancellationError() }
          if lowSpace { throw NativeStubFileError.insufficientSpace }
          throw NativeStubFileError.invalidImage
        }
      }
      try Task.checkCancellation()
      _ = errors.finish()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NativeStubFileError.invalidImage
      }
    }

    /// The decoder's own native children hold workspace leases. Refuse stale
    /// output cleanup while any of those children still uses that workspace.
    static func requireInactiveWorkspaces(_ directory: URL, owner: uid_t) throws {
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".omarchy-restore-") {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == owner, info.st_mode & 0o077 == 0
        else { throw NativeStubFileError.unsafeFile }
        let descriptor = open(url.appendingPathComponent(".lease").path,
          O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NativeRecoveryJournalError.busy }
        defer { close(descriptor) }
        var lease = stat()
        guard fstat(descriptor, &lease) == 0, lease.st_mode & S_IFMT == S_IFREG,
          lease.st_uid == owner, lease.st_mode & 0o077 == 0, lease.st_nlink == 1
        else { throw NativeStubFileError.unsafeFile }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NativeRecoveryJournalError.busy }
      }
    }
  }
#endif
