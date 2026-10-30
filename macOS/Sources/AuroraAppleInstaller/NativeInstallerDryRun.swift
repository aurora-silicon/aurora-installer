#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// A recorded description of one Mac, as the native inspection would see it:
  /// identity, boot firmware versions and the internal disk graph. Fixtures are
  /// captured read-only from real machines and replayed here without any disk,
  /// helper, network or Recovery authority.
  public struct NativeInstallerDryRunMachine: Decodable, Sendable {
    let deviceIdentifier: String
    let hardware: NativeInspectionHardware
    let snapshot: RemovalSnapshot
    let containers: [NativeContainerFacts]
  }

  /// Runs the same inspection, firmware selection, planning and boot-chain
  /// admission code an installation uses, against a recorded machine and an
  /// authenticated payload's metadata. It returns what the installer would do
  /// and never does any of it.
  public enum NativeInstallerDryRun {
    /// `experimental` replays the owner's opt-in for a Mac this release does
    /// not support: the same inspection, planner and 1TR step, run against the
    /// policy the experimental assessment widens for this one Mac.
    public static func run(
      machine machineData: Data, metadata: Data, payloadDigest: String,
      archive: IPSWArchive?, experimental: ExperimentalHardwareLevel? = nil
    ) async throws -> Data {
      let machine = try JSONDecoder().decode(NativeInstallerDryRunMachine.self, from: machineData)
      var policy = try NativeInspectionPolicy.sealed()
      let device = machine.deviceIdentifier
      var result: [String: Any] = [
        "schema": 1, "device_identifier": device,
        "policy_runtime": policy.runtimeVersion,
      ]
      var supported =
        !AppleSiliconHostInspector.isExplicitlyUnsupported(device)
        && policy.supports(device, hardware: machine.hardware)
      var assessment: NativeExperimentalAssessment?
      var admission: ExperimentalAdmissionRecord?
      if let experimental {
        var row: [String: Any] = ["requested_level": experimental.rawValue]
        switch NativeExperimentalHardware.refusal(
          device, hardware: machine.hardware, policy: policy)
        {
        case .supported?:
          row["offered"] = false
          row["refusal"] = "supported Mac: the experimental path is never offered"
        case .some(let other):
          row["offered"] = false
          row["refusal"] = String(describing: other)
        case nil:
          row["offered"] = true
          do {
            // The app's decision, the record the plan binds, then the helper's
            // own re-run of the decision against that record.
            let installation = try NativeInstallationMetadata(data: metadata)
            let chosen = try NativeExperimentalHardware.assess(
              device, hardware: machine.hardware, policy: policy, metadata: installation,
              level: experimental)
            let record = NativeDeviceAdmission.record(chosen)
            let verified = try NativeDeviceAdmission.verify(
              ExperimentalAdmissionRecord.decode(record.canonical), deviceIdentifier: device,
              hardware: machine.hardware, policy: policy, metadata: installation)
            assessment = verified
            admission = record
            policy = verified.policy
            supported = true
            row["stub_firmware"] = verified.firmwareVersion
            row["warnings"] = verified.warnings
            row["admission_record"] = record.canonical
            row["helper_recheck"] = "agrees"
          } catch {
            row["refusal"] = String(describing: error)
          }
        }
        result["experimental"] = row
      }
      result["supported"] = supported
      result["one_true_recovery_boot_policy"] = RecoveryBootPolicyArguments.bootPolicy(
        deviceIdentifier: device)
      guard supported else {
        result["unsupported_reason"] =
          AppleSiliconHostInspector.isExplicitlyUnsupported(device)
          ? "explicitly refused model"
          : policy.devices[String(device.dropFirst(6))] == nil
            ? "model not in the inspection policy"
            : policy.chipMinimum[String(machine.hardware.chipID)] == nil
              ? "chip not in the inspection policy" : "expert-only model"
        return try encode(result)
      }
      let installation = try NativeInstallationMetadata(data: metadata)
      let stub = try policy.stubBytes(device, hardware: machine.hardware, metadata: installation)
      result["inspection_stub_bytes"] = stub
      var firmware: NativeFirmwareSelection?
      do {
        firmware = try NativeFirmwareSelection.choose(
          deviceIdentifier: device,
          facts: .init(deviceIdentifier: device, hardware: machine.hardware),
          metadata: installation, policy: policy, experimental: assessment != nil)
        result["firmware"] = [
          "version": firmware!.version, "source_url": firmware!.sourceURL.absoluteString,
          "stub_bytes": firmware!.stubBytes,
        ]
      } catch {
        result["firmware_error"] = String(describing: error)
      }
      let transcript = try NativeDiskInventory.transcript(
        device: device, snapshot: machine.snapshot, containers: machine.containers,
        metadata: installation, stubBytes: stub)
      let inspection = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
      guard let inventory = inspection.inventory else {
        throw NativeInspectionError.invalidLayout
      }
      let identity = try PinnedAsahiPlanIdentity(
        engineVersion: "native-v1", engineDigest: SHA256Digest(hashing: Data()).rawValue,
        metadataDigest: SHA256Digest(hashing: metadata).rawValue, payloadDigest: payloadDigest)
      var candidates = [[String: Any]]()
      for candidate in inventory.candidates {
        var row: [String: Any] = [
          "kind": candidate.kind, "source": candidate.sourceIdentifier,
          "offset_bytes": candidate.offsetBytes, "length_bytes": candidate.lengthBytes,
          "minimum_install_bytes": candidate.minimumInstallBytes,
          "minimum_container_bytes": candidate.minimumContainerBytes,
        ]
        if let bytes = candidate.recommendedInstallBytes {
          row["recommended_install_bytes"] = bytes
        }
        do {
          let length = try requestedLength(candidate)
          let request = try PinnedAsahiPlanRequest(
            inventory: inventory, candidate: candidate, requestedLengthBytes: length)
          let planned = try NativeInstallerPlanner.transcript(
            inspection: inspection, request: request, identity: identity,
            experimental: admission)
          guard let plan = try AppleInstallerTrustCore().validateEngineTranscript(planned).plan
          else { throw NativeInstallerPlanningError.inspectionRequired }
          var planRow: [String: Any] = [
            "offset_bytes": plan.offsetBytes, "length_bytes": plan.lengthBytes,
            "required_human_steps": plan.requiredHumanSteps, "plan_digest": plan.planDigest,
          ]
          if let bound = plan.experimentalAdmission {
            planRow["experimental_admission"] = bound
            // The same plan without the record: the digest must differ.
            let unbound = try NativeInstallerPlanner.transcript(
              inspection: inspection, request: request, identity: identity)
            planRow["unbound_plan_digest"] =
              try AppleInstallerTrustCore().validateEngineTranscript(unbound).plan?.planDigest
          }
          if let firmware, plan.lengthBytes > firmware.stubBytes {
            let available = NativeInspectionMath.alignDown(plan.lengthBytes - firmware.stubBytes)
            planRow["stub_bytes"] = firmware.stubBytes
            planRow["os_partitions"] = try NativeOSPartitionPlan(
              metadata: metadata, available: available
            ).parts.map {
              ["name": $0.name, "type": $0.type, "bytes": $0.bytes] as [String: Any]
            }
          }
          row["plan"] = planRow
        } catch {
          row["plan_error"] = String(describing: error)
        }
        candidates.append(row)
      }
      result["candidates"] = candidates
      result["known_installations"] = try NativeKnownInstallations.recognize(
        NativeCollectedDisk(snapshot: machine.snapshot, containers: machine.containers)
      ).map {
        [
          "source": $0.sourceIdentifier, "offset_bytes": $0.offsetBytes,
          "length_bytes": $0.lengthBytes,
        ]
      }
      if let archive, firmware != nil, let assessment {
        do {
          let boot = try await NativeExperimentalBootChain.admit(
            metadata: metadata, archive: archive, assessment: assessment)
          var source: [String: Any] = ["kind": "none"]
          switch boot.stage2 {
          case .own(let member): source = ["kind": "own", "member": member]
          case .sibling(let board, let member):
            source = ["kind": "sibling", "board": "apple," + board, "member": member]
          case .none: break
          }
          var espFiles: Any = NSNull()
          do {
            if let plan = try await NativeESPPayloadPlan.make(
              metadata: metadata, archive: archive, device: device,
              firmware: assessment.firmwareVersion, experimental: assessment)
            {
              espFiles =
                [
                  "members": plan.entries.map(\.path).sorted(),
                  "extra_files": plan.extraFiles.keys.sorted(),
                  "window_milliseconds": plan.windowMilliseconds,
                ] as [String: Any]
            }
          } catch {
            espFiles = ["error": String(describing: error)]
          }
          result["boot_chain"] =
            [
              "esp_plan": espFiles,
              "esp_layout": boot.espLayout, "window_milliseconds": 0,
              "stage1_member": boot.stage1Member, "stage1_bytes": boot.stage1Bytes,
              "stage1_sha256": boot.stage1SHA256, "stage2_source": source,
              "stage2_bytes": boot.stage2Bytes, "stage2_sha256": boot.stage2SHA256,
              "stage2_trees": boot.stage2Trees,
              "extra_files": boot.extraFiles.keys.sorted(), "level": boot.assessment.level.rawValue,
              "notes": boot.notes,
              "record":
                (try? JSONSerialization.jsonObject(
                  with: boot.extraFiles[NativeExperimentalHardware.recordPath] ?? Data()))
                ?? NSNull(),
            ] as [String: Any]
        } catch {
          result["boot_chain_error"] = String(describing: error)
        }
      } else if let archive, let firmware {
        do {
          let boot = try await NativeBootChain.admit(
            metadata: metadata, archive: archive, deviceIdentifier: device,
            firmware: firmware.version)
          var chain: [String: Any] = [
            "esp_layout": boot.espLayout, "window_milliseconds": boot.windowMilliseconds,
          ]
          if let member = boot.stage1Member,
            let stage = archive.members.first(where: { $0.name == member })
          {
            let bytes = try await archive.read(stage, maximumBytes: 64 << 20)
            let filled = try NativeBootChain.fillStage1(
              bytes, uuid: "00000000-0000-4000-8000-000000000001", path: "m1n1/boot.bin",
              windowMilliseconds: boot.windowMilliseconds)
            chain["stage1_member"] = member
            chain["stage1_bytes"] = filled.count
            chain["stage1_sha256"] = SHA256Digest(hashing: bytes).rawValue
          }
          result["boot_chain"] = chain
        } catch {
          result["boot_chain_error"] = String(describing: error)
        }
      }
      return try encode(result)
    }

    /// The installer offers the recommended size when it fits and otherwise
    /// the smallest admissible one, rounded to the plan's allocation unit.
    static func requestedLength(_ candidate: ValidatedEngineCandidate) throws -> UInt64 {
      let unit = PinnedAsahiPlanRequest.allocationUnitBytes
      if ["repair", "replace", "reinstall"].contains(candidate.kind) {
        return candidate.lengthBytes
      }
      let maximum =
        candidate.kind == "resize"
        ? candidate.lengthBytes > candidate.minimumContainerBytes
          ? candidate.lengthBytes - candidate.minimumContainerBytes : 0
        : candidate.lengthBytes
      let wanted = candidate.recommendedInstallBytes ?? candidate.minimumInstallBytes
      let chosen = min(max(wanted, candidate.minimumInstallBytes), maximum)
      return chosen / unit * unit
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
      try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
  }

  /// The paired Recovery commands each Mac's enrollment runs. The Recovery app
  /// receives the boot-policy choice through its install configuration.
  public enum RecoveryBootPolicyArguments {
    /// Only the MacBook Neo opts in to custom boot arguments (`bputil -nca`).
    public static func allowsCustomBootArguments(deviceIdentifier: String) -> Bool {
      deviceIdentifier == "apple,j700"
    }

    public static func bootPolicy(deviceIdentifier: String) -> [String] {
      [allowsCustomBootArguments(deviceIdentifier: deviceIdentifier) ? "-nca" : "-nc"]
    }
  }
#endif
