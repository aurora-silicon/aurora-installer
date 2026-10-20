#if os(macOS)
  import Darwin
  import Foundation

  enum NativePreservedInstallState: Equatable, Sendable {
    case ready, started, written, complete
  }

  struct NativePreservedInstallReceipt: Codable, Equatable, Sendable {
    let planDigest: String
    let targetIdentity: String
    let espUUID: String
    let boot: NativeRawImageReceipt
    let root: NativeRawImageReceipt
    let espDigest: String

    func validate(plan: ValidatedEnginePlan, expectedTarget: String) throws {
      guard planDigest == plan.planDigest, targetIdentity == expectedTarget,
        SHA256Digest(rawValue: targetIdentity) != nil,
        UUID(uuidString: espUUID) != nil, SHA256Digest(hexadecimal: espDigest) != nil,
        boot.verification == "source-sha256-write-flushed-v1",
        root.verification == "source-sha256-write-flushed-v1",
        [boot, root].allSatisfy({ image in
          image.installedBytes > 0 && image.installedBytes <= image.partitionSizeBytes
            && SHA256Digest(hexadecimal: image.contentSHA256) != nil
            && UUID(uuidString: image.partitionUUID) != nil
        })
      else { throw NativeRecoveryJournalError.invalidState }
    }
  }

  struct NativePreservedInstallJournalSnapshot: Sendable {
    let transcript: Data
    let plan: ValidatedEnginePlan
    let targetIdentity: String
    let state: NativePreservedInstallState
    let receipt: NativePreservedInstallReceipt?

    static func decode(
      _ bytes: Data, package: ImportedEngineHandoffPackage,
      evidence: (String) throws -> Data
    ) throws -> Self {
      let records = try EngineTranscriptDecoder().decode(bytes)
      let validated = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      guard package.installationIntent == .reinstall,
        validated.support == .supported,
        validated.deviceIdentifier == package.deviceIdentifier,
        let plan = validated.plan, plan.candidateKind == "reinstall",
        let inventory = validated.inventory,
        inventory.candidates.filter({
          $0.kind == "reinstall" && $0.sourceIdentifier == plan.sourceIdentifier
        }).count == 1,
        let targetIdentity = inventory.candidates.first(where: {
          $0.kind == "reinstall" && $0.sourceIdentifier == plan.sourceIdentifier
        })?.identityDigest,
        plan.planDigest == package.planDigest,
        plan.storeIdentifier == package.storeIdentifier,
        plan.requiredHumanSteps == ["authenticateMachineOwner"],
        (3...6).contains(records.count)
      else { throw NativeRecoveryJournalError.invalidState }
      if records.count == 3 {
        return Self(
          transcript: bytes, plan: plan, targetIdentity: targetIdentity,
          state: .ready, receipt: nil)
      }
      guard case .event(let event) = records[3].message,
        event.name == "preserved_reinstall_started", event.planDigest == plan.planDigest
      else { throw NativeRecoveryJournalError.invalidState }
      if records.count == 4 {
        return Self(
          transcript: bytes, plan: plan, targetIdentity: targetIdentity,
          state: .started, receipt: nil)
      }
      guard case .checkpoint(let checkpoint) = records[4].message,
        checkpoint.identifier == "preserved-install-written",
        checkpoint.phase == "preserved_reinstall",
        checkpoint.planDigest == plan.planDigest
      else { throw NativeRecoveryJournalError.invalidState }
      let saved = try evidence(checkpoint.identifier)
      guard SHA256Digest(hashing: saved).rawValue == checkpoint.evidenceDigest else {
        throw NativeRecoveryJournalError.evidenceChanged
      }
      let receipt = try JSONDecoder().decode(NativePreservedInstallReceipt.self, from: saved)
      try receipt.validate(plan: plan, expectedTarget: targetIdentity)
      if records.count == 5 {
        return Self(
          transcript: bytes, plan: plan, targetIdentity: targetIdentity,
          state: .written, receipt: receipt)
      }
      guard case .completion(let completion) = records[5].message,
        completion.planDigest == plan.planDigest, completion.outcome == "installed"
      else { throw NativeRecoveryJournalError.invalidState }
      return Self(
        transcript: bytes, plan: plan, targetIdentity: targetIdentity,
        state: .complete, receipt: receipt)
    }
  }

  final class NativePreservedInstallJournal: @unchecked Sendable {
    private let file: NativeInstallJournalFile
    private let package: ImportedEngineHandoffPackage

    init(
      url: URL, package: ImportedEngineHandoffPackage,
      transcript: Data, owner: uid_t = 0
    ) throws {
      self.package = package
      file = try NativeInstallJournalFile(url: url, package: package, owner: owner)
      let existing = try file.readJournal()
      if existing.count <= transcript.count {
        try file.initialize(transcript)
      } else if !existing.starts(with: transcript) {
        throw NativeRecoveryJournalError.changed
      }
      _ = try snapshot()
    }

    func snapshot() throws -> NativePreservedInstallJournalSnapshot {
      try file.transaction { try current() }
    }

    func begin() throws {
      try file.transaction {
        let before = try current()
        if before.state == .ready {
          try file.append(
            type: "event",
            payload: [
              "plan_digest": package.planDigest, "name": "preserved_reinstall_started",
            ], before: before.transcript)
        }
      }
    }

    func imageReceipt(_ name: String) throws -> NativeRawImageReceipt? {
      guard ["boot", "root"].contains(name) else { throw NativeRecoveryJournalError.invalidState }
      return try file.transaction {
        let before = try current()
        guard before.state != .ready else { throw NativeRecoveryJournalError.invalidState }
        let identifier = "preserved-image-" + name
        guard try file.containsEvidence(identifier) else { return nil }
        return try JSONDecoder().decode(
          NativeRawImageReceipt.self, from: file.readEvidence(identifier))
      }
    }

    func recordImage(_ receipt: NativeRawImageReceipt, name: String) throws {
      guard ["boot", "root"].contains(name) else { throw NativeRecoveryJournalError.invalidState }
      try file.transaction {
        let before = try current()
        guard before.state == .started,
          receipt.verification == "source-sha256-write-flushed-v1",
          receipt.installedBytes > 0, receipt.installedBytes <= receipt.partitionSizeBytes,
          SHA256Digest(hexadecimal: receipt.contentSHA256) != nil
        else { throw NativeRecoveryJournalError.invalidState }
        try file.publishEvidence(Self.encode(receipt), identifier: "preserved-image-" + name)
      }
    }

    func recordWritten(_ receipt: NativePreservedInstallReceipt) throws {
      try file.transaction {
        let before = try current()
        try receipt.validate(plan: before.plan, expectedTarget: before.targetIdentity)
        let bytes = try Self.encode(receipt)
        if before.state == .written || before.state == .complete {
          guard try file.readEvidence("preserved-install-written") == bytes else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
          return
        }
        guard before.state == .started else { throw NativeRecoveryJournalError.invalidState }
        try file.publishEvidence(bytes, identifier: "preserved-install-written")
        try file.append(
          type: "checkpoint",
          payload: [
            "plan_digest": package.planDigest, "identifier": "preserved-install-written",
            "phase": "preserved_reinstall",
            "evidence_digest": SHA256Digest(hashing: bytes).rawValue,
          ], before: before.transcript)
      }
    }

    func complete(verify: (NativePreservedInstallReceipt) throws -> Void) throws {
      try file.transaction {
        let before = try current()
        guard let receipt = before.receipt else { throw NativeRecoveryJournalError.invalidState }
        try verify(receipt)
        if before.state == .complete { return }
        guard before.state == .written else { throw NativeRecoveryJournalError.invalidState }
        try file.append(
          type: "completion",
          payload: ["plan_digest": package.planDigest, "outcome": "installed"],
          before: before.transcript)
      }
    }

    private func current() throws -> NativePreservedInstallJournalSnapshot {
      try NativePreservedInstallJournalSnapshot.decode(file.readJournal(), package: package) {
        try file.readEvidence($0)
      }
    }

    private static func encode(_ receipt: NativePreservedInstallReceipt) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(receipt)
    }
  }
#endif
