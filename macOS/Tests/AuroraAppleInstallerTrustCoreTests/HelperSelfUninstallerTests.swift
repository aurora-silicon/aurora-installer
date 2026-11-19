#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class HelperSelfUninstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: root)
    }

    func testRemovesRegistrationButPreservesRecoveryState() throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder).uninstallNow()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binary.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testAHelperWhoseBinaryLivesElsewhereStillUnloads() throws {
      let paths = try makeInstalledHelper()
      try FileManager.default.removeItem(at: paths.binary)
      let recorder = Recorder()

      uninstaller(paths, recorder).uninstallNow()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testUninstallingAfterRemovalWaitsForTheReplyToBeDelivered() async throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()
      let delivery = HelperReplyDelivery()

      uninstaller(paths, recorder, deadline: .seconds(30))
        .uninstallAfterRemoval(delivered: delivery)
      XCTAssertEqual(recorder.events, [], "unloading waits for the app's receipt")
      XCTAssertTrue(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: paths.binary.path))

      delivery.fire()
      try await recorder.waitForEvents(2)
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: paths.state.path))
    }

    func testADeliveryThatAlreadyHappenedRetiresAtOnce() async throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder, deadline: .seconds(30))
        .uninstallAfterRemoval(delivered: .immediate)

      try await recorder.waitForEvents(2)
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testAnAppThatNeverClosesItsConnectionStillRetiresTheHelper() async throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()
      let delivery = HelperReplyDelivery()

      uninstaller(paths, recorder, deadline: .milliseconds(50))
        .uninstallAfterRemoval(delivered: delivery)

      try await recorder.waitForEvents(2)
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
      XCTAssertTrue(delivery.hasFired)
    }

    func testWaitingOnADeliveryEndsWhenTheWaiterIsCancelled() async {
      let delivery = HelperReplyDelivery()
      let waiter = Task { await delivery.wait() }
      waiter.cancel()
      await waiter.value
      XCTAssertFalse(delivery.hasFired)
    }

    // MARK: Fixtures

    private struct Paths {
      let jobFile: URL
      let binary: URL
      let state: URL
    }

    private final class Recorder: @unchecked Sendable {
      private let lock = NSLock()
      private var recorded: [String] = []
      private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
      var events: [String] { lock.withLock { recorded } }

      func record(_ event: String) {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
          recorded.append(event)
          guard let waiter, recorded.count >= waiter.count else { return nil }
          self.waiter = nil
          return waiter.continuation
        }
        resume?.resume()
      }

      /// Returns once `count` events are recorded; fails the test after 10 s.
      func waitForEvents(_ count: Int) async throws {
        let timeout = Task {
          try await Task.sleep(for: .seconds(10))
          XCTFail("expected \(count) events, got \(events)")
          for _ in 0..<count { record("timeout") }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let ready = lock.withLock {
            if recorded.count >= count { return true }
            waiter = (count, continuation)
            return false
          }
          if ready { continuation.resume() }
        }
        timeout.cancel()
      }
    }

    private func makeInstalledHelper() throws -> Paths {
      let paths = Paths(
        jobFile: root.appendingPathComponent("LaunchDaemons/probe.helper.plist"),
        binary: root.appendingPathComponent("PrivilegedHelperTools/probe.helper"),
        state: root.appendingPathComponent("db/probe.app", isDirectory: true))
      for file in [paths.jobFile, paths.binary] {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
      }
      let retired = paths.state.appendingPathComponent("retired-execution-journals/t")
      try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: retired.appendingPathComponent("abc.jsonl"))
      return paths
    }

    private func uninstaller(
      _ paths: Paths, _ recorder: Recorder, deadline: Duration = .seconds(30)
    ) -> LaunchdHelperSelfUninstaller {
      LaunchdHelperSelfUninstaller(
        label: "probe.helper", jobFile: paths.jobFile, binary: paths.binary,
        deliveryDeadline: deadline,
        unload: { recorder.record("unload:\($0)") },
        exitProcess: { recorder.record("exit") })
    }
  }
#endif
