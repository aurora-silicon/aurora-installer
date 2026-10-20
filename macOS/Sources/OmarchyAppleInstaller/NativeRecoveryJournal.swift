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
      try decode(bytes, planDigest: package.planDigest, deviceIdentifier: package.deviceIdentifier,
        storeIdentifier: package.storeIdentifier, intent: package.installationIntent, evidence: evidence)
    }

    static func decode(_ bytes: Data, planDigest: String, deviceIdentifier: String,
      storeIdentifier: String, intent: ImportedInstallationIntent,
      evidence: (String) throws -> Data) throws -> Self {
      let records = try EngineTranscriptDecoder().decode(bytes)
      let validated = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
      guard let plan = validated.plan, validated.support == .supported,
        validated.deviceIdentifier == deviceIdentifier,
        plan.deviceIdentifier == deviceIdentifier, plan.storeIdentifier == storeIdentifier,
        plan.planDigest == planDigest, intent != .repair,
        (intent == .replace ? plan.candidateKind == "replace"
          : ["free", "resize"].contains(plan.candidateKind))
      else { throw NativeRecoveryJournalError.invalidState }
      var stages = [("apfs_preparation_started", "apfs-target-prepared", "apfs_preparation"),
        ("stub_and_esp_started", "stub-and-esp-installed", "stub_and_esp")]
      if intent == .replace {
        stages.insert(("existing_removal_started", "existing-install-removed", "existing_removal"), at: 0)
      }
      var cursor = 3
      var saved = [String: Data]()
      func checkpoint(_ index: Int, identifier: String, phase: String) throws {
        guard index < records.count, case .checkpoint(let checkpoint) = records[index].message,
          checkpoint.identifier == identifier, checkpoint.phase == phase else {
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
          event.name == stage.0 else { throw NativeRecoveryJournalError.invalidState }
        try checkpoint(cursor + 1, identifier: stage.1, phase: stage.2)
        cursor += 2
      }
      let state: NativeRecoveryHandoffState
      if cursor == records.count { state = .ready }
      else {
        guard case .event(let event) = records[cursor].message,
          event.name == "recovery_handoff_started" else { throw NativeRecoveryJournalError.invalidState }
        cursor += 1
        if cursor == records.count { state = .started }
        else {
          try checkpoint(cursor, identifier: "recovery-handoff-prepared", phase: "awaiting_recovery")
          guard saved["recovery-handoff-prepared"] == handoffEvidence(plan.planDigest) else {
            throw NativeRecoveryJournalError.evidenceChanged
          }
          cursor += 1
          if cursor == records.count { state = .prepared }
          else {
            guard cursor + 1 == records.count,
              case .completion(let completion) = records[cursor].message,
              completion.outcome == "awaiting_recovery" else { throw NativeRecoveryJournalError.invalidState }
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

  /// Holds the private journal lock throughout handoff. Evidence is published
  /// durably before its checkpoint; an intent is durable before disk changes.
  final class NativeRecoveryJournal: @unchecked Sendable {
    private final class Descriptor {
      let value: Int32
      init(_ value: Int32) throws {
        guard value >= 0 else { throw NativeRecoveryJournalError.unsafeJournal }
        self.value = value
      }
      deinit { close(value) }
    }
    private let directoryHandle: Descriptor
    private let fileHandle: Descriptor
    private var directory: Int32 { directoryHandle.value }
    private var file: Int32 { fileHandle.value }
    private let name: String
    private let owner: uid_t
    private let package: ImportedEngineHandoffPackage
    private let lock = NSLock()

    init(url: URL, package: ImportedEngineHandoffPackage, owner: uid_t = 0) throws {
      guard let binding = SHA256Digest(rawValue: package.bindingDigest),
        url.lastPathComponent == binding.hexadecimal + ".jsonl" else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      self.name = url.lastPathComponent
      self.owner = owner
      self.package = package
      let parentFD = try Descriptor(open(url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
      directoryHandle = parentFD
      var parent = stat()
      guard fstat(parentFD.value, &parent) == 0, parent.st_uid == owner, parent.st_mode & 0o077 == 0 else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      fileHandle = try Descriptor(openat(parentFD.value, url.lastPathComponent,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
      guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
        throw NativeRecoveryJournalError.busy
      }
      _ = try snapshot()
    }

    func snapshot() throws -> NativeRecoveryJournalSnapshot {
      try lock.withLock { try current() }
    }

    func beginHandoff() throws {
      try lock.withLock {
        let before = try current()
        guard before.state == .ready || before.state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        if before.state == .ready {
          try append(type: "event", payload: ["plan_digest": package.planDigest,
            "name": "recovery_handoff_started"], before: before.transcript)
        }
      }
    }

    func recordPrepared() throws {
      try lock.withLock {
        let before = try current()
        guard before.state == .started else { throw NativeRecoveryJournalError.invalidState }
        let bytes = NativeRecoveryJournalSnapshot.handoffEvidence(package.planDigest)
        try publishEvidence(bytes, identifier: "recovery-handoff-prepared")
        try append(type: "checkpoint", payload: ["plan_digest": package.planDigest,
          "identifier": "recovery-handoff-prepared", "phase": "awaiting_recovery",
          "evidence_digest": SHA256Digest(hashing: bytes).rawValue], before: before.transcript)
      }
    }

    func complete() throws -> Data {
      try lock.withLock {
        let before = try current()
        guard before.state == .prepared || before.state == .complete else {
          throw NativeRecoveryJournalError.invalidState
        }
        if before.state == .prepared {
          try append(type: "completion", payload: ["plan_digest": package.planDigest,
            "outcome": "awaiting_recovery"], before: before.transcript)
        }
        return try current().transcript
      }
    }

    private func current() throws -> NativeRecoveryJournalSnapshot {
      try NativeRecoveryJournalSnapshot.decode(readJournal(), package: package) {
        try self.readEvidence($0)
      }
    }

    private func readJournal() throws -> Data {
      var info = stat(), entry = stat()
      guard fstat(file, &info) == 0, fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
        safe(info, maximum: PinnedAsahiEngineExecutor.maximumTranscriptBytes),
        info.st_ino == entry.st_ino, info.st_dev == entry.st_dev else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      return try read(file, bytes: Int(info.st_size))
    }

    private func safe(_ info: stat, maximum: Int64) -> Bool {
      info.st_uid == owner && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0
        && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= maximum
    }

    private func readEvidence(_ identifier: String) throws -> Data {
      let fd = openat(directory, name + "." + identifier + ".evidence",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard fd >= 0 else { throw NativeRecoveryJournalError.evidenceChanged }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, safe(info, maximum: 1 << 20) else {
        throw NativeRecoveryJournalError.evidenceChanged
      }
      return try read(fd, bytes: Int(info.st_size))
    }

    private func read(_ fd: Int32, bytes count: Int) throws -> Data {
      var bytes = Data(count: count)
      try bytes.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < count {
          let got = pread(fd, buffer.baseAddress!.advanced(by: offset), count - offset, off_t(offset))
          if got < 0 && errno == EINTR { continue }
          guard got > 0 else { throw NativeRecoveryJournalError.changed }
          offset += got
        }
      }
      var after = stat()
      guard fstat(fd, &after) == 0, after.st_size == count else { throw NativeRecoveryJournalError.changed }
      return bytes
    }

    private func append(type: String, payload: [String: Any], before: Data) throws {
      guard try readJournal() == before else { throw NativeRecoveryJournalError.changed }
      var line = try JSONSerialization.data(withJSONObject: ["schema_version": 1,
        "sequence": before.split(separator: 10).count + 1, "type": type, "payload": payload],
        options: [.sortedKeys, .withoutEscapingSlashes])
      line.append(10)
      guard line.count <= EngineTranscriptDecoder.maximumLineBytes,
        before.count + line.count <= PinnedAsahiEngineExecutor.maximumTranscriptBytes else {
        throw NativeRecoveryJournalError.writeFailed
      }
      _ = try EngineTranscriptDecoder().decode(before + line)
      try write(file, bytes: line, offset: off_t(before.count))
      guard fsync(file) == 0 else { throw NativeRecoveryJournalError.writeFailed }
      guard try readJournal() == before + line else { throw NativeRecoveryJournalError.changed }
    }

    private func publishEvidence(_ bytes: Data, identifier: String) throws {
      let final = name + "." + identifier + ".evidence"
      var existing = stat()
      if fstatat(directory, final, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard try readEvidence(identifier) == bytes else { throw NativeRecoveryJournalError.evidenceChanged }
        return
      }
      guard errno == ENOENT else { throw NativeRecoveryJournalError.evidenceChanged }
      let temporary = ".handoff-evidence-" + UUID().uuidString
      let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw NativeRecoveryJournalError.writeFailed }
      defer { close(fd); unlinkat(directory, temporary, 0) }
      try write(fd, bytes: bytes, offset: 0)
      guard fsync(fd) == 0,
        renameatx_np(directory, temporary, directory, final, UInt32(RENAME_EXCL)) == 0,
        fsync(directory) == 0 else {
        throw NativeRecoveryJournalError.writeFailed
      }
    }

    private func write(_ fd: Int32, bytes: Data, offset: off_t) throws {
      try bytes.withUnsafeBytes { buffer in
        var written = 0
        while written < bytes.count {
          let count = pwrite(fd, buffer.baseAddress!.advanced(by: written), bytes.count - written,
            offset + off_t(written))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NativeRecoveryJournalError.writeFailed }
          written += count
        }
      }
    }
  }
#endif
