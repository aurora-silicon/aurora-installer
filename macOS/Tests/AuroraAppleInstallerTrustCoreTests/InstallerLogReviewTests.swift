#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// Regressions found in review of the Installer Log.
  final class InstallerLogReviewTests: XCTestCase {
    func testANewerHelpersLogNeverStopsAnOlderAppReadingTheJob() throws {
      let (jobs, request) = try job()
      jobs.log(for: request.ticket.identifier).append(.progress, source: "helper", "a line")
      let snapshot = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0, logSequence: 0),
        initiatingUID: 501)
      var object =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
      var log = object["log"] as! [String: Any]
      var entries = log["entries"] as! [[String: Any]]
      entries[0]["level"] = 9
      log["entries"] = entries
      object["log"] = log
      let unknownLevel = try JSONDecoder().decode(
        InstallerJobSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(unknownLevel.log?.entries.first?.level, .debug)
      XCTAssertEqual(unknownLevel.identifier, snapshot.identifier)

      object["log"] = ["entries": "not a list"]
      let broken = try JSONDecoder().decode(
        InstallerJobSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertNil(broken.log)
      XCTAssertEqual(broken.identifier, snapshot.identifier)
      XCTAssertEqual(broken.phase, snapshot.phase)
    }

    func testSecretsInArgumentsAreRedactedBeforeQuoting() {
      let secret = "it's a secret"
      let line = InstallerLogRedactor.command(
        "/usr/bin/tool", ["--name", secret], secrets: [Data(secret.utf8)])
      XCTAssertFalse(line.contains("it"), line)
      XCTAssertFalse(line.contains("a secret"), line)
      XCTAssertEqual(line, "/usr/bin/tool --name [redacted]")
    }

    func testEveryPasswordLikeFlagWithholdsWhatFollows() {
      let cases: [(String, [String])] = [
        ("/usr/sbin/sysadminctl", ["-addUser", "bob", "-adminPassword", "x"]),
        ("/usr/bin/security", ["unlock-keychain", "-p", "x", "login.keychain"]),
        ("/usr/bin/dscl", [".", "-passwd", "/Users/bob", "x"]),
        ("/usr/bin/tool", ["--client-secret", "x"]),
        ("/usr/bin/tool", ["--auth-token", "x", "--verbose"]),
      ]
      for (executable, arguments) in cases {
        let line = InstallerLogRedactor.command(executable, arguments)
        XCTAssertFalse(line.split(separator: " ").contains("x"), line)
      }
      XCTAssertEqual(
        InstallerLogRedactor.command("/usr/sbin/bless", ["--user", "bob", "--stdinpass", "--x"]),
        "/usr/sbin/bless --user [redacted] --stdinpass --x")
    }

    func testHelperLinesLoseTheAppsSecrets() {
      let app = InstallerLogBuffer(capacity: 10)
      let password = "app-side secret"
      InstallerLog.$secrets.withValue([Data(password.utf8)]) {
        HelperLogReader(app).read(
          InstallerLogBatch(
            entries: [
              InstallerLogEntry(
                sequence: 1, time: Date(), level: .error, source: "bless",
                message: "echoed \(password)")
            ], missed: 0, cursor: 1))
      }
      XCTAssertEqual(app.snapshot().map(\.message), ["echoed [redacted]"])
    }

    func testAReplyWithAFullTranscriptStaysUnderTheAppsLimit() throws {
      let (jobs, request) = try job()
      let log = jobs.log(for: request.ticket.identifier)
      let line = String(repeating: "/", count: 2_000)
      for _ in 0..<600 { log.append(.debug, source: "diskutil", line) }
      jobs.finish(
        request.ticket.identifier,
        result: .success(
          (Data(count: Int(NativeInstallerExecutor.maximumTranscriptBytes)), .recorded)))
      let snapshot = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0, logSequence: 0),
        initiatingUID: 501)
      XCTAssertNotNil(snapshot.transcript)
      XCTAssertLessThanOrEqual(try JSONEncoder().encode(snapshot).count, 12 * 1_048_576)
    }

    func testMessagesAreCappedInBytes() {
      let buffer = InstallerLogBuffer(capacity: 10)
      buffer.append(.debug, source: "x", String(repeating: "🦊", count: 1_500))
      let message = buffer.snapshot()[0].message
      XCTAssertLessThanOrEqual(message.utf8.count, 2_000)
      XCTAssertEqual(message, String(repeating: "🦊", count: 500))
    }

    func testWatchingAJobAgainContinuesWhereTheLastWatchStopped() {
      let app = InstallerLogBuffer(capacity: 100)
      let helper = InstallerLogBuffer(capacity: 100)
      let job = UUID()
      helper.append(.progress, source: "helper", "first watch")
      let first = HelperLogReader.reader(for: job, into: app)
      first.read(helper.entries(after: first.cursor, ring: first.ring))
      // A Recovery retry, or a watch begun at launch, makes a new watch.
      helper.append(.progress, source: "helper", "second watch")
      let second = HelperLogReader.reader(for: job, into: app)
      XCTAssertTrue(second === first)
      second.read(helper.entries(after: second.cursor, ring: second.ring))
      XCTAssertEqual(app.snapshot().map(\.message), ["first watch", "second watch"])
      XCTAssertFalse(HelperLogReader.reader(for: UUID(), into: app) === first)
    }

    func testAReaderOfAnEarlierRingReadsANewOneFromItsStart() {
      let earlier = InstallerLogBuffer(capacity: 100)
      for index in 0..<5 { earlier.append(.debug, source: "x", "\(index)") }
      let restarted = InstallerLogBuffer(capacity: 100)
      for index in 0..<8 { restarted.append(.debug, source: "x", "after \(index)") }
      let batch = restarted.entries(after: 3, ring: earlier.identity)
      XCTAssertEqual(batch.entries.first?.message, "after 0")
      XCTAssertEqual(batch.ring, restarted.identity)
      XCTAssertEqual(restarted.entries(after: 3, ring: restarted.identity).entries.count, 5)
    }

    func testTheLastLinesArriveAndTheJobsCommandsEndWithIt() async throws {
      let app = InstallerLogBuffer(capacity: 2_000)
      let helper = InstallerLogBuffer(capacity: 2_000)
      helper.append(.debug, source: "diskutil", "Started #1", activity: "diskutil#1")
      for index in 0..<1_200 { helper.append(.debug, source: "helper", "line \(index)") }
      helper.append(.error, source: "helper", "Installation job failed")
      let reader = HelperLogReader(app)
      reader.read(helper.entries(after: 0))
      XCTAssertEqual(reader.cursor, UInt64(InstallerLogBatch.maximumEntries))
      try await reader.drain { helper.entries(after: reader.cursor, ring: reader.ring) }
      XCTAssertEqual(app.snapshot().last?.message, "Installation job failed")
      reader.finish()
      let last = try XCTUnwrap(app.snapshot().last)
      XCTAssertEqual(last.activity, "helper/diskutil#1")
      XCTAssertTrue(last.closesActivity)
    }

    func testPollingComesBackSoonWhileTheLogHasMore() async throws {
      let (jobs, request) = try job()
      for index in 0..<600 {
        jobs.log(for: request.ticket.identifier).append(.debug, source: "x", "\(index)")
      }
      let snapshot = try jobs.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0, logSequence: 0),
        initiatingUID: 501)
      XCTAssertEqual(snapshot.log?.more, true)
      let sleeps = Locked<[Duration]>([])
      let calls = Locked(0)
      _ = try? await InstallerJobObservation.wait(
        fetch: { _ in
          calls.mutate { $0 += 1 }
          guard calls.value == 1 else { throw InstallerJobError.invalidRequest }
          return snapshot
        }, sleep: { duration in sleeps.mutate { $0.append(duration) } })
      XCTAssertEqual(sleeps.value, [.milliseconds(100)])
    }

    func testAFailureLineIsLoggedInsideTheRedactingScope() async throws {
      struct Refused: Error, CustomStringConvertible {
        let description: String
      }
      let buffer = InstallerLogBuffer(capacity: 10)
      let authorization = try MachineOwnerAuthorization(
        username: "owner", password: Data("scope secret".utf8))
      await InstallerLog.$taskBuffer.withValue(buffer) {
        let failure: (any Error) -> String? = { "The service said: \($0)" }
        _ = try? await InstallerLog.redacting(authorization, failure: failure) {
          () async throws -> Void in
          throw Refused(description: "bad password scope secret")
        }
      }
      XCTAssertEqual(
        buffer.snapshot().map(\.message), ["The service said: bad password [redacted]"])
    }

    #if DEBUG
      func testHelperLinesAreCleanedBeforeTheBufferIsLocked() {
        let app = InstallerLogBuffer(capacity: 10)
        let locked = Locked<[Bool]>([])
        InstallerLogRedactor.willRedact = { locked.mutate { $0.append(app.isLocked) } }
        defer { InstallerLogRedactor.willRedact = nil }
        app.ingest(
          [InstallerLogEntry(sequence: 1, time: Date(), level: .debug, source: "x", message: "y")],
          sourcePrefix: "helper")
        XCTAssertEqual(locked.value, [false])
      }
    #endif

    private func job() throws -> (InstallerJobRegistry, InstallerJobStartRequest) {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = InstallerJobStartRequest(
        ticket: try InstallerJobTicket(
          bindingDigest: "sha256:" + String(repeating: "a", count: 64),
          selection: AuroraInstallationSelection(distribution: .fedora, desktop: .gnome)),
        operation: "install",
        installConf: try InstallConf(encrypt: true, lane: "stable").serializedData)
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      return (jobs, request)
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
