#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeInstallerPlannerTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
      let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let document = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appendingPathComponent("native-plan-vectors.json")))
          as? [String: Any])
      return try XCTUnwrap(document["vectors"] as? [[String: Any]])
    }

    private func input(_ vector: [String: Any]) throws -> (
      inspection: ValidatedEngineTranscript, request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity
    ) {
      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(
        Data(try XCTUnwrap(vector["inspection"] as? String).utf8))
      let inventory = try XCTUnwrap(inspection.inventory)
      let candidate = try XCTUnwrap(inventory.candidates.first)
      let identity = try XCTUnwrap(vector["identity"] as? [String: String])
      return (
        inspection,
        try PinnedAsahiPlanRequest(
          inventory: inventory, candidate: candidate,
          requestedLengthBytes: try XCTUnwrap(vector["requested"] as? NSNumber).uint64Value),
        try PinnedAsahiPlanIdentity(
          engineVersion: try XCTUnwrap(identity["engine_version"]),
          engineDigest: try XCTUnwrap(identity["engine_digest"]),
          metadataDigest: try XCTUnwrap(identity["metadata_digest"]),
          payloadDigest: try XCTUnwrap(identity["payload_digest"]),
          repairManifestDigest: identity["repair_manifest_digest"])
      )
    }

    func testNativePlansMatchAllIndependentReferenceVectors() async throws {
      let vectors = try vectors()
      XCTAssertEqual(vectors.count, 7)
      for vector in vectors {
        let value = try input(vector)
        let bytes = try await NativeInstallerPlanner().plan(
          inspection: value.inspection, request: value.request, identity: value.identity)
        let actual = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
        var reference = Data(try XCTUnwrap(vector["inspection"] as? String).utf8)
        reference.append(
          try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "sequence": 3, "type": "plan", "payload": vector["expected_plan"]!,
          ]))
        reference.append(10)
        let expected = try AppleInstallerTrustCore().validateEngineTranscript(reference)
        XCTAssertEqual(actual, expected, vector["name"] as? String ?? "vector")
        XCTAssertNil(actual.completion)
        XCTAssertTrue(actual.checkpoints.isEmpty)
        XCTAssertEqual(bytes.split(separator: 10).count, 3)
      }
    }

    private func replacing(
      _ original: ValidatedEngineTranscript,
      candidates: [ValidatedEngineCandidate]? = nil, layout: String? = nil,
      support: EngineSupport? = nil
    ) throws -> ValidatedEngineTranscript {
      let inventory = try XCTUnwrap(original.inventory)
      return ValidatedEngineTranscript(
        deviceIdentifier: original.deviceIdentifier,
        support: support ?? original.support,
        inventory: ValidatedEngineInventory(
          layoutDigest: layout ?? inventory.layoutDigest,
          systemStoreIdentifier: inventory.systemStoreIdentifier,
          candidates: candidates ?? inventory.candidates),
        plan: nil, checkpoints: [], completion: nil)
    }

    func testChangedLayoutMissingOrDuplicateCandidateAndUnsupportedInspectionAreRejected() throws {
      let value = try input(XCTUnwrap(vectors().first))
      let candidate = try XCTUnwrap(value.inspection.inventory?.candidates.first)
      for inspection in [
        try replacing(value.inspection, layout: "sha256:" + String(repeating: "0", count: 64)),
        try replacing(value.inspection, candidates: []),
        try replacing(value.inspection, candidates: [candidate, candidate]),
        try replacing(value.inspection, support: .unsupported),
      ] {
        XCTAssertThrowsError(
          try NativeInstallerPlanner.transcript(
            inspection: inspection, request: value.request, identity: value.identity))
      }
    }

    func testFreshMinimumsAndOverflowAreCheckedAgain() throws {
      let value = try input(XCTUnwrap(vectors().first))
      let original = try XCTUnwrap(value.inspection.inventory?.candidates.first)
      for overflow in [false, true] {
        let candidate = ValidatedEngineCandidate(
          kind: original.kind,
          sourceIdentifier: original.sourceIdentifier,
          offsetBytes: overflow ? UInt64.max : original.offsetBytes,
          lengthBytes: original.lengthBytes,
          minimumInstallBytes: overflow ? original.minimumInstallBytes : original.lengthBytes,
          minimumContainerBytes: original.minimumContainerBytes)
        let changed = try replacing(value.inspection, candidates: [candidate])
        XCTAssertThrowsError(
          try NativeInstallerPlanner.transcript(
            inspection: changed, request: value.request, identity: value.identity))
      }
    }

    func testRepairIdentityCannotBeAppliedToAFreshInstallation() throws {
      let value = try input(XCTUnwrap(vectors().first))
      let repair = try PinnedAsahiPlanIdentity(
        engineVersion: value.identity.engineVersion,
        engineDigest: value.identity.engineDigest, metadataDigest: value.identity.metadataDigest,
        payloadDigest: value.identity.payloadDigest,
        repairManifestDigest: "sha256:" + String(repeating: "7", count: 64))
      XCTAssertThrowsError(
        try NativeInstallerPlanner.transcript(
          inspection: value.inspection, request: value.request, identity: repair))
    }

    func testAnAlreadyPlannedTranscriptIsNotAFreshInspection() throws {
      let value = try input(XCTUnwrap(vectors().first))
      let planned = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeInstallerPlanner.transcript(
          inspection: value.inspection, request: value.request, identity: value.identity))
      XCTAssertThrowsError(
        try NativeInstallerPlanner.transcript(
          inspection: planned, request: value.request, identity: value.identity))
    }

    func testCancellationStopsNativePlanning() async throws {
      let value = try input(XCTUnwrap(vectors().first))
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeInstallerPlanner().plan(
          inspection: value.inspection, request: value.request, identity: value.identity)
      }
      do {
        _ = try await task.value
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
  }
#endif
