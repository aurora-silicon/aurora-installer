#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerTimingTests: XCTestCase {
    func testStepsAreKeptBesideTheJournalOnceItsDirectoryExists() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      let journal = journals.appendingPathComponent(String(repeating: "a", count: 64) + ".jsonl")
      let timing = InstallerTimingRecorder(
        operation: "install", origin: 1_000, started: Date(timeIntervalSince1970: 1_800_000_000),
        bootSession: "boot-1")
      timing.step("credential_validation", start: 1_000, end: 2_000, completed: true)
      timing.attach(journal: journal)
      timing.step("helper_import", start: 2_000, end: 3_000, completed: true)
      let sidecar = URL(fileURLWithPath: journal.path + InstallerTimingRecorder.fileSuffix)
      XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

      try FileManager.default.createDirectory(
        at: journals, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try InstallerTimingRecorder.$current.withValue(timing) {
        try InstallerPerformance.measure("source_owner") {}
        XCTAssertThrowsError(
          try InstallerPerformance.measure("payload_preflight") { () throws -> Void in
            throw CocoaError(.fileNoSuchFile)
          }
        )
      }
      let saved = try lines(sidecar)
      XCTAssertEqual(
        saved.map { $0["type"] as? String }, ["attempt", "step", "step", "step", "step"])
      XCTAssertEqual(saved[0]["operation"] as? String, "install")
      XCTAssertEqual(saved[0]["boot"] as? String, "boot-1")
      XCTAssertEqual(saved[0]["monotonic_ns"] as? Int, 1_000)
      XCTAssertEqual(
        saved.dropFirst().map { $0["name"] as? String },
        ["credential_validation", "helper_import", "source_owner", "payload_preflight"])
      XCTAssertEqual(saved[4]["completed"] as? Bool, false)
      XCTAssertEqual(try mode(of: sidecar), 0o600)

      // A second attempt adds to the same file and starts with its own line.
      let next = InstallerTimingRecorder(operation: "retry-recovery-authorization")
      next.attach(journal: journal)
      next.step("recovery_handoff", start: InstallerTimingRecorder.now(), end: 0, completed: true)
      XCTAssertEqual(try lines(sidecar).count, 7)
    }

    func testAnAttemptReportsEachMeasuredStepAsItStarts() async {
      final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var all: [String] { lock.withLock { names } }
        func append(_ name: String) { lock.withLock { names.append(name) } }
      }
      let started = Started()
      let observe: @Sendable (String) -> Void = { started.append($0) }
      await InstallerTimingRecorder.attempt("install", observe: observe) {
        InstallerPerformance.measure("source_owner") {
          XCTAssertEqual(started.all, ["source_owner"])
          InstallerPerformance.measure("owner_snapshot") {}
        }
        await InstallerPerformance.measuring("stub_files_preflight") {}
      }
      XCTAssertEqual(started.all, ["source_owner", "owner_snapshot", "stub_files_preflight"])
      // Outside an attempt nothing is reported.
      InstallerPerformance.measure("finishing") {}
      XCTAssertEqual(started.all.count, 3)
    }

    func testAnUnsafeSidecarIsNeverWritten() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journal = root.appendingPathComponent(String(repeating: "b", count: 64) + ".jsonl")
      let sidecar = URL(fileURLWithPath: journal.path + InstallerTimingRecorder.fileSuffix)
      let elsewhere = root.appendingPathComponent("elsewhere")
      try Data().write(to: elsewhere)
      try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: elsewhere)
      let linked = InstallerTimingRecorder(operation: "install")
      linked.attach(journal: journal)
      linked.step("source_owner", start: 0, end: 1, completed: true)
      XCTAssertEqual(try Data(contentsOf: elsewhere), Data())

      try FileManager.default.removeItem(at: sidecar)
      try Data().write(to: sidecar)
      chmod(sidecar.path, 0o644)
      let exposed = InstallerTimingRecorder(operation: "install")
      exposed.attach(journal: journal)
      exposed.step("source_owner", start: 0, end: 1, completed: true)
      XCTAssertEqual(try Data(contentsOf: sidecar), Data())
      XCTAssertEqual(exposed.entries.count, 1, "The attempt still keeps its own timeline")
    }

    func testSummaryNestsStepsAndPlacesJournalRecordsInTime() {
      let second: UInt64 = 1_000_000_000
      let timing = InstallerTimingRecorder(
        operation: "install", origin: 10 * second, started: Date(timeIntervalSince1970: 0),
        bootSession: "boot-1")
      timing.step("owner_device", start: 11 * second, end: 12 * second, completed: true)
      timing.step("source_owner", start: 11 * second, end: 14 * second, completed: true)
      timing.step("stub_files", start: 20 * second, end: 434 * second, completed: false)
      timing.step("apfs_preparation", start: 15 * second, end: 19 * second, completed: true)
      let summary = timing.summary
      XCTAssertTrue(summary.contains("started: 1970-01-01T00:00:00.000Z"), summary)
      XCTAssertTrue(summary.contains("boot session: boot-1"), summary)
      let rows = summary.split(separator: "\n").drop { !$0.contains("seconds") }.dropFirst()
      XCTAssertEqual(
        rows.map(String.init),
        [
          "     1.0      3.00  source_owner",
          "     1.0      1.00    owner_device",
          "     5.0      4.00  apfs_preparation",
          "    10.0    414.00  stub_files (stopped)",
        ])
    }

    func testSummaryShowsJournalRecordsInsideTheStepThatWroteThem() throws {
      let timing = InstallerTimingRecorder(operation: "install")
      let start = InstallerTimingRecorder.now() - 1_000
      timing.record(sequence: 4, type: "event", name: "apfs_preparation_started")
      timing.step(
        "apfs_preparation", start: start, end: InstallerTimingRecorder.now() + 1_000_000_000,
        completed: true)
      let rows = timing.summary.split(separator: "\n").drop { !$0.contains("seconds") }
        .dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
      XCTAssertEqual(rows.count, 2)
      XCTAssertTrue(rows[0].hasSuffix("apfs_preparation"), rows[0])
      XCTAssertTrue(rows[1].hasSuffix("-    journal #4 event apfs_preparation_started"), rows[1])
    }

    func testTimingReportIsPrivateAndPrunedSeparatelyFromFailures() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let timing = InstallerTimingRecorder(operation: "install")
      timing.step("stub_files", start: 0, end: 2_000_000_000, completed: true)
      let failure = EngineFailureReport(
        notice: EngineFailureNotice(
          reason: .unclassified, exitStatus: 1, diskUnchanged: false, summary: "stopped"),
        redactedStandardErrorTail: "")
      EngineFailureDiagnosticsStore.write(
        failure, operation: "install", in: root, now: Date(timeIntervalSince1970: 1_800_000_000))
      var last: URL?
      for index in 0..<(EngineFailureDiagnosticsStore.maximumRetainedReports + 2) {
        last = EngineFailureDiagnosticsStore.writeTiming(
          timing, outcome: "finished", in: root,
          now: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)))
      }
      let url = try XCTUnwrap(last)
      XCTAssertEqual(try mode(of: url), 0o600)
      let body = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(body.hasPrefix("Aurora installer timing\n"), body)
      XCTAssertTrue(body.contains("outcome: finished"), body)
      XCTAssertTrue(body.contains("2.00  stub_files"), body)
      let names = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("diagnostics").path)
      XCTAssertEqual(names.filter { $0.hasPrefix("engine-failure-") }.count, 1)
      XCTAssertEqual(
        names.filter { $0.hasPrefix("installation-timing-") }.count,
        EngineFailureDiagnosticsStore.maximumRetainedReports)
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
      try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      }
    }

    private func temporaryDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-installer-timing-\(UUID().uuidString.lowercased())", isDirectory: true)
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
