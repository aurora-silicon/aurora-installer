#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import Darwin
  import Foundation
  import XCTest

  @testable import AuroraInstallerUXCore

  @MainActor
  final class InstallerLogStoreTests: XCTestCase {
    private func entry(
      _ sequence: UInt64, _ level: InstallerLogLevel, _ source: String = "Installer",
      _ message: String = "line"
    ) -> InstallerLogEntry {
      InstallerLogEntry(
        sequence: sequence, time: Date(timeIntervalSince1970: 1_000 + Double(sequence)),
        level: level, source: source, message: message)
    }

    func testEachFilterShowsItsLevelAndTheOnesAboveIt() {
      let entries = [entry(1, .error), entry(2, .progress), entry(3, .debug)]
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .errorsOnly, search: "").map(\.sequence), [1])
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .errorsAndProgress, search: "").map(
          \.sequence), [1, 2])
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .all, search: "").map(\.sequence), [1, 2, 3])
      XCTAssertEqual(
        InstallerLogFilter.allCases.map(\.title),
        ["Errors only", "Errors and progress", "Everything"])
    }

    func testSearchMatchesMessageOrSourceIgnoringCase() {
      let entries = [
        entry(1, .debug, "helper/diskutil", "Started #1"),
        entry(2, .progress, "download", "Verified aurora.IMG"),
        entry(3, .error, "helper", "Stopped stub_files"),
      ]
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .all, search: "DISKUTIL").map(\.sequence), [1])
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .all, search: " img ").map(\.sequence), [2])
      XCTAssertEqual(
        InstallerLogFormat.visible(entries, filter: .errorsOnly, search: "started").map(
          \.sequence), [])
    }

    func testSavedLinesCarryDateLevelSourceAndMessage() {
      let line = InstallerLogFormat.fileLine(entry(1, .error, "helper/bless", "Exited 3"))
      XCTAssertTrue(
        line.range(
          of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}[+-]\d{4} error helper/bless: Exited 3$"#,
          options: .regularExpression) != nil, line)
      let document = InstallerLogFormat.document(
        [entry(1, .progress)], filter: .errorsAndProgress, search: "x")
      XCTAssertTrue(document.contains("Filter: Errors and progress, matching “x”"))
      XCTAssertTrue(document.hasSuffix(" info  Installer: line\n"))
    }

    func testStoreTracksRunningCommandsAndStaysBounded() {
      let store = InstallerLogStore(capacity: 4)
      store.buffer.append(.debug, source: "diskutil", "Started #1", activity: "diskutil#1")
      store.buffer.append(.progress, source: "download", "Downloading", activity: "download:a")
      store.refresh()
      XCTAssertEqual(store.running.map(\.activity), ["diskutil#1", "download:a"])
      store.buffer.append(
        .debug, source: "diskutil", "Exited 0", activity: "diskutil#1", closesActivity: true)
      for index in 0..<3 { store.buffer.append(.debug, source: "x", "\(index)") }
      store.refresh()
      XCTAssertEqual(store.running.map(\.activity), ["download:a"])
      XCTAssertEqual(store.entries.count, 4)
      XCTAssertEqual(store.entries.last?.message, "2")
    }

    func testStoreRefreshesOnTheMainQueueAfterALineFromAnyThread() async {
      let store = InstallerLogStore()
      await Task.detached { _ = store.buffer.append(.error, source: "helper", "from elsewhere") }
        .value
      for _ in 0..<100 where store.entries.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(store.entries.map(\.message), ["from elsewhere"])
    }

    func testPersistedLogKeepsEveryLevelPrivatelyAndAfterTheFact() throws {
      let directory = try temporaryDirectory()
      let store = InstallerLogStore()
      store.buffer.append(.debug, source: "diskutil", "before persisting")
      let file = InstallerLogFile(directory: directory.appendingPathComponent("Logs"))
      store.persist(to: file, header: "=== header ===")
      store.buffer.append(.error, source: "helper", "after persisting")
      file.flush()
      let text = try String(contentsOf: file.url, encoding: .utf8)
      let lines = text.split(separator: "\n").map(String.init)
      XCTAssertEqual(lines.first, "=== header ===")
      XCTAssertTrue(lines[1].hasSuffix(" debug diskutil: before persisting"))
      XCTAssertTrue(lines[2].hasSuffix(" error helper: after persisting"))
      var info = stat()
      XCTAssertEqual(stat(file.url.path, &info), 0)
      XCTAssertEqual(info.st_mode & 0o777, 0o600)
      XCTAssertEqual(stat(file.directory.path, &info), 0)
      XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testPersistedLogRotatesAndKeepsTwoOlderFiles() throws {
      let directory = try temporaryDirectory()
      let file = InstallerLogFile(directory: directory, maximumFileBytes: 300)
      for index in 0..<100 {
        file.append(line: "line \(index) " + String(repeating: "x", count: 40))
      }
      file.flush()
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      XCTAssertEqual(names, ["installer.1.log", "installer.2.log", "installer.log"])
      for name in names {
        let size =
          try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 300)
      }
      let newest = try String(
        contentsOf: directory.appendingPathComponent("installer.log"), encoding: .utf8)
      XCTAssertTrue(newest.contains("line 99 "))
    }

    func testPersistedLogNeverWritesThroughALink() throws {
      let directory = try temporaryDirectory()
      let elsewhere = directory.appendingPathComponent("elsewhere.txt")
      try Data().write(to: elsewhere)
      try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent(InstallerLogFile.fileName),
        withDestinationURL: elsewhere)
      let file = InstallerLogFile(directory: directory)
      file.append(line: "must not land")
      file.flush()
      XCTAssertEqual(try Data(contentsOf: elsewhere), Data())
    }

    func testPersistedLogDropsAndCountsLinesWhenTheDiskFallsBehind() throws {
      let directory = try temporaryDirectory()
      let file = InstallerLogFile(directory: directory)
      let huge = String(repeating: "y", count: InstallerLogFile.maximumPendingBytes / 2 + 1)
      file.pause()
      for _ in 0..<6 { file.append(line: huge) }
      file.resume()
      file.flush()
      let text = try String(contentsOf: file.url, encoding: .utf8)
      XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("yyy") }.count, 1)
      XCTAssertTrue(text.hasSuffix("5 log lines were not written: the disk fell behind\n"))
    }

    #if DEBUG
      func testSessionLogsEachPhaseAndTheRealCauseOfAFailure() async {
        let buffer = InstallerLogBuffer(capacity: 500)
        await InstallerLog.$taskBuffer.withValue(buffer) {
          let session = InstallerSession(
            environment: InstallerSimulationEnvironment(scenario: .spaceChanged, delay: .zero))
          await session.inspect()
          await session.continueToPlan()
          session.continueToPlanReview()
          session.setAcknowledged(true)
          session.approve()
          session.presentInstallCredentials()
          let authorization = try! MachineOwnerAuthorization(
            username: "owner", password: Data("simulated secret".utf8))
          await session.submit(authorization)
        }
        let entries = buffer.snapshot()
        let installer = entries.filter { $0.source == "Installer" }.map(\.message)
        XCTAssertTrue(installer.contains("Inspecting this Mac"))
        XCTAssertTrue(installer.contains { $0.hasPrefix("Ready to install: ") })
        XCTAssertTrue(installer.contains { $0.hasPrefix("Plan ready: ") })
        XCTAssertTrue(installer.contains { $0.hasPrefix("Installation started") })
        let errors = entries.filter { $0.level == .error }.map(\.message)
        XCTAssertTrue(errors.contains { $0.contains("approved extent changed") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.hasPrefix("Stopped apfs_preflight after ") })
        XCTAssertFalse(entries.contains { $0.message.contains("simulated secret") })
      }
    #endif

    func testDroppedLinesAreCountedWhenSeveralWritesAreQueued() throws {
      let directory = try temporaryDirectory()
      let file = InstallerLogFile(directory: directory)
      let half = String(repeating: "y", count: InstallerLogFile.maximumPendingBytes / 2 + 1)
      file.pause()
      file.append(line: half)
      file.append(line: half)  // dropped: it would pass the pending limit
      file.append(line: "small")  // queued behind the first
      file.resume()
      file.flush()
      let text = try String(contentsOf: file.url, encoding: .utf8)
      XCTAssertTrue(text.hasSuffix("small\n1 log lines were not written: the disk fell behind\n"))
    }

    func testTheStoreTrimsInBatchesNotALinePerRefresh() {
      let store = InstallerLogStore(capacity: 100)
      for index in 0..<100 { store.buffer.append(.debug, source: "x", "\(index)") }
      store.refresh()
      let first = store.entries.first?.sequence
      for index in 0..<20 {
        store.buffer.append(.debug, source: "x", "more \(index)")
        store.refresh()
        XCTAssertEqual(store.entries.first?.sequence, first, "no trim before the batch")
      }
      for index in 0..<10 { store.buffer.append(.debug, source: "x", "last \(index)") }
      store.refresh()
      XCTAssertEqual(store.entries.count, 100)
      XCTAssertEqual(store.entries.last?.message, "last 9")
    }

    func testThePersistedLogIsMadePrivateAndItsFolderMustNotBeALink() throws {
      let directory = try temporaryDirectory()
      let existing = directory.appendingPathComponent(InstallerLogFile.fileName)
      FileManager.default.createFile(
        atPath: existing.path, contents: Data(), attributes: [.posixPermissions: 0o644])
      let file = InstallerLogFile(directory: directory)
      file.append(line: "private")
      file.flush()
      var info = stat()
      XCTAssertEqual(stat(existing.path, &info), 0)
      XCTAssertEqual(info.st_mode & 0o777, 0o600)

      let elsewhere = try temporaryDirectory()
      let link = directory.appendingPathComponent("Linked")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
      let linked = InstallerLogFile(directory: link)
      linked.append(line: "must not land")
      linked.flush()
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    private func temporaryDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: url) }
      return url
    }
  }
#endif
