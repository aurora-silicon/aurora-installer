#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  @MainActor
  final class ReadOnlyMacCommandRunnerTests: XCTestCase {
    private func process(_ tool: String, _ arguments: [String]) -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      return process
    }

    func testLargeStderrIsDrainedBeforeTheChildWritesStdout() throws {
      let child = process("/bin/sh", ["-c", "head -c 262144 /dev/zero >&2; printf done"])
      let result = try FoundationReadOnlyMacCommandRunner.collect(
        process: child, auditName: "pipe-fixture", timeout: .seconds(5))
      XCTAssertEqual(result, Data("done".utf8))
    }

    func testOutputBudgetAndFailedExitNeverBecomeAnInspectionResponse() throws {
      let oversized = process("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=9"])
      XCTAssertThrowsError(
        try FoundationReadOnlyMacCommandRunner.collect(
          process: oversized, auditName: "output-budget", timeout: .seconds(10))
      ) {
        XCTAssertEqual(
          $0 as? AppleSiliconHostInspectionError, .invalidCommandResponse("output-budget"))
      }
      let failed = process("/bin/sh", ["-c", "printf partial; exit 3"])
      XCTAssertThrowsError(
        try FoundationReadOnlyMacCommandRunner.collect(process: failed, auditName: "exit-fixture")
      ) {
        XCTAssertEqual($0 as? AppleSiliconHostInspectionError, .commandFailed("exit-fixture", 3))
      }
    }

    func testTimeoutTerminatesTheOwnedReadOnlyProcess() {
      let child = process("/bin/sleep", ["10"])
      XCTAssertThrowsError(
        try FoundationReadOnlyMacCommandRunner.collect(
          process: child, auditName: "timeout-fixture", timeout: .milliseconds(100))
      ) {
        XCTAssertEqual($0 as? AppleSiliconHostInspectionError, .commandTimedOut("timeout-fixture"))
      }
      XCTAssertFalse(child.isRunning)
    }

    func testCancellationReachesARunningReadOnlyProcess() async {
      let started = DispatchSemaphore(value: 0)
      let worker = Task.detached {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        return try FoundationReadOnlyMacCommandRunner.collect(
          process: child, auditName: "cancel-fixture", timeout: .seconds(5),
          onStarted: { started.signal() })
      }
      XCTAssertEqual(started.wait(timeout: .now() + .seconds(3)), .success)
      worker.cancel()
      do {
        _ = try await worker.value
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAlreadyCancelledInspectionDoesNotLaunchAChild() async {
      let started = DispatchSemaphore(value: 0)
      let worker = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/false")
        return try FoundationReadOnlyMacCommandRunner.collect(
          process: child, auditName: "pre-cancel-fixture", onStarted: { started.signal() })
      }
      do {
        _ = try await worker.value
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertEqual(started.wait(timeout: .now()), .timedOut)
    }
  }
#endif
