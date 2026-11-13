#if os(macOS)
  import Foundation

  /// The parts of slot creation that don't touch a disk: the plan's identity,
  /// the slot's Recovery inputs and the operation's journal.
  extension NativeStartupFirmwareSlot {
    enum ExecutionError: Error, Equatable, Sendable {
      /// The installation's Recovery inputs aren't the shape the installer
      /// wrote, or they name another EFI partition.
      case changedInstallation
      /// The slot's volumes aren't the ones the plan created.
      case changedSlot
      /// The journal doesn't belong to this plan, or its records are out of
      /// order.
      case changedJournal
      /// A step was recorded before the one the plan puts first.
      case outOfOrder(expected: Int, recorded: Int)
      /// Completion was asked for while a step the installer takes is left.
      case unfinished(next: Int)
    }

    // MARK: Plan identity

    /// The plan with the installation it was made for, as canonical JSON.
    /// The journal records its digest, so a resumed operation can only
    /// continue the plan it started.
    static func canonical(_ plan: Plan, installation: Installation) throws -> Data {
      var placement: [String: Any]
      switch plan.placement {
      case .free(let extent):
        placement = ["kind": "free", "offset": extent.offset, "size": extent.size]
      case .shrinkMacOS(let bytes):
        placement = ["kind": "shrink_macos", "bytes": bytes]
      }
      let object: [String: Any] = [
        "schema": 1, "build": plan.build, "version": plan.version, "title": plan.title,
        "bytes": plan.bytes, "placement": placement,
        "firmware_directory": plan.firmwareDirectory,
        "steps": plan.steps.map(\.record),
        "installation": [
          "title": installation.title, "esp_uuid": installation.espUUID.uppercased(),
          "stub_bytes": installation.stubBytes, "end_offset": installation.endOffset,
          "build": installation.build ?? "", "version": installation.version ?? "",
        ] as [String: Any],
      ]
      return try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func digest(_ plan: Plan, installation: Installation) throws -> String {
      SHA256Digest(hashing: try canonical(plan, installation: installation)).rawValue
    }

    // MARK: Recovery inputs

    /// The volumes the container step created, as `diskutil` reports them.
    struct SlotVolumes: Equatable, Sendable {
      let title: String
      let systemUUID: String
      let groupUUID: String
      let prebootUUID: String
    }

    struct RecoveryInputs: Equatable, Sendable {
      /// `install-config.json` for the slot's System volume.
      let configuration: Data
      /// `AuraPayloads/manifest.json`, byte for byte the installation's: the
      /// slot enrolls the Stage 1 the installation already enrolled.
      let manifest: Data
    }

    /// The slot's Recovery inputs, made from the installation's own.
    ///
    /// Only the volume identity changes: the slot's name, System, group and
    /// Preboot UUIDs. The EFI partition, boot mode, Stage 2 path and
    /// bootstrap stay the installation's, so the slot's Recovery enrolls the
    /// same Stage 1 and it starts the same Stage 2.
    static func recoveryInputs(
      configuration: Data, manifest: Data, installation: Installation, slot: SlotVolumes,
      plan: Plan
    ) throws -> RecoveryInputs {
      let required: Set<String> = [
        "schema", "volumeName", "systemUUID", "groupUUID", "prebootUUID", "espUUID",
        "bootMode", "stage2Path", "bootstrap",
      ]
      guard configuration.count <= 65_536, manifest.count <= 1 << 20,
        var config = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
        Set(config.keys).subtracting(["allowCustomBootArguments"]) == required,
        config["schema"] as? Int == 2,
        let esp = config["espUUID"] as? String,
        esp.uppercased() == installation.espUUID.uppercased(),
        (config["bootMode"] as? String).flatMap(NativeRecoveryBootMode.init(recorded:)) != nil,
        config["stage2Path"] is String, config["bootstrap"] != nil
      else { throw ExecutionError.changedInstallation }
      let installed = Set(
        ["systemUUID", "groupUUID", "prebootUUID"].compactMap { config[$0] as? String })
      guard installed.count == 3 else { throw ExecutionError.changedInstallation }
      guard let payloads = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
        payloads["schema"] as? Int == 2,
        let files = payloads["files"] as? [String: [String: Any]],
        ["raw/aura-raw.bin", "raw/boot.bin", "macho/aura-boot.macho"].allSatisfy({
          files[$0]?["sha256"] is String
        })
      else { throw ExecutionError.changedInstallation }
      let fresh = [slot.systemUUID, slot.groupUUID, slot.prebootUUID]
      guard slot.title == plan.title, (try? fresh.map(NativeSourceBootstrap.uuid)) != nil,
        Set(fresh).count == 3, Set(fresh).isDisjoint(with: installed)
      else { throw ExecutionError.changedSlot }
      config["volumeName"] = slot.title
      config["systemUUID"] = slot.systemUUID
      config["groupUUID"] = slot.groupUUID
      config["prebootUUID"] = slot.prebootUUID
      return RecoveryInputs(
        configuration: try JSONSerialization.data(
          withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]),
        manifest: manifest)
    }

    // MARK: Journal

    /// The operation's own journal: one plan record, then one record per step
    /// the installer finished, in plan order, then completion. Each line is a
    /// JSON object with `schema_version`, `sequence`, `type` and `payload`.
    /// The owner's enrollment is never recorded: it happens in Recovery.
    enum Journal {
      struct Progress: Equatable, Sendable {
        let planDigest: String
        /// How many of the plan's steps are done, from the first.
        let done: Int
        let completed: Bool
        let sequence: Int

        /// The next step the installer takes, or nil when only the owner's is left.
        func next(in plan: Plan) -> Int? {
          done < plan.steps.count && !plan.steps[done].byOwner ? done : nil
        }
      }

      static func start(_ plan: Plan, installation: Installation) throws -> Data {
        try line(
          1, "plan",
          [
            "plan_digest": try digest(plan, installation: installation), "build": plan.build,
            "title": plan.title, "esp_uuid": installation.espUUID.uppercased(),
          ])
      }

      /// Reads a journal for `plan`; anything else in it is a refusal.
      static func read(_ data: Data, plan: Plan, installation: Installation) throws -> Progress {
        let expected = try digest(plan, installation: installation)
        guard data.count <= 1 << 20, data.last == 10 else { throw ExecutionError.changedJournal }
        var done = 0
        var completed = false
        var sequence = 0
        for raw in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
          guard !completed,
            let record = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
            Set(record.keys) == ["schema_version", "sequence", "type", "payload"],
            record["schema_version"] as? Int == 1, record["sequence"] as? Int == sequence + 1,
            let type = record["type"] as? String,
            let payload = record["payload"] as? [String: Any],
            payload["plan_digest"] as? String == expected
          else { throw ExecutionError.changedJournal }
          sequence += 1
          switch (sequence, type) {
          case (1, "plan"):
            guard payload["build"] as? String == plan.build,
              payload["title"] as? String == plan.title,
              payload["esp_uuid"] as? String == installation.espUUID.uppercased()
            else { throw ExecutionError.changedJournal }
          case (2..., "step"):
            guard let index = payload["index"] as? Int,
              let step = payload["step"] as? [String: Any],
              let evidence = payload["evidence_digest"] as? String,
              SHA256Digest(rawValue: evidence) != nil
            else { throw ExecutionError.changedJournal }
            guard index == done else {
              throw ExecutionError.outOfOrder(expected: done, recorded: index)
            }
            guard index < plan.steps.count, !plan.steps[index].byOwner,
              NSDictionary(dictionary: step).isEqual(to: plan.steps[index].record)
            else { throw ExecutionError.changedJournal }
            done += 1
          case (2..., "completion"):
            guard payload["outcome"] as? String == "awaiting_recovery",
              Progress(planDigest: expected, done: done, completed: false, sequence: sequence)
                .next(in: plan) == nil
            else { throw ExecutionError.changedJournal }
            completed = true
          default:
            throw ExecutionError.changedJournal
          }
        }
        guard sequence >= 1 else { throw ExecutionError.changedJournal }
        return Progress(planDigest: expected, done: done, completed: completed, sequence: sequence)
      }

      /// The record for the plan's next step, with the digest of what it left
      /// on disk (a container's UUIDs, a stub's file list, Recovery's inputs).
      static func step(_ progress: Progress, plan: Plan, evidence: Data) throws -> Data {
        guard !progress.completed, let index = progress.next(in: plan) else {
          throw ExecutionError.changedJournal
        }
        return try line(
          progress.sequence + 1, "step",
          [
            "plan_digest": progress.planDigest, "index": index,
            "step": plan.steps[index].record,
            "evidence_digest": SHA256Digest(hashing: evidence).rawValue,
          ])
      }

      /// The last record: everything the installer does is done and the slot
      /// waits for the owner's enrollment.
      static func completion(_ progress: Progress, plan: Plan) throws -> Data {
        guard !progress.completed else { throw ExecutionError.changedJournal }
        if let next = progress.next(in: plan) { throw ExecutionError.unfinished(next: next) }
        return try line(
          progress.sequence + 1, "completion",
          ["plan_digest": progress.planDigest, "outcome": "awaiting_recovery"])
      }

      private static func line(_ sequence: Int, _ type: String, _ payload: [String: Any]) throws
        -> Data
      {
        var data = try JSONSerialization.data(
          withJSONObject: [
            "schema_version": 1, "sequence": sequence, "type": type, "payload": payload,
          ], options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
      }
    }
  }

  extension NativeStartupFirmwareSlot.Step {
    /// The step as the plan digest and the journal spell it.
    var record: [String: Any] {
      switch self {
      case .shrinkMacOS(let bytes): ["kind": "shrink_macos", "bytes": bytes]
      case .createContainer(let bytes, let title):
        ["kind": "create_container", "bytes": bytes, "title": title]
      case .restoreStub(let build, let version):
        ["kind": "restore_stub", "build": build, "version": version]
      case .stageRecovery(let espUUID):
        ["kind": "stage_recovery", "esp_uuid": espUUID.uppercased()]
      case .writeSlotFirmware(let directory):
        ["kind": "write_slot_firmware", "directory": directory]
      case .enrollInRecovery(let title): ["kind": "enroll_in_recovery", "title": title]
      }
    }
  }
#endif
