#if os(macOS)
  import Darwin
  import Foundation

  /// Protected descriptor I/O shared by the native disk and Recovery stages.
  final class NativeInstallJournalFile: @unchecked Sendable {
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
    private let lock = NSLock()

    init(url: URL, package: ImportedEngineHandoffPackage, owner: uid_t = 0) throws {
      guard let binding = SHA256Digest(rawValue: package.bindingDigest),
        url.lastPathComponent == binding.hexadecimal + ".jsonl"
      else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      self.name = url.lastPathComponent
      self.owner = owner
      let parentFD = try Descriptor(
        open(
          url.deletingLastPathComponent().path,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
      directoryHandle = parentFD
      var parent = stat()
      guard fstat(parentFD.value, &parent) == 0, parent.st_uid == owner, parent.st_mode & 0o077 == 0
      else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      fileHandle = try Descriptor(
        openat(
          parentFD.value, url.lastPathComponent,
          O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
      guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
        throw NativeRecoveryJournalError.busy
      }
      _ = try readJournal()
    }

    func transaction<T>(_ body: () throws -> T) rethrows -> T {
      try lock.withLock(body)
    }

    /// A decoder inherits this open description as stdin. Its lifetime then
    /// retains the mutation lease even if the supervising helper is killed.
    func leaseForChild() throws -> FileHandle {
      let descriptor = dup(file)
      guard descriptor >= 0 else { throw NativeRecoveryJournalError.busy }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// An interrupted initial header may be completed only when every saved
    /// byte is a prefix of the freshly reconstructed, approved plan. A disk
    /// intent or checkpoint can never enter this path.
    func initialize(_ transcript: Data) throws {
      let records = try EngineTranscriptDecoder().decode(transcript)
      let validated = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
      guard records.count == 3, validated.plan != nil else {
        throw NativeRecoveryJournalError.invalidState
      }
      let before = try readJournal()
      guard transcript.starts(with: before) else { throw NativeRecoveryJournalError.changed }
      if before == transcript { return }
      try write(file, bytes: transcript, offset: 0)
      guard fsync(file) == 0, try readJournal() == transcript else {
        throw NativeRecoveryJournalError.writeFailed
      }
    }

    func readJournal() throws -> Data {
      var info = stat()
      var entry = stat()
      guard fstat(file, &info) == 0, fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
        safe(info, maximum: PinnedAsahiEngineExecutor.maximumTranscriptBytes, allowEmpty: true),
        info.st_ino == entry.st_ino, info.st_dev == entry.st_dev
      else {
        throw NativeRecoveryJournalError.unsafeJournal
      }
      return try read(file, bytes: Int(info.st_size))
    }

    private func safe(_ info: stat, maximum: Int64, allowEmpty: Bool = false) -> Bool {
      info.st_uid == owner && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0
        && info.st_nlink == 1 && info.st_size >= 0 && (allowEmpty || info.st_size > 0)
        && info.st_size <= maximum
    }

    func readEvidence(_ identifier: String) throws -> Data {
      let fd = openat(
        directory, name + "." + identifier + ".evidence",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard fd >= 0 else { throw NativeRecoveryJournalError.evidenceChanged }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, safe(info, maximum: 1 << 20) else {
        throw NativeRecoveryJournalError.evidenceChanged
      }
      return try read(fd, bytes: Int(info.st_size))
    }

    func containsEvidence(_ identifier: String) throws -> Bool {
      var info = stat()
      if fstatat(directory, name + "." + identifier + ".evidence", &info, AT_SYMLINK_NOFOLLOW) == 0
      {
        guard safe(info, maximum: 1 << 20) else { throw NativeRecoveryJournalError.evidenceChanged }
        return true
      }
      guard errno == ENOENT else { throw NativeRecoveryJournalError.evidenceChanged }
      return false
    }

    private func read(_ fd: Int32, bytes count: Int) throws -> Data {
      var bytes = Data(count: count)
      try bytes.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < count {
          let got = pread(
            fd, buffer.baseAddress!.advanced(by: offset), count - offset, off_t(offset))
          if got < 0 && errno == EINTR { continue }
          guard got > 0 else { throw NativeRecoveryJournalError.changed }
          offset += got
        }
      }
      var after = stat()
      guard fstat(fd, &after) == 0, after.st_size == count else {
        throw NativeRecoveryJournalError.changed
      }
      return bytes
    }

    func append(type: String, payload: [String: Any], before: Data) throws {
      guard try readJournal() == before else { throw NativeRecoveryJournalError.changed }
      var line = try JSONSerialization.data(
        withJSONObject: [
          "schema_version": 1,
          "sequence": before.split(separator: 10).count + 1, "type": type, "payload": payload,
        ],
        options: [.sortedKeys, .withoutEscapingSlashes])
      line.append(10)
      guard line.count <= EngineTranscriptDecoder.maximumLineBytes,
        before.count + line.count <= PinnedAsahiEngineExecutor.maximumTranscriptBytes
      else {
        throw NativeRecoveryJournalError.writeFailed
      }
      _ = try EngineTranscriptDecoder().decode(before + line)
      try write(file, bytes: line, offset: off_t(before.count))
      guard fsync(file) == 0 else { throw NativeRecoveryJournalError.writeFailed }
      guard try readJournal() == before + line else { throw NativeRecoveryJournalError.changed }
    }

    func publishEvidence(_ bytes: Data, identifier: String) throws {
      let final = name + "." + identifier + ".evidence"
      var existing = stat()
      if fstatat(directory, final, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard try readEvidence(identifier) == bytes else {
          throw NativeRecoveryJournalError.evidenceChanged
        }
        return
      }
      guard errno == ENOENT else { throw NativeRecoveryJournalError.evidenceChanged }
      let temporary = ".handoff-evidence-" + UUID().uuidString
      let fd = openat(
        directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw NativeRecoveryJournalError.writeFailed }
      defer {
        close(fd)
        unlinkat(directory, temporary, 0)
      }
      try write(fd, bytes: bytes, offset: 0)
      guard fsync(fd) == 0,
        renameatx_np(directory, temporary, directory, final, UInt32(RENAME_EXCL)) == 0,
        fsync(directory) == 0
      else {
        throw NativeRecoveryJournalError.writeFailed
      }
    }

    private func write(_ fd: Int32, bytes: Data, offset: off_t) throws {
      try bytes.withUnsafeBytes { buffer in
        var written = 0
        while written < bytes.count {
          let count = pwrite(
            fd, buffer.baseAddress!.advanced(by: written), bytes.count - written,
            offset + off_t(written))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NativeRecoveryJournalError.writeFailed }
          written += count
        }
      }
    }
  }
#endif
