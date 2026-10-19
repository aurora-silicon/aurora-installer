#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerJobTests: XCTestCase {
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
        operation: "install", installConf: try InstallConf(encrypt: true, lane: "stable").serializedData)
    }

    func testExactDuplicateObservesOnceWhileChangedOptionsAndOtherUIDAreRejected() throws {
      let root = try workspace()
      let work = HelperWorkState()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: work)
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      XCTAssertFalse(try jobs.begin(request, initiatingUID: 501))
      XCTAssertFalse(work.beginReplacement(token: "replacement"))
      XCTAssertThrowsError(try jobs.begin(request, initiatingUID: 502)) {
        XCTAssertEqual($0 as? InstallerJobError, .identityMismatch)
      }
      let changed = InstallerJobStartRequest(
        ticket: request.ticket, operation: request.operation,
        installConf: try InstallConf(encrypt: false, lane: "stable").serializedData)
      XCTAssertThrowsError(try jobs.begin(changed, initiatingUID: 501)) {
        XCTAssertEqual($0 as? InstallerJobError, .identityMismatch)
      }
      jobs.finish(request.ticket.identifier, result: .failure(InstallerJobError.interrupted))
      XCTAssertTrue(work.beginReplacement(token: "replacement"))
    }

    func testWrongObservationTokenCannotReadAnotherJobAndRootRecordNeverStoresTheToken() throws {
      let root = try workspace()
      let jobs = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try jobs.begin(request, initiatingUID: 501))
      var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.ticket)) as? [String: Any])
      fields["observationToken"] = String(repeating: "b", count: 64)
      let wrong = try JSONDecoder().decode(InstallerJobTicket.self, from: JSONSerialization.data(withJSONObject: fields))
      XCTAssertThrowsError(try jobs.status(
        InstallerJobStatusRequest(ticket: wrong, journalOffset: 0), initiatingUID: 501))
      let saved = root.appendingPathComponent("installation-jobs")
        .appendingPathComponent(request.ticket.identifier.uuidString.lowercased() + ".json")
      let text = try String(contentsOf: saved, encoding: .utf8)
      XCTAssertFalse(text.contains(request.ticket.observationToken))
      XCTAssertTrue(text.contains(request.ticket.tokenDigest))
    }

    func testHelperRestartReportsInterruptedAndNeverStartsTheOldJobAgain() throws {
      let root = try workspace()
      let first = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try first.begin(request, initiatingUID: 501))
      let restarted = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let snapshot = try restarted.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      XCTAssertEqual(snapshot.phase, .interrupted)
      XCTAssertNil(snapshot.transcript)
      XCTAssertThrowsError(try snapshot.requireResult()) {
        XCTAssertEqual($0 as? InstallerJobError, .interrupted)
      }
      XCTAssertFalse(try restarted.begin(request, initiatingUID: 501))
    }

    func testTerminalResultSurvivesHelperRestartWithTheSameHandoffOutcome() throws {
      let root = try workspace()
      let first = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let request = try request()
      XCTAssertTrue(try first.begin(request, initiatingUID: 501))
      let transcript = Data("bounded transcript fixture\n".utf8)
      first.finish(request.ticket.identifier, result: .success((transcript, .unconfirmed(encrypt: true))))
      let restarted = InstallerJobRegistry(workingDirectory: root, work: HelperWorkState())
      let snapshot = try restarted.status(
        InstallerJobStatusRequest(ticket: request.ticket, journalOffset: 0), initiatingUID: 501)
      let (result, handoff) = try snapshot.requireResult()
      XCTAssertEqual(result, transcript)
      XCTAssertEqual(handoff, .unconfirmed(encrypt: true))
    }

    func testPendingHintRejectsSymlinksHardlinksAndPubliclyReadableState() throws {
      let root = try workspace()
      let store = PendingInstallerJobStore(directory: root)
      let hint = PendingInstallerJob(
        ticket: try request().ticket, helperMachServiceName: "org.aurora.helper",
        helperCodeSigningRequirement: "identifier \"org.aurora.helper\"")
      try store.save(hint)
      XCTAssertEqual(try store.load(), hint)
      let file = root.appendingPathComponent("pending-installation.json")
      XCTAssertEqual(chmod(file.path, 0o644), 0)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(chmod(file.path, 0o600), 0)
      let linkURL = root.appendingPathComponent("second-link")
      XCTAssertEqual(link(file.path, linkURL.path), 0)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(unlink(linkURL.path), 0)
      try FileManager.default.moveItem(at: file, to: linkURL)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linkURL)
      XCTAssertThrowsError(try store.load())
    }
  }
#endif
