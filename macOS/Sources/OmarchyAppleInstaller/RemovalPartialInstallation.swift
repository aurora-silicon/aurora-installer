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
  }

  struct NativeRemovalInstallJournals: RemovalInstallJournals {
    let workingDirectory: URL
    var owner: uid_t = 0

    func creator(of stub: RemovalPartition, in snapshot: RemovalSnapshot) throws -> String? {
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
          Self.created(
            stub, transcript: transcript, snapshot: snapshot,
            evidence: { try tree.read(name + "." + $0 + ".evidence", maximum: 1 << 20) }),
          Self.released(directory.appendingPathComponent(name), owner: owner)
        else { continue }
        found.append(String(name.dropLast(".jsonl".count)))
      }
      guard found.count <= 1 else {
        throw RemovalFailure(
          message:
            "More than one installation record names the startup container \(stub.identifier). Nothing was changed."
        )
      }
      return found.first
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
