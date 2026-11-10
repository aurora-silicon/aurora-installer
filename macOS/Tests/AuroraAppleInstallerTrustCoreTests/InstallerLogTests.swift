#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class InstallerLogTests: XCTestCase {
    private let password = "correct horse 7!"

    // MARK: Buffer

    func testRingKeepsTheNewestLinesAndCountsWhatItDropped() {
      let buffer = InstallerLogBuffer(capacity: 3)
      for index in 1...5 { buffer.append(.progress, source: "test", "line \(index)") }
      XCTAssertEqual(buffer.snapshot().map(\.message), ["line 3", "line 4", "line 5"])
      XCTAssertEqual(buffer.snapshot().map(\.sequence), [3, 4, 5])
      XCTAssertEqual(buffer.dropped, 2)
      XCTAssertEqual(buffer.lastSequence, 5)

      let behind = buffer.entries(after: 0)
      XCTAssertEqual(behind.missed, 2)
      XCTAssertEqual(behind.entries.map(\.sequence), [3, 4, 5])
      XCTAssertEqual(behind.cursor, 5)

      let caughtUp = buffer.entries(after: 5)
      XCTAssertTrue(caughtUp.entries.isEmpty)
      XCTAssertEqual(caughtUp.missed, 0)
      XCTAssertEqual(caughtUp.cursor, 5)

      let limited = buffer.entries(after: 3, limit: 1)
      XCTAssertEqual(limited.entries.map(\.sequence), [4])
      XCTAssertEqual(limited.cursor, 4)
    }

    func testACursorFromAnEarlierBufferReadsThisOneFromItsStart() {
      let buffer = InstallerLogBuffer(capacity: 10)
      buffer.append(.progress, source: "helper", "after a restart")
      let batch = buffer.entries(after: 900)
      XCTAssertEqual(batch.entries.map(\.message), ["after a restart"])
      XCTAssertEqual(batch.cursor, 1)
    }

    func testEachLineIsItsOwnEntryBoundedAndPrintable() {
      let buffer = InstallerLogBuffer(capacity: 10)
      let long = String(repeating: "x", count: InstallerLogBuffer.maximumMessageBytes + 50)
      buffer.append(.error, source: "tool\u{7}\n", "first\n\n\u{1B}[31msecond\u{0}\n" + long)
      let entries = buffer.snapshot()
      XCTAssertEqual(entries.map(\.message).prefix(2), ["first", "second"])
      XCTAssertEqual(entries.last?.message.count, InstallerLogBuffer.maximumMessageBytes)
      XCTAssertEqual(Set(entries.map(\.source)), ["tool"])
      XCTAssertTrue(entries.allSatisfy { $0.level == .error })
    }

    func testAppendHandsEachLineOnInOrder() {
      let seen = Locked<[UInt64]>([])
      let buffer = InstallerLogBuffer(capacity: 2) { entry in
        seen.mutate { $0.append(entry.sequence) }
      }
      for index in 1...4 { buffer.append(.debug, source: "test", "\(index)") }
      XCTAssertEqual(seen.value, [1, 2, 3, 4])
    }

    // MARK: Redaction

    func testSecretsNeverReachTheLogAtAnyLevel() async throws {
      let buffer = InstallerLogBuffer(capacity: 100)
      let secret = Data(password.utf8)
      await InstallerLog.logging(into: buffer, secrets: [secret]) {
        for level in InstallerLogLevel.allCases {
          InstallerLog.record(level, "tool said \(password) twice: \(password)")
        }
        InstallerLog.debug("password: \(password)")
        InstallerLog.debug("Authorization: Bearer abc.def-ghi")
        InstallerLog.debug("api_token=s3cr3t-value and more")
        InstallerLog.debug("b'raw bytes literal'")
        let process = InstallerProcessLog.begin(
          "/usr/sbin/bless",
          ["--setBoot", "--user", "owner", "--stdinpass", "--password=\(password)", "x"])
        process?.end(
          status: 3, standardError: Data("bad password \(password)\nsecond line\n".utf8))
      }
      let text = buffer.snapshot().map(\.message).joined(separator: "\n")
      XCTAssertFalse(text.contains(password))
      XCTAssertFalse(text.contains("abc.def-ghi"))
      XCTAssertFalse(text.contains("s3cr3t-value"))
      XCTAssertFalse(text.contains("raw bytes literal"))
      XCTAssertFalse(text.contains("--user owner"))
      // As in the helper's diagnostics, a credential-named key withholds the
      // rest of its line.
      XCTAssertTrue(text.contains("--user [redacted] --stdinpass --password= [redacted]"))
      XCTAssertTrue(text.contains("stderr: second line"))
      XCTAssertEqual(buffer.snapshot().filter { $0.level == .debug }.count, 6)
    }

    func testCommandLinesWithholdAccountAndCredentialValues() {
      XCTAssertEqual(
        InstallerLogRedactor.command(
          "/usr/sbin/diskutil",
          [
            "apfs", "unlockVolume", "disk3s5", "-user", "ABCD", "-passphrase", "pw",
            "-stdinpassphrase",
          ]),
        "/usr/sbin/diskutil apfs unlockVolume disk3s5 -user [redacted] -passphrase [redacted]"
      )
      XCTAssertEqual(
        InstallerLogRedactor.command("/bin/tool", ["a b", "SECRET_KEY=v", "--token", "t", "tail"]),
        "/bin/tool 'a b' SECRET_KEY= [redacted]")
      XCTAssertEqual(
        InstallerLogRedactor.command("/bin/tool", ["value"], secrets: [Data("value".utf8)]),
        "/bin/tool [redacted]")
    }

    func testURLsKeepOnlyTheirHostAndPath() {
      XCTAssertEqual(
        InstallerLogRedactor.line(
          "fetch https://user:pa/ss@cdn.example.com/a/b.img?X-Amz-Signature=abc#frag failed"),
        "fetch https://cdn.example.com/a/b.img?[redacted] failed")
      XCTAssertEqual(
        InstallerLogRedactor.line(
          "https://wkms-public.apple.com/fcs-keys/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        "https://wkms-public.apple.com/fcs-keys/[redacted]")
    }

    func testHomeFoldersAreShortened() {
      XCTAssertEqual(
        InstallerLogRedactor.homePaths(
          in: "/Users/mina/Library/Logs and /Users/mina and /Users/other/x and /Users/Shared/y",
          home: "/Users/mina"),
        "~/Library/Logs and ~ and /Users/[user]/x and /Users/Shared/y")
    }

    func testSourcesKeepASafeShortName() {
      XCTAssertEqual(InstallerLogRedactor.source("helper/diskutil#12"), "helper/diskutil#12")
      XCTAssertEqual(InstallerLogRedactor.source("\u{1B}[0m"), "0m")
      XCTAssertEqual(InstallerLogRedactor.source(""), "unknown")
      XCTAssertEqual(InstallerLogRedactor.source(String(repeating: "a", count: 99)).count, 48)
    }

    // MARK: Recorders

    func testProcessLinesNameTheCommandStatusAndStandardErrorTail() async {
      let buffer = InstallerLogBuffer(capacity: 100)
      await InstallerLog.logging(into: buffer) {
        let ok = InstallerProcessLog.begin("/usr/sbin/diskutil", ["list", "-plist"])
        ok?.end(status: 0, standardError: Data("ignored\n".utf8))
        let failed = InstallerProcessLog.begin("/usr/sbin/diskutil", ["apfs", "resizeContainer"])
        failed?.end(
          status: 1, standardError: Data("one\ntwo\nthree\nfour\n".utf8), truncated: false)
        let probe = InstallerProcessLog.begin("/bin/launchctl", ["print", "system/x"])
        probe?.end(status: 113, failureLevel: .debug)
        InstallerProcessLog.begin("/bin/sleep", ["5"])?.failed("Stopped: no answer")
      }
      let entries = buffer.snapshot()
      XCTAssertTrue(entries[0].message.hasPrefix("Started #"))
      XCTAssertEqual(entries[0].source, "diskutil")
      XCTAssertEqual(entries[0].level, .debug)
      XCTAssertNotNil(entries[0].activity)
      XCTAssertEqual(entries[1].activity, entries[0].activity)
      XCTAssertTrue(entries[1].closesActivity)
      XCTAssertTrue(entries[1].message.hasPrefix("Exited 0 after "))
      let errors = entries.filter { $0.level == .error }.map(\.message)
      XCTAssertTrue(errors[0].contains("Exited with status 1 after"))
      XCTAssertTrue(errors[0].hasSuffix("/usr/sbin/diskutil apfs resizeContainer"))
      XCTAssertEqual(Array(errors[1...3]), ["stderr: two", "stderr: three", "stderr: four"])
      XCTAssertTrue(errors[4].hasPrefix("Stopped: no answer after "))
      XCTAssertFalse(entries.contains { $0.message.contains("ignored") })
      XCTAssertTrue(
        entries.contains { $0.level == .debug && $0.message.contains("Exited with status 113") })
    }

    func testNothingIsRecordedWithoutALog() {
      XCTAssertNil(InstallerLog.taskBuffer)
      XCTAssertNil(InstallerProcessLog.begin("/usr/bin/true", []))
    }

    func testStepsAreProgressOutermostAndDebugInsideAndErrorWhenStopped() async {
      struct Refusal: Error {}
      let buffer = InstallerLogBuffer(capacity: 100)
      await InstallerLog.logging(into: buffer) {
        InstallerPerformance.measure("apfs_preflight") {
          InstallerPerformance.measure("apfs_collect") {}
        }
        _ = try? await InstallerPerformance.measuring("stub_files") { () async throws -> Void in
          throw Refusal()
        }
      }
      let lines = buffer.snapshot().map { "\($0.level.label) \($0.message)" }
      XCTAssertEqual(lines[0], "info Started apfs_preflight (preflight: APFS container)")
      XCTAssertEqual(lines[1], "debug Started apfs_collect")
      XCTAssertTrue(lines[2].hasPrefix("debug Finished apfs_collect in "))
      XCTAssertTrue(lines[3].hasPrefix("info Finished apfs_preflight in "))
      XCTAssertEqual(lines[4], "info Started stub_files (changing the disk: stub files)")
      XCTAssertTrue(lines[5].hasPrefix("error Stopped stub_files after "))
    }

    func testDownloadLinesShowHostSizeRateAndVerification() throws {
      let buffer = InstallerLogBuffer(capacity: 100)
      let artifact = try PinnedInstallerArtifact(
        role: "payload",
        sourceURL: URL(string: "https://cdn.example.com/releases/aurora.img.zst")!,
        fileName: "aurora.img.zst",
        expectedDigest: "sha256:" + String(repeating: "ab", count: 32),
        expectedSizeBytes: 1_000)
      try InstallerLog.$taskBuffer.withValue(buffer) {
        let log = try XCTUnwrap(InstallerDownloadLog.begin(artifact))
        log.downloading(
          from: artifact.sourceURL.appending(queryItems: [.init(name: "t", value: "x")]))
        let handler = log.observing(nil)
        for bytes in stride(from: 0, through: 1_000, by: 50) {
          handler(
            ArtifactStagingProgress(
              role: "payload", fileName: artifact.fileName, phase: .downloading,
              bytesCompleted: UInt64(bytes), totalBytes: 1_000))
        }
        log.verified()
        log.failed(URLError(.timedOut))
      }
      let entries = buffer.snapshot()
      XCTAssertEqual(
        entries.first?.message, "Downloading aurora.img.zst (1 KB) from cdn.example.com")
      let tenths = entries.filter {
        $0.message.hasPrefix("aurora.img.zst: ") && $0.level == .progress
      }
      XCTAssertEqual(tenths.count, 9)
      XCTAssertTrue(
        entries.last?.message.hasPrefix("Verified aurora.img.zst: size and SHA-256") == true)
      XCTAssertTrue(entries.last?.message.contains("sha256:abababababab…abab") == true)
      XCTAssertTrue(entries.last?.closesActivity == true)
      XCTAssertFalse(
        entries.contains { $0.message.contains("failed") }, "only the first end counts")
      XCTAssertFalse(entries.contains { $0.message.contains("t=x") })
    }

    func testFirmwareTransfersReachTheJobLog() async {
      let buffer = InstallerLogBuffer(capacity: 10)
      await InstallerLog.logging(into: buffer) {
        FirmwareTransferLog.observer?(
          .progress, "Range of updates.cdn-apple.com/x.ipsw interrupted")
      }
      XCTAssertEqual(buffer.snapshot().map(\.source), ["firmware"])
    }

    // MARK: Helper to app

    func testHelperLinesArriveUnderTheHelperNameAndCleanedAgain() {
      let app = InstallerLogBuffer(capacity: 10)
      let sent = [
        InstallerLogEntry(
          sequence: 7, time: Date(timeIntervalSince1970: 1), level: .error, source: "diskutil",
          message: "bad\u{1B}[2J line", activity: "diskutil#3", closesActivity: true),
        InstallerLogEntry(
          sequence: 8, time: Date(timeIntervalSince1970: 2), level: .progress, source: "helper",
          message: "Finished x"),
      ]
      let reader = HelperLogReader(app)
      reader.read(InstallerLogBatch(entries: sent, missed: 4, cursor: 8))
      XCTAssertEqual(reader.cursor, 8)
      let entries = app.snapshot()
      XCTAssertEqual(entries.map(\.source), ["Installer", "helper/diskutil", "helper"])
      XCTAssertEqual(
        entries[0].message, "4 helper log lines were dropped before they could be read")
      XCTAssertEqual(entries[1].message, "bad line")
      XCTAssertEqual(entries[1].activity, "helper/diskutil#3")
      XCTAssertEqual(entries[1].time, Date(timeIntervalSince1970: 1))
    }

    func testAJobReportsItsLogOnlyWhenAskedAndOlderPeersStillDecode() throws {
      let root = try workspace()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      jobs.log(for: request.ticket.identifier).append(.debug, source: "diskutil", "Started #1")
      let notice = EngineFailureNotice(
        reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: true,
        summary: "approved extent changed")
      jobs.finish(
        request.ticket.identifier,
        result: .failure(
          NativeInstallerExecutionError.engineFailed(
            EngineFailureReport(notice: notice, redactedStandardErrorTail: "root-only tail"))))

      let without = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertNil(without.log)
      let with = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0, logSequence: 0),
        initiatingUID: 501)
      let messages = try XCTUnwrap(with.log).entries.map(\.message)
      XCTAssertTrue(messages[0].hasPrefix("Accepted installation job "))
      XCTAssertEqual(messages[1], "Started #1")
      XCTAssertTrue(
        messages[2].hasSuffix(
          "failed (engine, reason approvedSpaceChanged, exit 1, disk unchanged): approved extent changed"
        ))
      XCTAssertFalse(messages.joined().contains("root-only tail"))
      let later = try jobs.status(
        InstallerJobStatusRequest(
          ticket: request.ticket, journalOffset: 0, logSequence: with.log?.cursor),
        initiatingUID: 501)
      XCTAssertEqual(later.log?.entries.count, 0)

      // An older helper's snapshot has no log; an older app's request has no cursor.
      var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as! [String: Any]
      old.removeValue(forKey: "log")
      let decoded = try JSONDecoder().decode(
        InstallerJobSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
      XCTAssertNil(decoded.log)
      let oldRequest = try JSONEncoder().encode(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 3))
      XCTAssertFalse(String(decoding: oldRequest, as: UTF8.self).contains("logSequence"))
      XCTAssertNil(
        try JSONDecoder().decode(InstallerJobStatusRequest.self, from: oldRequest).logSequence)
    }

    func testOnlyRecentJobLogsAreKept() throws {
      let jobs = InstallerJobRegistry(workingDirectory: try workspace(), work: HelperWorkState())
      let first = UUID()
      let kept = jobs.log(for: first)
      XCTAssertTrue(jobs.log(for: first) === kept)
      for _ in 0..<InstallerJobRegistry.retainedLogs { _ = jobs.log(for: UUID()) }
      XCTAssertFalse(jobs.log(for: first) === kept)
    }

    // MARK: Fixtures

    private func workspace() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      addTeardownBlock { try? FileManager.default.removeItem(at: url) }
      return url
    }

    private func request() throws -> InstallerJobStartRequest {
      InstallerJobStartRequest(
        ticket: try InstallerJobTicket(
          bindingDigest: "sha256:" + String(repeating: "a", count: 64),
          selection: AuroraInstallationSelection(distribution: .fedora, desktop: .gnome)),
        operation: "install",
        installConf: try InstallConf(encrypt: true, lane: "stable").serializedData)
    }
  }

  private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
  }
#endif
