#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

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

    func testRemovesJobFileBinaryAndAllStateThenUnloadsAndExits() throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder).uninstallNow()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binary.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testAHelperWhoseBinaryLivesElsewhereStillUnloads() throws {
      let paths = try makeInstalledHelper()
      try FileManager.default.removeItem(at: paths.binary)
      let recorder = Recorder()

      uninstaller(paths, recorder).uninstallNow()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
    }

    func testUninstallingAfterRemovalWaitsThenRunsInTheBackground() async throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder, delay: .milliseconds(50)).uninstallAfterRemoval()
      XCTAssertEqual(recorder.events, [], "unloading waits")

      for _ in 0..<200 where recorder.events.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(recorder.events, ["unload:probe.helper", "exit"])
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
    }

    func testFilesGoAtOnceSoNoStaleHelperIsSeenWhileUnloadWaits() throws {
      let paths = try makeInstalledHelper()
      let recorder = Recorder()

      uninstaller(paths, recorder, delay: .seconds(30)).uninstallAfterRemoval()

      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.jobFile.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binary.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
      XCTAssertEqual(recorder.events, [], "unloading waits for the reply to reach the app")
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
      var events: [String] { lock.withLock { recorded } }
      func record(_ event: String) { lock.withLock { recorded.append(event) } }
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
      _ paths: Paths, _ recorder: Recorder, delay: Duration = .zero
    ) -> LaunchdHelperSelfUninstaller {
      LaunchdHelperSelfUninstaller(
        label: "probe.helper", jobFile: paths.jobFile, binary: paths.binary,
        workingDirectory: paths.state, delay: delay,
        unload: { recorder.record("unload:\($0)") },
        exitProcess: { recorder.record("exit") })
    }
  }
#endif
