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

  struct NativePreservedESPBaseline: Codable, Equatable, Sendable {
    let member: String
    let path: String
    let previous: NativeStubFileIdentity?
    let installed: NativeStubFileIdentity

    func validate() throws {
      guard NativeESPPayloadPlan.safeFATPath(path), !member.isEmpty,
        installed.bytes > 0, installed.bytes <= 64 << 20,
        SHA256Digest(hexadecimal: installed.sha256) != nil,
        previous.map({
          $0.bytes > 0 && $0.bytes <= 64 << 20
            && SHA256Digest(hexadecimal: $0.sha256) != nil
        }) ?? true
      else { throw NativeRecoveryJournalError.invalidState }
    }
  }

  struct NativePreservedESPEntryReceipt: Codable, Equatable, Sendable {
    let member: String
    let path: String
    let installed: NativeStubFileIdentity
    let backup: NativeESPFileStore.ReplacementReceipt?

    func validate(baseline: NativePreservedESPBaseline) throws {
      try baseline.validate()
      guard member == baseline.member, path == baseline.path,
        installed == baseline.installed
      else { throw NativeRecoveryJournalError.invalidState }
      if let previous = baseline.previous, previous != installed {
        guard let backup, backup.path == path,
          backup.previous == previous, backup.installed == installed
        else { throw NativeRecoveryJournalError.invalidState }
      } else if backup != nil {
        throw NativeRecoveryJournalError.invalidState
      }
    }
  }

  /// The preserved ESP's FAT volume serial before and after the payload's
  /// volume ID is applied. The same record is the baseline and the receipt.
  struct NativePreservedESPVolumeID: Codable, Equatable, Sendable {
    let partitionUUID: String
    let previous: UInt32
    let installed: UInt32

    func validate() throws {
      guard UUID(uuidString: partitionUUID) != nil, partitionUUID == partitionUUID.lowercased()
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
      guard package.installationIntent == .reinstall else {
        throw NativeRecoveryJournalError.invalidState
      }
      return try decode(
        bytes, identity: InstallerJobPlanIdentity(package: package), evidence: evidence)
    }

    static func decode(
      _ bytes: Data, identity: InstallerJobPlanIdentity,
      evidence: (String) throws -> Data
    ) throws -> Self {
      let records = try EngineTranscriptDecoder().decode(bytes)
      let validated = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      guard validated.support == .supported,
        validated.deviceIdentifier == identity.deviceIdentifier,
        let plan = validated.plan, plan.candidateKind == "reinstall",
        let inventory = validated.inventory,
        inventory.candidates.filter({
          $0.kind == "reinstall" && $0.sourceIdentifier == plan.sourceIdentifier
        }).count == 1,
        let targetIdentity = inventory.candidates.first(where: {
          $0.kind == "reinstall" && $0.sourceIdentifier == plan.sourceIdentifier
        })?.identityDigest,
        plan.planDigest == identity.planDigest,
        plan.storeIdentifier == identity.storeIdentifier,
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
      } else {
        // Free-space advice can change after the first write. Resume only when
        // the reconstructed plan, layout and retained target still match.
        let saved = try snapshot()
        let records = try EngineTranscriptDecoder().decode(transcript)
        let refreshed = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
        guard records.count == 3, refreshed.plan == saved.plan,
          refreshed.inventory?.layoutDigest == saved.plan.layoutDigest,
          refreshed.inventory?.candidates.contains(where: {
            $0.kind == "reinstall" && $0.sourceIdentifier == saved.plan.sourceIdentifier
              && $0.identityDigest == saved.targetIdentity
          }) == true
        else { throw NativeRecoveryJournalError.changed }
      }
      _ = try snapshot()
    }

    func snapshot() throws -> NativePreservedInstallJournalSnapshot {
      try file.transaction { try current() }
    }

    /// Bind the owner-selected first-boot configuration before any target
    /// write. An interrupted attempt may resume only with the same choice.
    func bindInstallConf(_ configuration: InstallConf) throws {
      try file.transaction {
        let state = try current().state
        let bytes = configuration.serializedData
        if try file.containsEvidence("preserved-install-conf") {
          guard try file.readEvidence("preserved-install-conf") == bytes else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
        } else {
          guard state == .ready else { throw NativeRecoveryJournalError.invalidState }
          try file.publishEvidence(bytes, identifier: "preserved-install-conf")
        }
      }
    }

    func requireInstallConf(_ configuration: InstallConf) throws {
      try file.transaction {
        _ = try current()
        guard try file.readEvidence("preserved-install-conf") == configuration.serializedData
        else { throw NativeRecoveryJournalError.evidenceChanged }
      }
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

    func espBaseline(_ path: String) throws -> NativePreservedESPBaseline? {
      guard NativeESPPayloadPlan.safeFATPath(path) else {
        throw NativeRecoveryJournalError.invalidState
      }
      return try file.transaction {
        let before = try current()
        guard before.state != .ready else { throw NativeRecoveryJournalError.invalidState }
        let identifier = Self.espIdentifier("preserved-esp-old-", path: path)
        guard try file.containsEvidence(identifier) else { return nil }
        let baseline = try JSONDecoder().decode(
          NativePreservedESPBaseline.self, from: file.readEvidence(identifier))
        try baseline.validate()
        guard baseline.path == path else { throw NativeRecoveryJournalError.evidenceChanged }
        return baseline
      }
    }

    func recordESPBaseline(_ baseline: NativePreservedESPBaseline) throws {
      try baseline.validate()
      try file.transaction {
        guard try current().state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        try file.publishEvidence(
          Self.encode(baseline),
          identifier: Self.espIdentifier("preserved-esp-old-", path: baseline.path))
      }
    }

    func espReceipt(_ path: String) throws -> NativePreservedESPEntryReceipt? {
      guard NativeESPPayloadPlan.safeFATPath(path) else {
        throw NativeRecoveryJournalError.invalidState
      }
      return try file.transaction {
        guard try current().state != .ready else {
          throw NativeRecoveryJournalError.invalidState
        }
        let identifier = Self.espIdentifier("preserved-esp-new-", path: path)
        guard try file.containsEvidence(identifier) else { return nil }
        let baselineID = Self.espIdentifier("preserved-esp-old-", path: path)
        let baseline = try JSONDecoder().decode(
          NativePreservedESPBaseline.self, from: file.readEvidence(baselineID))
        let receipt = try JSONDecoder().decode(
          NativePreservedESPEntryReceipt.self, from: file.readEvidence(identifier))
        try receipt.validate(baseline: baseline)
        return receipt
      }
    }

    func recordESP(_ receipt: NativePreservedESPEntryReceipt) throws {
      try file.transaction {
        guard try current().state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        let baselineID = Self.espIdentifier("preserved-esp-old-", path: receipt.path)
        let baseline = try JSONDecoder().decode(
          NativePreservedESPBaseline.self, from: file.readEvidence(baselineID))
        try receipt.validate(baseline: baseline)
        try file.publishEvidence(
          Self.encode(receipt),
          identifier: Self.espIdentifier("preserved-esp-new-", path: receipt.path))
      }
    }

    func espVolumeIDBaseline() throws -> NativePreservedESPVolumeID? {
      try espVolumeID("preserved-esp-volume-id-old")
    }

    /// The previous serial is published before the first boot sector write.
    func recordESPVolumeIDBaseline(_ baseline: NativePreservedESPVolumeID) throws {
      try baseline.validate()
      try file.transaction {
        guard try current().state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        try file.publishEvidence(
          Self.encode(baseline), identifier: "preserved-esp-volume-id-old")
      }
    }

    func espVolumeIDReceipt() throws -> NativePreservedESPVolumeID? {
      guard let receipt = try espVolumeID("preserved-esp-volume-id-new") else { return nil }
      guard try espVolumeIDBaseline() == receipt else {
        throw NativeRecoveryJournalError.evidenceChanged
      }
      return receipt
    }

    func recordESPVolumeID(_ receipt: NativePreservedESPVolumeID) throws {
      try receipt.validate()
      try file.transaction {
        guard try current().state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        let baseline = try JSONDecoder().decode(
          NativePreservedESPVolumeID.self,
          from: file.readEvidence("preserved-esp-volume-id-old"))
        guard baseline == receipt else { throw NativeRecoveryJournalError.evidenceChanged }
        try file.publishEvidence(Self.encode(receipt), identifier: "preserved-esp-volume-id-new")
      }
    }

    private func espVolumeID(_ identifier: String) throws -> NativePreservedESPVolumeID? {
      try file.transaction {
        guard try current().state != .ready else {
          throw NativeRecoveryJournalError.invalidState
        }
        guard try file.containsEvidence(identifier) else { return nil }
        let saved = try JSONDecoder().decode(
          NativePreservedESPVolumeID.self, from: file.readEvidence(identifier))
        try saved.validate()
        return saved
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

    private static func encode<T: Encodable>(_ receipt: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(receipt)
    }

    private static func espIdentifier(_ prefix: String, path: String) -> String {
      prefix + NativeStubFileStore.hash(Data(path.utf8))
    }
  }
#endif
