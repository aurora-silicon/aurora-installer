#if os(macOS)
  import Darwin
  import Foundation

  enum NativeRecoveryJournalError: Error, Equatable {
    case unsafeJournal
    case busy
    case invalidState
    case changed
    case evidenceChanged
    case writeFailed
  }

  enum NativeRecoveryHandoffState: Equatable, Sendable {
    case ready, started, prepared, complete
  }

  struct NativeRecoveryJournalSnapshot: Sendable {
    let transcript: Data
    let plan: ValidatedEnginePlan
    let state: NativeRecoveryHandoffState
    let evidence: [String: Data]

    static func decode(
      _ bytes: Data, package: ImportedEngineHandoffPackage,
      evidence: (String) throws -> Data
    ) throws -> Self {
      try decode(
        bytes, planDigest: package.planDigest, deviceIdentifier: package.deviceIdentifier,
        storeIdentifier: package.storeIdentifier, intent: package.installationIntent,
        evidence: evidence)
    }

    static func decode(
      _ bytes: Data, planDigest: String, deviceIdentifier: String,
      storeIdentifier: String, intent: ImportedInstallationIntent,
      evidence: (String) throws -> Data
    ) throws -> Self {
      let records = try EngineTranscriptDecoder().decode(bytes)
      let validated = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      guard let plan = validated.plan, validated.support == .supported,
        validated.deviceIdentifier == deviceIdentifier,
        plan.deviceIdentifier == deviceIdentifier, plan.storeIdentifier == storeIdentifier,
        plan.planDigest == planDigest, intent != .repair,
        intent == .replace
          ? plan.candidateKind == "replace"
          : ["free", "resize"].contains(plan.candidateKind)
      else { throw NativeRecoveryJournalError.invalidState }
      var stages = [
        ("apfs_preparation_started", "apfs-target-prepared", "apfs_preparation"),
        ("stub_and_esp_started", "stub-and-esp-installed", "stub_and_esp"),
      ]
      if intent == .replace {
        stages.insert(
          ("existing_removal_started", "existing-install-removed", "existing_removal"), at: 0)
      }
      var cursor = 3
      var saved = [String: Data]()
      func checkpoint(_ index: Int, identifier: String, phase: String) throws {
        guard index < records.count, case .checkpoint(let checkpoint) = records[index].message,
          checkpoint.identifier == identifier, checkpoint.phase == phase
        else {
          throw NativeRecoveryJournalError.invalidState
        }
        let bytes = try evidence(identifier)
        guard SHA256Digest(hashing: bytes).rawValue == checkpoint.evidenceDigest,
          let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          object["plan_digest"] as? String == plan.planDigest
        else { throw NativeRecoveryJournalError.evidenceChanged }
        saved[identifier] = bytes
      }
      for stage in stages {
        guard cursor < records.count, case .event(let event) = records[cursor].message,
          event.name == stage.0
        else { throw NativeRecoveryJournalError.invalidState }
        try checkpoint(cursor + 1, identifier: stage.1, phase: stage.2)
        cursor += 2
      }
      let state: NativeRecoveryHandoffState
      if cursor == records.count {
        state = .ready
      } else {
        guard case .event(let event) = records[cursor].message,
          event.name == "recovery_handoff_started"
        else { throw NativeRecoveryJournalError.invalidState }
        cursor += 1
        if cursor == records.count {
          state = .started
        } else {
          try checkpoint(
            cursor, identifier: "recovery-handoff-prepared", phase: "awaiting_recovery")
          guard saved["recovery-handoff-prepared"] == handoffEvidence(plan.planDigest) else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
          cursor += 1
          if cursor == records.count {
            state = .prepared
          } else {
            guard cursor + 1 == records.count,
              case .completion(let completion) = records[cursor].message,
              completion.outcome == "awaiting_recovery"
            else { throw NativeRecoveryJournalError.invalidState }
            state = .complete
          }
        }
      }
      return Self(transcript: bytes, plan: plan, state: state, evidence: saved)
    }

    static func handoffEvidence(_ digest: String) -> Data {
      // The existing backend uses these exact canonical bytes.
      Data("{\"outcome\":\"awaiting_recovery\",\"plan_digest\":\"\(digest)\"}".utf8)
    }
  }

  /// The Recovery stage admits only a completed disk-stage prefix.
  final class NativeRecoveryJournal: @unchecked Sendable {
    private let file: NativeInstallJournalFile
    private let package: ImportedEngineHandoffPackage

    init(url: URL, package: ImportedEngineHandoffPackage, owner: uid_t = 0) throws {
      self.package = package
      file = try NativeInstallJournalFile(url: url, package: package, owner: owner)
      _ = try snapshot()
    }

    func snapshot() throws -> NativeRecoveryJournalSnapshot {
      try file.transaction { try current() }
    }

    func beginHandoff() throws {
      try file.transaction {
        let before = try current()
        guard before.state == .ready || before.state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        if before.state == .ready {
          try file.append(
            type: "event",
            payload: [
              "plan_digest": package.planDigest, "name": "recovery_handoff_started",
            ], before: before.transcript)
        }
      }
    }

    func recordPrepared() throws {
      try file.transaction {
        let before = try current()
        guard before.state == .started else { throw NativeRecoveryJournalError.invalidState }
        let bytes = NativeRecoveryJournalSnapshot.handoffEvidence(package.planDigest)
        try file.publishEvidence(bytes, identifier: "recovery-handoff-prepared")
        try file.append(
          type: "checkpoint",
          payload: [
            "plan_digest": package.planDigest,
            "identifier": "recovery-handoff-prepared", "phase": "awaiting_recovery",
            "evidence_digest": SHA256Digest(hashing: bytes).rawValue,
          ], before: before.transcript)
      }
    }

    func complete() throws -> Data {
      try file.transaction {
        let before = try current()
        guard before.state == .prepared || before.state == .complete else {
          throw NativeRecoveryJournalError.invalidState
        }
        if before.state == .prepared {
          try file.append(
            type: "completion",
            payload: [
              "plan_digest": package.planDigest, "outcome": "awaiting_recovery",
            ], before: before.transcript)
        }
        return try current().transcript
      }
    }

    private func current() throws -> NativeRecoveryJournalSnapshot {
      try NativeRecoveryJournalSnapshot.decode(file.readJournal(), package: package) {
        try file.readEvidence($0)
      }
    }
  }
#endif
