#if os(macOS)
  import Darwin
  import Foundation

  /// A fresh install that stopped right after it created its startup
  /// container: that container, directly after macOS, is all it left.
  struct RemovalPartialInstallation: Codable, Equatable, Sendable {
    let name: String
    let stub: RemovalPartition
    /// The binding of the installer journal that created the container.
    let journal: String
  }

  /// The installer's own journals. A partial install never got as far as the
  /// files removal otherwise checks, so only its journal can prove it is ours.
  protocol RemovalInstallJournals: Sendable {
    /// The one journal that created exactly this startup container and went
    /// no further; nil when none did.
    func creator(of stub: RemovalPartition, in snapshot: RemovalSnapshot) throws -> String?
    /// The one fresh-install journal that created exactly this installation's
    /// startup container, EFI partition and Linux partitions and installed
    /// them; nil when none did. The native installer keeps this record instead
    /// of the asahi installer's `asahi/installer.log` and m1n1 step-2 object.
    func installer(of installation: RemovalInstallation, in snapshot: RemovalSnapshot) throws
      -> String?
  }

  extension RemovalInstallJournals {
    func installer(of installation: RemovalInstallation, in snapshot: RemovalSnapshot) throws
      -> String?
    { nil }
  }

  struct NativeRemovalInstallJournals: RemovalInstallJournals {
    let workingDirectory: URL
    var owner: uid_t = 0

    func creator(of stub: RemovalPartition, in snapshot: RemovalSnapshot) throws -> String? {
      try journal(naming: stub.identifier) { transcript, evidence in
        Self.created(stub, transcript: transcript, snapshot: snapshot, evidence: evidence)
      }
    }

    func installer(of installation: RemovalInstallation, in snapshot: RemovalSnapshot) throws
      -> String?
    {
      try journal(naming: installation.stub.identifier) { transcript, evidence in
        Self.installed(
          installation, transcript: transcript, snapshot: snapshot, evidence: evidence)
      }
    }

    /// The binding of the one released journal `proves` accepts.
    private func journal(
      naming identifier: String,
      where proves: (Data, (String) throws -> Data) -> Bool
    ) throws -> String? {
      let directory = workingDirectory.appendingPathComponent(
        "execution-journals", isDirectory: true)
      guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0.range(of: #"\A[a-f0-9]{64}\.jsonl\z"#, options: .regularExpression) != nil
      }
      guard names.count <= 128 else {
        throw RemovalFailure(
          message: "Too many installation records need review. Nothing was changed.")
      }
      let tree = try NativeHandoffFileTree(directory, protected: true, owner: owner)
      var found = [String]()
      for name in names {
        let transcript = try tree.read(name, maximum: 4 << 20)
        guard
          proves(transcript, { try tree.read(name + "." + $0 + ".evidence", maximum: 1 << 20) }),
          Self.released(directory.appendingPathComponent(name), owner: owner)
        else { continue }
        found.append(String(name.dropLast(".jsonl".count)))
      }
      guard found.count <= 1 else {
        throw RemovalFailure(
          message:
            "More than one installation record names the startup container \(identifier). Nothing was changed."
        )
      }
      return found.first
    }

    /// The fields of `stub-and-esp-installed` that name what was installed.
    private struct InstalledRecord: Decodable {
      struct Part: Decodable {
        let name: String
        let partitionUUID: String
        let partitionSizeBytes: UInt64
        enum CodingKeys: String, CodingKey {
          case name
          case partitionUUID = "partition_uuid"
          case partitionSizeBytes = "partition_size_bytes"
        }
      }
      let planDigest: String
      let group: String
      let efiPartition: String
      let parts: [Part]
      enum CodingKeys: String, CodingKey {
        case planDigest = "plan_digest"
        case group = "apfs_vgid"
        case efiPartition = "efi_partition"
        case parts = "populated_partitions"
      }
    }

    /// A fresh install whose digest-bound checkpoints prepared exactly this
    /// startup container and then installed exactly this EFI partition and
    /// these Boot and Root partitions into that container's volume group.
    /// Its later Recovery step, and a Reset Linux that rewrote the images in
    /// place, leave every one of these identities unchanged.
    static func installed(
      _ installation: RemovalInstallation, transcript: Data, snapshot: RemovalSnapshot,
      evidence: (String) throws -> Data
    ) -> Bool {
      func checked(_ identifier: String, in checkpoints: [ValidatedEngineCheckpoint]) -> Data? {
        guard let checkpoint = checkpoints.first(where: { $0.identifier == identifier }),
          let bytes = try? evidence(identifier),
          SHA256Digest(hashing: bytes).rawValue == checkpoint.evidenceDigest
        else { return nil }
        return bytes
      }
      let linux = installation.linux.sorted { $0.offset < $1.offset }
      guard let validated = try? AppleInstallerTrustCore().validateEngineTranscript(transcript),
        let plan = validated.plan, ["free", "resize"].contains(plan.candidateKind),
        plan.storeIdentifier == snapshot.disk,
        validated.checkpoints.first?.identifier == "apfs-target-prepared",
        let targetBytes = checked("apfs-target-prepared", in: validated.checkpoints),
        let target = try? NativeAPFSTargetEvidence.read(targetBytes),
        target.planDigest == plan.planDigest, target.uuid == installation.stub.uuid,
        target.offsetBytes == installation.stub.offset,
        target.sizeBytes == installation.stub.size,
        let installedBytes = checked("stub-and-esp-installed", in: validated.checkpoints),
        let record = try? JSONDecoder().decode(InstalledRecord.self, from: installedBytes),
        record.planDigest == plan.planDigest, let group = installation.system.group,
        record.group.uppercased() == group.uppercased(),
        record.efiPartition.uppercased() == installation.esp.uuid.uppercased(),
        linux.count == 2, record.parts.map(\.name) == ["EFI", "Boot", "Root"]
      else { return false }
      return zip(record.parts, [installation.esp] + linux).allSatisfy { recorded, live in
        recorded.partitionUUID.uppercased() == live.uuid.uppercased()
          && recorded.partitionSizeBytes == live.size
      }
    }

    /// The journal is a fresh install whose only checkpoint prepared exactly
    /// this partition, and the volumes it recorded are the ones there now.
    static func created(
      _ stub: RemovalPartition, transcript: Data, snapshot: RemovalSnapshot,
      evidence: (String) throws -> Data
    ) -> Bool {
      guard let validated = try? AppleInstallerTrustCore().validateEngineTranscript(transcript),
        let plan = validated.plan, ["free", "resize"].contains(plan.candidateKind),
        plan.storeIdentifier == snapshot.disk, validated.completion == nil,
        validated.checkpoints.map(\.identifier) == ["apfs-target-prepared"],
        let targetBytes = try? evidence("apfs-target-prepared"),
        SHA256Digest(hashing: targetBytes).rawValue == validated.checkpoints[0].evidenceDigest,
        let target = try? NativeAPFSTargetEvidence.read(targetBytes),
        target.planDigest == plan.planDigest, target.uuid == stub.uuid,
        target.offsetBytes == stub.offset, target.sizeBytes == stub.size,
        let volumesBytes = try? evidence(NativeStubVolumes.evidenceIdentifier),
        let volumes = try? NativeStubVolumes.read(volumesBytes),
        (try? volumes.validate(plan: plan.planDigest, target: stub, snapshot: snapshot)) != nil
      else { return false }
      return true
    }

    /// No process still holds the journal's lease.
    static func released(_ journal: URL, owner: uid_t) -> Bool {
      let descriptor = open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == owner, flock(descriptor, LOCK_EX | LOCK_NB) == 0
      else { return false }
      _ = flock(descriptor, LOCK_UN)
      return true
    }
  }
#endif
