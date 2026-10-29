#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  enum NativeAdmissionTestData {
    static let evidence = Data("durable checkpoint".utf8)
    static var inventory: EngineInventoryMessage {
      let candidates = [
        EngineInstallCandidate(
          kind: "free", sourceIdentifier: "disk0s2",
          offsetBytes: 4096, lengthBytes: 100_663_296, minimumInstallBytes: 4096,
          minimumContainerBytes: 0, identityDigest: nil,
          recommendedInstallBytes: nil, recommendedContainerBytes: nil)
      ]
      let unsigned = EngineInventoryMessage(
        layoutDigest: "", systemStoreIdentifier: "disk0",
        candidates: candidates)
      return EngineInventoryMessage(
        layoutDigest: unsigned.computedLayoutDigest,
        systemStoreIdentifier: "disk0", candidates: candidates)
    }
    static var plan: EnginePlanMessage {
      let digest = "sha256:" + String(repeating: "c", count: 64)
      let unsigned = EnginePlanMessage(
        planDigest: "", deviceIdentifier: "apple,j314s",
        storeIdentifier: "disk0", layoutDigest: inventory.layoutDigest, candidateKind: "free",
        sourceIdentifier: "disk0s2", offsetBytes: 4096, lengthBytes: 100_663_296,
        engineVersion: "fixture", engineDigest: digest, metadataDigest: digest,
        payloadDigest: digest, repairManifestDigest: nil,
        requiredHumanSteps: ["enterOneTrueRecovery"])
      return EnginePlanMessage(
        planDigest: unsigned.computedPlanDigest,
        deviceIdentifier: unsigned.deviceIdentifier, storeIdentifier: unsigned.storeIdentifier,
        layoutDigest: unsigned.layoutDigest, candidateKind: unsigned.candidateKind,
        sourceIdentifier: unsigned.sourceIdentifier, offsetBytes: unsigned.offsetBytes,
        lengthBytes: unsigned.lengthBytes, engineVersion: unsigned.engineVersion,
        engineDigest: unsigned.engineDigest, metadataDigest: unsigned.metadataDigest,
        payloadDigest: unsigned.payloadDigest, repairManifestDigest: nil,
        requiredHumanSteps: unsigned.requiredHumanSteps)
    }
    static func journal(
      stages: Int = 0, pendingRecovery: Bool = false,
      completion: Bool = false, pendingDisk: Bool = false
    ) throws -> Data {
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
      }
      var rows: [(String, Any)] = [
        ("inspection", ["device_identifier": "apple,j314s", "support": "supported"]),
        ("inventory", try object(inventory)), ("plan", try object(plan)),
      ]
      let stageNames = [
        ("apfs_preparation_started", "apfs-target-prepared", "apfs_preparation"),
        ("stub_and_esp_started", "stub-and-esp-installed", "stub_and_esp"),
        ("recovery_handoff_started", "recovery-handoff-prepared", "awaiting_recovery"),
      ]
      for stage in stageNames.prefix(stages) {
        rows.append(("event", ["plan_digest": plan.planDigest, "name": stage.0]))
        rows.append(
          (
            "checkpoint",
            [
              "plan_digest": plan.planDigest, "identifier": stage.1,
              "phase": stage.2, "evidence_digest": SHA256Digest(hashing: evidence).rawValue,
            ]
          ))
      }
      if pendingRecovery || pendingDisk {
        rows.append(
          (
            "event",
            [
              "plan_digest": plan.planDigest,
              "name": pendingRecovery ? stageNames[2].0 : stageNames[stages].0,
            ]
          ))
      }
      if completion {
        rows.append(
          ("completion", ["plan_digest": plan.planDigest, "outcome": "awaiting_recovery"]))
      }
      var bytes = Data()
      for (index, row) in rows.enumerated() {
        bytes.append(
          try JSONSerialization.data(
            withJSONObject: [
              "schema_version": 1, "sequence": index + 1, "type": row.0, "payload": row.1,
            ], options: [.sortedKeys]))
        bytes.append(10)
      }
      return bytes
    }
    static func package(intent: ImportedInstallationIntent = .fresh) -> ImportedEngineHandoffPackage
    {
      let url = URL(fileURLWithPath: "/fixture")
      return ImportedEngineHandoffPackage(
        packageURL: url, manifestURL: url, requestURL: url,
        identityURL: url, metadataURL: url, payloadURL: url,
        bindingDigest: "sha256:" + String(repeating: "b", count: 64), planDigest: plan.planDigest,
        deviceIdentifier: "apple,j314s", storeIdentifier: "disk0", installationIntent: intent)
    }
    static func facts(existing: Bool = false) -> NativeInstallAdmissionFacts {
      NativeInstallAdmissionFacts(
        deviceIdentifier: "apple,j314s", storeIdentifier: "disk0",
        knownInstallations: existing
          ? [
            NativeKnownInstallation(
              sourceIdentifier: "disk0s4",
              offsetBytes: 4096, lengthBytes: 8192)
          ] : [])
    }
  }

  final class NativeInstallAdmissionTests: XCTestCase {
    func testFreshEmptyAndReadOnlyJournalsRecollectAndRefuseExistingInstallations() throws {
      for journal in [Data(), try NativeAdmissionTestData.journal()] {
        XCTAssertNoThrow(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(),
            journal: journal, collect: { NativeAdmissionTestData.facts() }))
        XCTAssertThrowsError(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(),
            journal: journal, collect: { NativeAdmissionTestData.facts(existing: true) })
        ) {
          XCTAssertEqual($0 as? NativeInstallAdmissionError, .existingInstallation)
        }
      }
    }

    func testCollectionFailureAndChangedDeviceOrStoreFailClosed() throws {
      XCTAssertThrowsError(
        try NativeInstallAdmission.check(
          package: NativeAdmissionTestData.package(),
          journal: Data(), collect: { throw CocoaError(.fileReadNoPermission) }))
      for facts in [
        NativeInstallAdmissionFacts(
          deviceIdentifier: "apple,j700", storeIdentifier: "disk0", knownInstallations: []),
        NativeInstallAdmissionFacts(
          deviceIdentifier: "apple,j314s", storeIdentifier: "disk1", knownInstallations: []),
      ] {
        XCTAssertThrowsError(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(),
            journal: Data(), collect: { facts })
        ) {
          XCTAssertEqual($0 as? NativeInstallAdmissionError, .deviceChanged)
        }
      }
    }

    func testExplicitRepairAndReplacementKeepTheirExistingAdmissionPaths() throws {
      for intent in [ImportedInstallationIntent.repair, .replace] {
        XCTAssertNoThrow(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(intent: intent),
            journal: Data(), collect: { throw CocoaError(.fileReadUnknown) }))
      }
    }

    func testRecordedResumeAndRecoveryHandoffRequireMatchingCheckpointEvidence() throws {
      let journals = try [
        NativeAdmissionTestData.journal(stages: 1), NativeAdmissionTestData.journal(stages: 2),
        NativeAdmissionTestData.journal(stages: 2, pendingRecovery: true),
        NativeAdmissionTestData.journal(stages: 3),
        NativeAdmissionTestData.journal(stages: 3, completion: true),
      ]
      for journal in journals {
        XCTAssertNoThrow(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(),
            journal: journal, collect: { throw CocoaError(.fileReadUnknown) },
            readEvidence: { _ in NativeAdmissionTestData.evidence }))
        for evidence in [Data(), Data("changed".utf8)] {
          XCTAssertThrowsError(
            try NativeInstallAdmission.check(
              package: NativeAdmissionTestData.package(),
              journal: journal, collect: { NativeAdmissionTestData.facts() },
              readEvidence: { _ in evidence }))
        }
        XCTAssertFalse(NativeInstallAdmission.provesNoMutation(journal))
      }
    }

    func testAmbiguousDiskIntentsForeignAndCorruptJournalsNeverBecomeResumeOrUnchanged() throws {
      let valid = try NativeAdmissionTestData.journal(stages: 1)
      var foreign = String(decoding: valid, as: UTF8.self)
      foreign = foreign.replacingOccurrences(of: "apple,j314s", with: "apple,j700")
      let journals = try [
        Data("{\"type\":\"plan\"}\n".utf8), Data("\n".utf8),
        valid.dropLast(), Data(foreign.utf8),
        NativeAdmissionTestData.journal(pendingDisk: true),
        NativeAdmissionTestData.journal(stages: 1, pendingDisk: true),
        NativeAdmissionTestData.journal(stages: 2, completion: true),
      ]
      for journal in journals {
        XCTAssertThrowsError(
          try NativeInstallAdmission.check(
            package: NativeAdmissionTestData.package(),
            journal: journal, collect: { NativeAdmissionTestData.facts() },
            readEvidence: { _ in NativeAdmissionTestData.evidence }))
        XCTAssertFalse(NativeInstallAdmission.provesNoMutation(journal))
      }
      XCTAssertTrue(NativeInstallAdmission.provesNoMutation(Data()))
      XCTAssertTrue(NativeInstallAdmission.provesNoMutation(try NativeAdmissionTestData.journal()))
    }
  }
#endif
