#if os(macOS)
  import Foundation

  public enum NativeInstallerPlanningError: Error, Equatable, Sendable {
    case inspectionRequired
    case inventoryChanged
    case candidateUnavailable
    case extentOverflow
    case invalidIdentity
  }

  /// Constructs the existing plan contract from a fresh validated inspection.
  /// It has no process, filesystem, network or approval authority. The resulting
  /// transcript still passes the same review and catalog-bound execution gates.
  public struct NativeInstallerPlanner: InstallerPlanExecuting {
    public init() {}

    public func plan(
      inspection: ValidatedEngineTranscript,
      request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity
    ) async throws -> Data {
      try Task.checkCancellation()
      let result = try Self.transcript(inspection: inspection, request: request, identity: identity)
      try Task.checkCancellation()
      return result
    }

    static func transcript(
      inspection: ValidatedEngineTranscript,
      request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity
    ) throws -> Data {
      guard inspection.support == .supported, inspection.plan == nil,
        inspection.checkpoints.isEmpty, inspection.completion == nil,
        let inventory = inspection.inventory
      else { throw NativeInstallerPlanningError.inspectionRequired }
      guard request.layoutDigest == inventory.layoutDigest else {
        throw NativeInstallerPlanningError.inventoryChanged
      }
      let matches = inventory.candidates.filter {
        $0.kind == request.candidateKind && $0.sourceIdentifier == request.sourceIdentifier
      }
      guard matches.count == 1, let candidate = matches.first else {
        throw NativeInstallerPlanningError.candidateUnavailable
      }
      // Recheck the requested extent against this inspection, not the inventory
      // that originally produced the request during a possibly earlier replan.
      _ = try PinnedAsahiPlanRequest(
        inventory: inventory, candidate: candidate,
        requestedLengthBytes: request.requestedLengthBytes)
      guard (candidate.kind == "repair") == (identity.repairManifestDigest != nil) else {
        throw NativeInstallerPlanningError.invalidIdentity
      }
      let (end, overflow) = candidate.offsetBytes.addingReportingOverflow(candidate.lengthBytes)
      guard !overflow else { throw NativeInstallerPlanningError.extentOverflow }
      let offset = candidate.kind == "resize" ? end - request.requestedLengthBytes : candidate.offsetBytes
      let steps = candidate.kind == "repair"
        ? ["authenticateMachineOwner"] : ["enterOneTrueRecovery", "authenticateMachineOwner"]
      var fields = [
        inspection.deviceIdentifier, inventory.systemStoreIdentifier, inventory.layoutDigest,
        candidate.kind, candidate.sourceIdentifier, String(offset), String(request.requestedLengthBytes),
        identity.engineVersion, identity.engineDigest, identity.metadataDigest, identity.payloadDigest,
      ]
      if let repair = identity.repairManifestDigest { fields.append(repair) }
      fields.append(steps.joined(separator: ","))
      var plan: [String: Any] = [
        "plan_digest": InstallerDigest.lengthPrefixedSHA256(fields).hexadecimal,
        "device_identifier": inspection.deviceIdentifier,
        "store_identifier": inventory.systemStoreIdentifier,
        "layout_digest": inventory.layoutDigest,
        "candidate_kind": candidate.kind, "source_identifier": candidate.sourceIdentifier,
        "offset_bytes": offset, "length_bytes": request.requestedLengthBytes,
        "engine_version": identity.engineVersion, "engine_digest": identity.engineDigest,
        "metadata_digest": identity.metadataDigest, "payload_digest": identity.payloadDigest,
        "required_human_steps": steps,
      ]
      if let repair = identity.repairManifestDigest { plan["repair_manifest_digest"] = repair }
      let inventoryPayload: [String: Any] = [
        "layout_digest": inventory.layoutDigest,
        "system_store_identifier": inventory.systemStoreIdentifier,
        "candidates": inventory.candidates.map(candidatePayload),
      ]
      var transcript = Data()
      for (index, row) in [
        ("inspection", ["device_identifier": inspection.deviceIdentifier, "support": "supported"] as [String: Any]),
        ("inventory", inventoryPayload), ("plan", plan),
      ].enumerated() {
        let record: [String: Any] = [
          "schema_version": 1, "sequence": index + 1, "type": row.0, "payload": row.1,
        ]
        transcript.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        transcript.append(10)
      }
      // The shared strict decoder also checks inventory identity and plan math;
      // native construction never bypasses those independent validation rules.
      _ = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
      return transcript
    }

    private static func candidatePayload(_ candidate: ValidatedEngineCandidate) -> [String: Any] {
      var result: [String: Any] = [
        "kind": candidate.kind, "source_identifier": candidate.sourceIdentifier,
        "offset_bytes": candidate.offsetBytes, "length_bytes": candidate.lengthBytes,
        "minimum_install_bytes": candidate.minimumInstallBytes,
        "minimum_container_bytes": candidate.minimumContainerBytes,
      ]
      if let digest = candidate.identityDigest { result["identity_digest"] = digest }
      if let bytes = candidate.recommendedInstallBytes { result["recommended_install_bytes"] = bytes }
      if let bytes = candidate.recommendedContainerBytes { result["recommended_container_bytes"] = bytes }
      return result
    }
  }
#endif
