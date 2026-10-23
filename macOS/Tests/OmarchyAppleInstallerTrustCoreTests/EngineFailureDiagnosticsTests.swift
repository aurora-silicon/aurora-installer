#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class EngineFailureDiagnosticsTests: XCTestCase {
    private let password = Data("correct horse".utf8)

    func testExactPasswordBytesAreRemovedEverywhere() {
      let raw = Data("a correct horse b\ncorrect horsecorrect horse\n".utf8)
      let redacted = EngineStandardErrorRedactor.redact(
        raw, truncated: false, secrets: [password])
      XCTAssertFalse(redacted.contains("correct horse"))
      XCTAssertEqual(redacted.components(separatedBy: "[redacted]").count - 1, 3)
    }

    func testCredentialKeyValuesAndBytesLiteralsAreRedacted() {
      let raw = Data(
        """
        password=abc123 Token: xyz
        API_KEY = "k e y" and more
        secret:'s'
        Authorization: Bearer TOPSECRET1
        token="prefix\\"TOPSECRET2"
        curl -H 'Bearer abcdefgh12345678'
        ok=1
        value b'\\x00secret-bytes' and b"other"
        AsahiAdapterError: machine owner password is invalid

        """.utf8)
      let redacted = EngineStandardErrorRedactor.redact(raw, truncated: false, secrets: [])
      for leaked in [
        "abc123", "xyz", "k e y", "and more", "'s'", "secret-bytes", "other", "TOPSECRET",
        "abcdefgh12345678",
      ] {
        XCTAssertFalse(redacted.contains(leaked), leaked)
      }
      XCTAssertTrue(redacted.contains("ok=1"))
      // Plain messages that only mention a credential stay readable.
      XCTAssertTrue(redacted.contains("machine owner password is invalid"))
    }

    func testPasswordSplitByTerminalEscapesIsStillRemoved() {
      let raw = Data("x correct\u{1B}[0m horse y\n".utf8)
      let redacted = EngineStandardErrorRedactor.redact(
        raw, truncated: false, secrets: [password])
      XCTAssertEqual(redacted, "x [redacted] y\n")
    }

    func testCollectorGivesUpOnAStderrHeldOpenAndClosesItsDescriptor() throws {
      let pipe = Pipe()
      let collector = BoundedStandardErrorCollector()
      try collector.start(reading: pipe.fileHandleForReading)
      try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
      let started = Date()
      let result = collector.finish(timeout: .now() + 0.3)
      XCTAssertLessThan(Date().timeIntervalSince(started), 2)
      XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "partial")
      try pipe.fileHandleForWriting.close()
    }

    func testCollectorStopsAWriterThatNeverStops() throws {
      // A separate process, like a stray engine descendant, writes forever.
      let pipe = Pipe()
      let collector = BoundedStandardErrorCollector(limit: 1_024)
      try collector.start(reading: pipe.fileHandleForReading)
      let writer = Process()
      writer.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
      writer.standardOutput = pipe
      writer.standardError = FileHandle.nullDevice
      try writer.run()
      defer {
        if writer.isRunning { writer.terminate() }
        writer.waitUntilExit()
      }
      let started = Date()
      let result = collector.finish(timeout: .now() + 0.3)
      XCTAssertLessThan(Date().timeIntervalSince(started), 2)
      XCTAssertLessThanOrEqual(result.data.count, 1_024)
      XCTAssertTrue(result.truncated)
    }

    func testDetailIsRedactedAfterEscapeRemoval() {
      let secret = Data("alpha-S3cret!".utf8)
      let line = "stage failed: alpha-\u{202E}S3cret! and alpha-\u{E9}S3cret!"
      let tail = EngineStandardErrorRedactor.redact(
        Data(line.utf8), truncated: false, secrets: [secret])
      XCTAssertFalse(tail.contains("alpha-S3cret!"), tail)
      XCTAssertFalse(tail.contains("\u{202E}"))
    }

    func testShortAuthorizationTokensAreRedacted() {
      let redacted = EngineStandardErrorRedactor.redact(
        Data("curl Basic dTpw then bearer abc123 and basic eHl6\n".utf8), truncated: false,
        secrets: [])
      XCTAssertFalse(redacted.contains("dTpw"))
      XCTAssertFalse(redacted.contains("abc123"))
      XCTAssertFalse(redacted.contains("eHl6"))
    }

    func testTruncatedTailDropsItsPartialFirstLine() {
      // A cut through the middle of a password leaves only its suffix, which
      // the exact-bytes pass cannot recognize; the partial line must go.
      let raw = Data("rse leaked-suffix\nsecond line\n".utf8)
      let redacted = EngineStandardErrorRedactor.redact(
        raw, truncated: true, secrets: [password])
      XCTAssertEqual(redacted, "second line\n")
      XCTAssertEqual(
        EngineStandardErrorRedactor.redact(Data("no newline".utf8), truncated: true, secrets: []),
        "")
    }

    func testTerminalEscapesAndControlCharactersAreRemoved() {
      let raw = Data("\u{1B}[31mred\u{1B}[0m\u{07}bell\r\n".utf8)
      XCTAssertEqual(
        EngineStandardErrorRedactor.redact(raw, truncated: false, secrets: []), "redbell\n")
    }

    func testMacOSUpdateSummaryCarriesOnlyAPlainVersion() throws {
      let summary = try XCTUnwrap(EngineFailureReason.macOSUpdateSummary(version: "26.6.2"))
      XCTAssertEqual(summary, "This Mac needs macOS 26.6.2 or later.")
      // The summary survives the notice's sanitizing on both sides of XPC.
      let notice = EngineFailureNotice(
        reason: .macOSUpdateRequired, exitStatus: 1, diskUnchanged: true, summary: summary)
      XCTAssertEqual(EngineFailureReason.requiredMacOSVersion(inSummary: notice.summary), "26.6.2")
      for version in ["14.8.3", "26.6", "26"] {
        XCTAssertEqual(
          EngineFailureReason.macOSUpdateSummary(version: version).flatMap {
            EngineFailureReason.requiredMacOSVersion(inSummary: $0)
          }, version)
      }
      for version in ["", "26.6.2.1", "26..2", "26.6.2b", "1234.1", "26.6 or later", "２６.6"] {
        XCTAssertNil(EngineFailureReason.macOSUpdateSummary(version: version), version)
      }
      for summary in [
        "", "This Mac needs macOS  or later.", "This Mac needs macOS 26.6.2.",
        "This Mac needs macOS 26.6.2 or later", "This Mac needs macOS 26.6.2.1 or later.",
        "Compatible boot firmware could not be selected.",
        "x This Mac needs macOS 26.6.2 or later.",
      ] {
        XCTAssertNil(EngineFailureReason.requiredMacOSVersion(inSummary: summary), summary)
      }
    }

    func testSummaryIsOneBoundedPrintableLine() {
      let notice = EngineFailureNotice(
        reason: .unclassified, exitStatus: 1, diskUnchanged: false,
        summary: "a\u{1B}b\tc\u{202E}d\nsecond line" + String(repeating: "x", count: 500))
      XCTAssertEqual(notice.summary, "ab cd")
      let long = EngineFailureNotice(
        reason: .unclassified, exitStatus: 1, diskUnchanged: false,
        summary: String(repeating: "y", count: 500))
      XCTAssertEqual(long.summary.count, EngineFailureNotice.maximumSummaryCharacters)
    }

    func testCollectorKeepsOnlyTheTail() {
      let collector = BoundedStandardErrorCollector(limit: 8)
      collector.append(Data("0123456789".utf8))
      collector.append(Data("ab".utf8))
      let result = collector.finish(timeout: .now())
      XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "456789ab")
      XCTAssertTrue(result.truncated)
    }

    func testDiagnosticsStoreWritesPrivateReportsAndPrunes() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let report = EngineFailureReport(
        notice: EngineFailureNotice(
          reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: true,
          summary: "omarchy_execution.ExecutionAdmissionError: approved extent changed"),
        redactedStandardErrorTail: "tail line\n")

      var last: URL?
      for index in 0..<(EngineFailureDiagnosticsStore.maximumRetainedReports + 3) {
        last = EngineFailureDiagnosticsStore.write(
          report, operation: "install", in: root,
          now: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)))
      }
      let url = try XCTUnwrap(last)
      let directory = root.appendingPathComponent("diagnostics")
      XCTAssertEqual(try mode(of: directory), 0o700)
      XCTAssertEqual(try mode(of: url), 0o600)
      let body = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(body.contains("reason: approvedSpaceChanged"))
      XCTAssertTrue(body.contains("disk unchanged (journal has no mutation record): true"))
      XCTAssertTrue(body.contains("tail line"))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
        EngineFailureDiagnosticsStore.maximumRetainedReports)
    }

    func testDiagnosticsStoreRefusesAnOpenDirectory() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("diagnostics")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755])
      let report = EngineFailureReport(
        notice: EngineFailureNotice(
          reason: .unclassified, exitStatus: 1, diskUnchanged: false, summary: ""),
        redactedStandardErrorTail: "")
      XCTAssertNil(EngineFailureDiagnosticsStore.write(report, operation: "install", in: root))
    }

    func testUserLogHoldsOnlyTheNotice() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let directory = root.appendingPathComponent("Logs/\(InstallerProductIdentity.appName)")
      let url = try XCTUnwrap(
        EngineFailureUserLog.write(
          EngineFailureNotice(
            reason: .approvedSpaceChanged, exitStatus: 1, diskUnchanged: true,
            summary: "omarchy_execution.ExecutionAdmissionError: approved extent changed"),
          operation: "install", in: directory))
      XCTAssertEqual(try mode(of: url), 0o600)
      let body = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(body.contains("approved extent changed"))
      XCTAssertTrue(body.contains("/var/db/\(InstallerProductIdentity.appIdentifier)/diagnostics"))
    }

    private func temporaryDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-engine-diagnostics-\(UUID().uuidString.lowercased())", isDirectory: true)
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return url
    }

    private func mode(of url: URL) throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
  }
#endif
