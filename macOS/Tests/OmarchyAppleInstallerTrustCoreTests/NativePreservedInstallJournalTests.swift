#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativePreservedInstallJournalTests: XCTestCase {
    private func transcript() throws -> (Data, ValidatedEnginePlan) {
      let candidate = EngineInstallCandidate(
        kind: "reinstall", sourceIdentifier: "disk0s3", offsetBytes: 4096,
        lengthBytes: 1_048_576, minimumInstallBytes: 1_048_576,
        minimumContainerBytes: 0,
        identityDigest: "sha256:" + String(repeating: "a", count: 64),
        recommendedInstallBytes: nil, recommendedContainerBytes: nil)
      let unsigned = EngineInventoryMessage(
        layoutDigest: "", systemStoreIdentifier: "disk0", candidates: [candidate])
      let inventory = EngineInventoryMessage(
        layoutDigest: unsigned.computedLayoutDigest,
        systemStoreIdentifier: "disk0", candidates: [candidate])
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let encodedInventory = try encoder.encode(inventory)
      let decodedInventory = try JSONSerialization.jsonObject(with: encodedInventory)
      let inventoryPayload = try XCTUnwrap(decodedInventory as? [String: Any])
      let rows: [(String, [String: Any])] = [
        ("inspection", ["device_identifier": "apple,j314s", "support": "supported"]),
        ("inventory", inventoryPayload),
      ]
      var bytes = Data()
      for (index, row) in rows.enumerated() {
        bytes.append(try JSONSerialization.data(withJSONObject: [
          "schema_version": 1, "sequence": index + 1,
          "type": row.0, "payload": row.1,
        ], options: [.sortedKeys]))
        bytes.append(10)
      }
      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      let boundInventory = try XCTUnwrap(inspection.inventory)
      let selected = try XCTUnwrap(boundInventory.candidates.first)
      let request = try PinnedAsahiPlanRequest(
        inventory: boundInventory, candidate: selected,
        requestedLengthBytes: selected.lengthBytes)
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: "test", engineDigest: "sha256:" + String(repeating: "b", count: 64),
        metadataDigest: "sha256:" + String(repeating: "c", count: 64),
        payloadDigest: "sha256:" + String(repeating: "d", count: 64))
      let transcript = try NativeInstallerPlanner.transcript(
        inspection: inspection, request: request, identity: identity)
      let plan = try XCTUnwrap(
        AppleInstallerTrustCore().validateEngineTranscript(transcript).plan)
      return (transcript, plan)
    }

    private func receipt(_ plan: ValidatedEnginePlan) -> NativePreservedInstallReceipt {
      let boot = NativeRawImageReceipt(
        partitionIdentifier: "disk0s5", partitionUUID: UUID().uuidString.lowercased(),
        partitionSizeBytes: 2 << 20, installedBytes: 4096,
        contentSHA256: String(repeating: "e", count: 64),
        verification: "source-sha256-write-flushed-v1")
      let root = NativeRawImageReceipt(
        partitionIdentifier: "disk0s6", partitionUUID: UUID().uuidString.lowercased(),
        partitionSizeBytes: 2 << 20, installedBytes: 4096,
        contentSHA256: String(repeating: "f", count: 64),
        verification: "source-sha256-write-flushed-v1")
      return NativePreservedInstallReceipt(
        planDigest: plan.planDigest,
        targetIdentity: "sha256:" + String(repeating: "1", count: 64),
        espUUID: UUID().uuidString.lowercased(), boot: boot, root: root,
        espDigest: String(repeating: "2", count: 64))
    }

    func testProtectedJournalResumesAndRejectsChangedCompletionEvidence() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-preserved-journal-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let parent = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let binding = "sha256:" + String(repeating: "3", count: 64)
      let journalURL = parent.appendingPathComponent(String(binding.dropFirst(7)) + ".jsonl")
      let (transcript, plan) = try transcript()
      try Data(transcript.prefix(17)).write(to: journalURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
      let package = ImportedEngineHandoffPackage(
        packageURL: root, manifestURL: root.appendingPathComponent("manifest.json"),
        requestURL: root.appendingPathComponent("request.json"),
        identityURL: root.appendingPathComponent("identity.json"),
        engineURL: root.appendingPathComponent("engine"),
        metadataURL: root.appendingPathComponent("metadata"),
        payloadURL: root.appendingPathComponent("payload"),
        bindingDigest: binding, planDigest: plan.planDigest,
        deviceIdentifier: plan.deviceIdentifier, storeIdentifier: plan.storeIdentifier,
        installationIntent: .reinstall)
      let completed = receipt(plan)
      do {
        let journal = try NativePreservedInstallJournal(
          url: journalURL, package: package, transcript: transcript, owner: geteuid())
        XCTAssertEqual(try journal.snapshot().state, .ready)
        try journal.begin()
        try journal.begin()
        XCTAssertEqual(try journal.snapshot().state, .started)
        try journal.recordWritten(completed)
        try journal.recordWritten(completed)
        XCTAssertEqual(try journal.snapshot().state, .written)
        try journal.complete { XCTAssertEqual($0, completed) }
        try journal.complete { XCTAssertEqual($0, completed) }
        XCTAssertEqual(try journal.snapshot().state, .complete)
        XCTAssertEqual(try journal.snapshot().receipt, .some(completed))
      }
      let reopened = try NativePreservedInstallJournal(
        url: journalURL, package: package, transcript: transcript, owner: geteuid())
      XCTAssertEqual(try reopened.snapshot().state, .complete)
      let evidence = URL(fileURLWithPath: journalURL.path + ".preserved-install-written.evidence")
      try Data("changed".utf8).write(to: evidence)
      XCTAssertThrowsError(try reopened.snapshot())
    }
  }
#endif
