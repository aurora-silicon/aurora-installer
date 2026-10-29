#if os(macOS)
  import Foundation

  struct NativeInstallAdmissionFacts: Sendable {
    let deviceIdentifier: String
    let storeIdentifier: String
    let knownInstallations: [NativeKnownInstallation]

    static func live() throws -> Self {
      let host = try AppleSiliconHostInspector().inspect()
      guard !AppleSiliconHostInspector.isExplicitlyUnsupported(host.identity.deviceIdentifier)
      else {
        throw NativeInstallAdmissionError.deviceChanged
      }
      let disk = try NativeDiskCollector().collect(host: host)
      return Self(
        deviceIdentifier: host.identity.deviceIdentifier,
        storeIdentifier: disk.snapshot.disk,
        knownInstallations: try NativeKnownInstallations.recognize(disk))
    }
  }

  enum NativeInstallAdmissionError: Error, Equatable {
    case invalidJournal
    case deviceChanged
    case existingInstallation
  }

  enum NativeInstallAdmission {
    /// Recheck immediately before execution. A journal only exempts a recorded
    /// operation when its complete contract and imported identity both match.
    static func check(
      package: ImportedEngineHandoffPackage, journal: Data,
      collect: () throws -> NativeInstallAdmissionFacts,
      readEvidence: (String) throws -> Data = { _ in
        throw NativeInstallAdmissionError.invalidJournal
      }
    ) throws {
      guard package.installationIntent == .fresh else { return }
      if !journal.isEmpty {
        let records: [EngineContractEnvelope]
        let validated: ValidatedEngineTranscript
        do {
          records = try EngineTranscriptDecoder().decode(journal)
          validated = try AppleInstallerTrustCore().validateEngineTranscript(journal)
        } catch { throw NativeInstallAdmissionError.invalidJournal }
        guard validated.deviceIdentifier == package.deviceIdentifier,
          validated.support == .supported,
          validated.inventory.map({ $0.systemStoreIdentifier == package.storeIdentifier }) ?? true,
          validated.plan.map({
            $0.planDigest == package.planDigest && $0.deviceIdentifier == package.deviceIdentifier
              && $0.storeIdentifier == package.storeIdentifier
              && ["free", "resize"].contains($0.candidateKind)
          }) ?? true
        else { throw NativeInstallAdmissionError.invalidJournal }
        if records.count > 3 {
          try requireRecordedResume(records, readEvidence: readEvidence)
          return
        }
      }
      let current = try collect()
      guard current.deviceIdentifier == package.deviceIdentifier,
        current.storeIdentifier == package.storeIdentifier
      else { throw NativeInstallAdmissionError.deviceChanged }
      guard current.knownInstallations.isEmpty else {
        throw NativeInstallAdmissionError.existingInstallation
      }
    }

    private static func requireRecordedResume(
      _ records: [EngineContractEnvelope], readEvidence: (String) throws -> Data
    ) throws {
      let stages = [
        ("apfs_preparation_started", "apfs-target-prepared", "apfs_preparation"),
        ("stub_and_esp_started", "stub-and-esp-installed", "stub_and_esp"),
        ("recovery_handoff_started", "recovery-handoff-prepared", "awaiting_recovery"),
      ]
      var cursor = 3
      for (index, stage) in stages.enumerated() {
        // Completed stage prefixes can resume; the first launch cannot.
        if cursor == records.count, index > 0 { return }
        guard cursor < records.count, case .event(let event) = records[cursor].message,
          event.name == stage.0
        else { throw NativeInstallAdmissionError.invalidJournal }
        cursor += 1
        // Recovery authorization can be retried after both disk stages have
        // durable evidence. An interrupted disk-stage intent is ambiguous.
        if cursor == records.count, index == 2 { return }
        guard cursor < records.count, case .checkpoint(let checkpoint) = records[cursor].message,
          checkpoint.identifier == stage.1, checkpoint.phase == stage.2,
          let bytes = try? readEvidence(checkpoint.identifier),
          SHA256Digest(hashing: bytes).rawValue == checkpoint.evidenceDigest
        else { throw NativeInstallAdmissionError.invalidJournal }
        cursor += 1
      }
      if cursor == records.count { return }
      guard cursor + 1 == records.count,
        case .completion(let completion) = records[cursor].message,
        completion.outcome == "awaiting_recovery"
      else { throw NativeInstallAdmissionError.invalidJournal }
    }

    static func provesNoMutation(_ bytes: Data) -> Bool {
      if bytes.isEmpty { return true }
      guard let records = try? EngineTranscriptDecoder().decode(bytes),
        case .inspection = records.first?.message
      else { return false }
      return records.allSatisfy {
        switch $0.message {
        case .inspection, .inventory, .plan: true
        default: false
        }
      }
    }
  }
#endif
