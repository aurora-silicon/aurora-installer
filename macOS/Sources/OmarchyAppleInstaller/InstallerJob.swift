#if os(macOS)
  import Darwin
  import Foundation
  import Security

  public enum InstallerJobError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case identityMismatch
    case unavailable
    case unsafeState
    case interrupted
    case historyFull
    case notAdmitted

    public var errorDescription: String? {
      switch self {
      case .interrupted:
        "The installer helper stopped before it could confirm completion. Your installation has been preserved. Inspect its saved record before continuing."
      case .unavailable:
        "The saved installation could not be reached. Reopen this version of Aurora Installer to reconnect."
      case .historyFull:
        "The installer’s saved records need maintenance before another installation can start."
      case .notAdmitted:
        "The helper did not start this installation. Try again when it is ready."
      case .invalidRequest, .identityMismatch, .unsafeState:
        "The saved installation could not be verified. No new installation was started."
      }
    }
  }

  /// An observation capability, never an approval or authority to mutate disks.
  /// The helper also requires the original connection-derived UID and binding.
  public struct InstallerJobTicket: Codable, Equatable, Sendable {
    public let identifier: UUID
    public let observationToken: String
    public let bindingDigest: String
    public let selection: AuroraInstallationSelection

    public init(bindingDigest: String, selection: AuroraInstallationSelection) throws {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw InstallerJobError.unavailable
      }
      identifier = UUID()
      observationToken = bytes.map { String(format: "%02x", $0) }.joined()
      self.bindingDigest = bindingDigest
      self.selection = selection
      try validate()
    }

    func validate() throws {
      guard SHA256Digest(rawValue: bindingDigest) != nil,
        observationToken.utf8.count == 64,
        observationToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        AuroraInstallationSelection.allProfileIDs.contains(selection.profileID)
      else { throw InstallerJobError.invalidRequest }
    }

    var tokenDigest: String { SHA256Digest(hashing: Data(observationToken.utf8)).rawValue }
  }

  public struct PendingInstallerJob: Codable, Equatable, Sendable {
    public let ticket: InstallerJobTicket
    public let helperMachServiceName: String
    public let helperCodeSigningRequirement: String
  }

  public final class InstallerJobExecutionContext: @unchecked Sendable {
    let bindingDigest: String
    let selection: AuroraInstallationSelection
    let store: PendingInstallerJobStore
    let installConf: InstallConf
    private let lock = NSLock()
    private var handoff: InstallConfHandoff?

    public init(
      bindingDigest: String, selection: AuroraInstallationSelection,
      store: PendingInstallerJobStore, installConf: InstallConf
    ) {
      self.bindingDigest = bindingDigest
      self.selection = selection
      self.store = store
      self.installConf = installConf
    }

    public var installConfHandoff: InstallConfHandoff? { lock.withLock { handoff } }
    func completed(_ value: InstallConfHandoff) { lock.withLock { handoff = value } }
  }

  enum InstallerJobXPCCodec {
    private static let domain = InstallerProductIdentity.appIdentifier + ".installation-job"
    private static let errors: [InstallerJobError] = [
      .invalidRequest, .identityMismatch, .unavailable, .unsafeState, .interrupted, .historyFull, .notAdmitted,
    ]

    static func serviceError(_ error: any Error) -> NSError {
      if let job = error as? InstallerJobError, let index = errors.firstIndex(of: job) {
        return NSError(domain: domain, code: index + 1, userInfo: [:])
      }
      return EngineXPCErrorBridge.serviceError(for: error)
    }

    static func decodedError(_ error: NSError) -> any Error {
      if error.domain == domain, (1...errors.count).contains(error.code) {
        return errors[error.code - 1]
      }
      return EngineXPCErrorBridge.submissionError(error)
    }
  }

  /// Only a lookup hint is retained by the GUI. No credential or approval is stored.
  public struct PendingInstallerJobStore: Sendable {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> PendingInstallerJob? {
      let files = try PrivateInstallerJobFiles(directory: directory)
      guard let data = try files.read("pending-installation.json", maximumBytes: 65_536) else {
        return nil
      }
      let hint = try JSONDecoder().decode(PendingInstallerJob.self, from: data)
      try hint.ticket.validate()
      guard hint.helperMachServiceName.utf8.count <= 255,
        hint.helperCodeSigningRequirement.utf8.count <= 4096,
        EngineCodeSigningRequirement.isValid(hint.helperCodeSigningRequirement)
      else { throw InstallerJobError.unsafeState }
      return hint
    }

    public func save(_ hint: PendingInstallerJob) throws {
      try hint.ticket.validate()
      let files = try PrivateInstallerJobFiles(directory: directory)
      try files.write(JSONEncoder().encode(hint), name: "pending-installation.json", maximumBytes: 65_536)
    }

    public func clear() throws {
      try PrivateInstallerJobFiles(directory: directory).remove("pending-installation.json")
    }
  }

  public struct InstallerJobPlanIdentity: Codable, Equatable, Sendable {
    public let bindingDigest: String
    public let planDigest: String
    public let deviceIdentifier: String

    init(package: ImportedEngineHandoffPackage) {
      bindingDigest = package.bindingDigest
      planDigest = package.planDigest
      deviceIdentifier = package.deviceIdentifier
    }
  }

  public enum InstallerJobPhase: String, Codable, Sendable {
    case preparing, running, succeeded, failed, interrupted
  }

  /// Only the existing fixed, redacted failure fields may enter persistent state.
  struct InstallerJobFailure: Codable, Sendable {
    let code: String
    let reason: Int?
    let exitStatus: Int32?
    let diskUnchanged: Bool
    let summary: String

    init(error: any Error) {
      let submission = EngineXPCErrorBridge.submissionError(EngineXPCErrorBridge.serviceError(for: error))
      switch submission {
      case .machineOwnerCredentialsRejected:
        code = "credentials"; reason = nil; exitStatus = nil; diskUnchanged = true; summary = ""
      case .recoveryAuthorizationFailed:
        code = "recovery"; reason = nil; exitStatus = nil; diskUnchanged = false; summary = ""
      case .engineFailed(let notice):
        code = "engine"; reason = notice.reason.rawValue; exitStatus = notice.exitStatus
        diskUnchanged = notice.diskUnchanged; summary = EngineFailureNotice.sanitizedSummary(notice.summary)
      default:
        code = "helper"; reason = nil; exitStatus = nil; diskUnchanged = false; summary = ""
      }
    }

    func submissionError() -> EngineXPCSubmissionError {
      switch code {
      case "credentials": .machineOwnerCredentialsRejected
      case "recovery": .recoveryAuthorizationFailed
      case "engine":
        .engineFailed(EngineFailureNotice(
          reason: EngineFailureReason(rawValue: reason ?? 0) ?? .unclassified,
          exitStatus: exitStatus ?? -1, diskUnchanged: diskUnchanged, summary: summary))
      default: .helperRejected(domain: "AuroraInstallerJob", code: 1)
      }
    }
  }

  public struct InstallerJobSnapshot: Codable, Sendable {
    public let identifier: UUID
    public let bindingDigest: String
    public let selection: AuroraInstallationSelection
    public let phase: InstallerJobPhase
    public let plan: InstallerJobPlanIdentity?
    public let transcript: Data?
    public let installConf: InstallConfHandoff?
    let failure: InstallerJobFailure?
    public let journal: Data
    public let journalOffset: UInt64

    public func requireResult() throws -> (Data, InstallConfHandoff) {
      switch phase {
      case .succeeded:
        guard let transcript, let installConf else { throw InstallerJobError.unsafeState }
        return (transcript, installConf)
      case .failed:
        throw failure?.submissionError() ?? EngineXPCSubmissionError.emptyResponse
      case .interrupted:
        throw InstallerJobError.interrupted
      case .preparing, .running:
        throw InstallerJobError.unavailable
      }
    }
  }

  struct InstallerJobStartRequest: Codable, Sendable {
    let ticket: InstallerJobTicket
    let operation: String
    let installConf: Data
  }

  struct InstallerJobStatusRequest: Codable, Sendable {
    let ticket: InstallerJobTicket
    let journalOffset: UInt64
  }

  private struct InstallerJobRecord: Codable {
    let format: Int
    let identifier: UUID
    let initiatingUID: UInt32
    let tokenDigest: String
    let bindingDigest: String
    let selection: AuroraInstallationSelection
    let operation: String
    let installConfDocument: Data
    let createdAt: Date
    var phase: InstallerJobPhase
    var plan: InstallerJobPlanIdentity?
    var transcript: Data?
    var installConf: InstallConfHandoff?
    var failure: InstallerJobFailure?
  }

  /// Independent synchronization keeps observation responsive while the engine
  /// blocks the helper actor. Starting a job claims the same replacement gate
  /// as all existing privileged operations. Disconnecting a client changes none
  /// of this state and never cancels the worker.
  final class InstallerJobRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let workingDirectory: URL
    private let work: HelperWorkState
    private var records = [UUID: InstallerJobRecord]()
    private var loaded = false
    private var loadError: (any Error)?
    private static let maximumRecordBytes = 12 * 1_048_576
    private static let maximumRecords = 32

    init(workingDirectory: URL, work: HelperWorkState) {
      self.workingDirectory = workingDirectory
      directory = workingDirectory.appendingPathComponent("installation-jobs", isDirectory: true)
      self.work = work
      do { try load() }
      catch {
        loadError = error
        // Unknown persistent state cannot make an old executor safe to replace.
        try? work.beginJob()
      }
    }

    /// Returns false for an exact duplicate; no password is needed to observe it.
    func begin(_ request: InstallerJobStartRequest, initiatingUID: UInt32) throws -> Bool {
      try request.ticket.validate()
      guard EngineHandoffOperation(rawValue: request.operation) != nil,
        request.installConf.count <= 256
      else { throw InstallerJobError.invalidRequest }
      _ = try InstallConf.parse(request.installConf)
      return try lock.withLock {
        try load()
        if let old = records[request.ticket.identifier] {
          try authorize(old, ticket: request.ticket, uid: initiatingUID)
          guard old.operation == request.operation, old.installConfDocument == request.installConf else {
            throw InstallerJobError.identityMismatch
          }
          return false
        }
        guard !records.values.contains(where: { $0.phase == .interrupted }) else {
          throw InstallerJobError.interrupted
        }
        try retireNonMutatingFailures()
        guard records.count < Self.maximumRecords else { throw InstallerJobError.historyFull }
        try work.beginJob()
        let record = InstallerJobRecord(
          format: 1, identifier: request.ticket.identifier, initiatingUID: initiatingUID,
          tokenDigest: request.ticket.tokenDigest, bindingDigest: request.ticket.bindingDigest,
          selection: request.ticket.selection, operation: request.operation,
          installConfDocument: request.installConf, createdAt: Date(), phase: .preparing)
        do {
          try persist(record)
          records[record.identifier] = record
          return true
        } catch {
          work.endJob()
          throw error
        }
      }
    }

    func admitted(_ identifier: UUID, package: ImportedEngineHandoffPackage) throws {
      try lock.withLock {
        guard var record = records[identifier], record.phase == .preparing,
          record.bindingDigest == package.bindingDigest
        else { throw InstallerJobError.identityMismatch }
        record.plan = InstallerJobPlanIdentity(package: package)
        record.phase = .running
        try persist(record)
        records[identifier] = record
      }
    }

    func finish(_ identifier: UUID, result: Result<(Data, InstallConfHandoff), any Error>) {
      defer { work.endJob() }
      lock.withLock {
        guard var record = records[identifier] else { return }
        switch result {
        case .success(let (transcript, conf)):
          if Int64(transcript.count) <= PinnedAsahiEngineExecutor.maximumTranscriptBytes {
            record.phase = .succeeded; record.transcript = transcript; record.installConf = conf
          } else {
            record.phase = .interrupted
          }
        case .failure(let error):
          record.phase = .failed; record.failure = InstallerJobFailure(error: error)
        }
        do {
          try persist(record)
        } catch {
          // The old durable record remains unfinished. Never infer success or
          // replay mutation when its final durable write could not be confirmed.
          record.phase = .interrupted; record.transcript = nil; record.installConf = nil
        }
        records[identifier] = record
      }
    }

    func status(_ request: InstallerJobStatusRequest, initiatingUID: UInt32) throws -> InstallerJobSnapshot {
      try request.ticket.validate()
      let record = try lock.withLock {
        try load()
        guard let record = records[request.ticket.identifier] else { throw InstallerJobError.unavailable }
        try authorize(record, ticket: request.ticket, uid: initiatingUID)
        return record
      }
      let (journal, offset) = readJournal(record, offset: request.journalOffset)
      return InstallerJobSnapshot(
        identifier: record.identifier, bindingDigest: record.bindingDigest,
        selection: record.selection, phase: record.phase, plan: record.plan,
        transcript: record.transcript, installConf: record.installConf, failure: record.failure,
        journal: journal, journalOffset: offset)
    }

    private func authorize(_ record: InstallerJobRecord, ticket: InstallerJobTicket, uid: UInt32) throws {
      guard record.initiatingUID == uid, record.tokenDigest == ticket.tokenDigest,
        record.bindingDigest == ticket.bindingDigest, record.selection == ticket.selection
      else { throw InstallerJobError.identityMismatch }
    }

    private func load() throws {
      if let loadError { throw loadError }
      guard !loaded else { return }
      let files = try PrivateInstallerJobFiles(directory: directory)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { !$0.hasPrefix(".pending-") }
      guard names.count <= Self.maximumRecords else { throw InstallerJobError.historyFull }
      var restored = [UUID: InstallerJobRecord]()
      for name in names {
        guard let data = try files.read(name, maximumBytes: Self.maximumRecordBytes) else {
          throw InstallerJobError.unsafeState
        }
        var record = try JSONDecoder().decode(InstallerJobRecord.self, from: data)
        guard record.format == 1, name == record.identifier.uuidString.lowercased() + ".json",
          SHA256Digest(rawValue: record.bindingDigest) != nil,
          SHA256Digest(rawValue: record.tokenDigest) != nil
        else { throw InstallerJobError.unsafeState }
        if record.phase == .preparing || record.phase == .running {
          record.phase = .interrupted
          try persist(record)
        }
        restored[record.identifier] = record
      }
      records = restored; loaded = true
      if records.values.contains(where: { $0.phase == .interrupted }) {
        // A child of the previous helper may still be alive. Keep every existing
        // privileged operation and helper replacement blocked pending inspection.
        try work.beginJob()
      }
    }

    private func retireNonMutatingFailures() throws {
      let failures = records.values.filter {
        $0.phase == .failed && $0.failure?.diskUnchanged == true
      }.sorted { $0.createdAt < $1.createdAt }
      guard failures.count >= 8 else { return }
      let files = try PrivateInstallerJobFiles(directory: directory)
      for old in failures.prefix(failures.count - 7) {
        try files.remove(old.identifier.uuidString.lowercased() + ".json")
        records.removeValue(forKey: old.identifier)
      }
    }

    private func persist(_ record: InstallerJobRecord) throws {
      try PrivateInstallerJobFiles(directory: directory).write(
        JSONEncoder().encode(record), name: record.identifier.uuidString.lowercased() + ".json",
        maximumBytes: Self.maximumRecordBytes)
    }

    private func readJournal(_ record: InstallerJobRecord, offset: UInt64) -> (Data, UInt64) {
      guard record.plan != nil,
        let url = EngineJournalLocator.journalURL(workingDirectory: workingDirectory, bindingDigest: record.bindingDigest)
      else { return (Data(), offset) }
      let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { return (Data(), offset) }
      defer { Darwin.close(fd) }
      var status = stat()
      guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_mode & 0o077 == 0, status.st_uid == geteuid(), status.st_nlink == 1,
        status.st_size >= 0, status.st_size <= PinnedAsahiEngineExecutor.maximumTranscriptBytes
      else { return (Data(), offset) }
      let start = offset <= UInt64(status.st_size) ? offset : 0
      guard Darwin.lseek(fd, off_t(start), SEEK_SET) >= 0,
        let bytes = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 262_144),
        let newline = bytes.lastIndex(of: 0x0A)
      else { return (Data(), start) }
      let complete = Data(bytes[...newline])
      return (complete, start + UInt64(complete.count))
    }
  }

  /// Descriptor-relative, private atomic storage shared by root records and GUI hints.
  private final class PrivateInstallerJobFiles {
    private let fd: Int32

    init(directory: URL) throws {
      if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw InstallerJobError.unsafeState }
      fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw InstallerJobError.unsafeState }
      var status = stat()
      guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
        status.st_mode & 0o077 == 0, status.st_uid == geteuid()
      else { Darwin.close(fd); throw InstallerJobError.unsafeState }
    }

    deinit { Darwin.close(fd) }

    private func validateName(_ name: String) throws {
      guard !name.isEmpty, name.utf8.count <= 128,
        name.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
        name != ".", name != ".."
      else { throw InstallerJobError.unsafeState }
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data? {
      try validateName(name)
      let file = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard file >= 0 else {
        if errno == ENOENT { return nil }
        throw InstallerJobError.unsafeState
      }
      defer { Darwin.close(file) }
      var status = stat()
      guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_mode & 0o077 == 0, status.st_uid == geteuid(), status.st_nlink == 1,
        status.st_size >= 0, status.st_size <= Int64(maximumBytes),
        let bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: maximumBytes + 1),
        bytes.count == Int(status.st_size)
      else { throw InstallerJobError.unsafeState }
      return bytes
    }

    func write(_ data: Data, name: String, maximumBytes: Int) throws {
      try validateName(name)
      guard data.count <= maximumBytes else { throw InstallerJobError.unsafeState }
      let temporary = ".pending-" + UUID().uuidString.lowercased()
      let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard file >= 0 else { throw InstallerJobError.unsafeState }
      defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
      try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: data)
      guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else {
        throw InstallerJobError.unsafeState
      }
    }

    func remove(_ name: String) throws {
      try validateName(name)
      guard unlinkat(fd, name, 0) == 0 || errno == ENOENT, fsync(fd) == 0 else {
        throw InstallerJobError.unsafeState
      }
    }
  }
  enum InstallerJobObservation {
    static func wait(
      fetch: @escaping @Sendable (UInt64) async throws -> InstallerJobSnapshot,
      journal: (@Sendable (Data) -> Void)? = nil,
      sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> InstallerJobSnapshot {
      var offset: UInt64 = 0
      var lostConnections = 0
      while true {
        do {
          let snapshot = try await fetch(offset)
          lostConnections = 0
          offset = snapshot.journalOffset
          if !snapshot.journal.isEmpty { journal?(snapshot.journal) }
          switch snapshot.phase {
          case .preparing, .running:
            try await sleep( snapshot.journal.isEmpty ? .seconds(1) : .milliseconds(100))
          case .succeeded, .failed, .interrupted:
            if let transcript = snapshot.transcript { journal?(transcript) }
            return snapshot
          }
        } catch let error as EngineXPCSubmissionError where error == .connectionFailed {
          lostConnections += 1
          guard lostConnections <= 8 else { throw InstallerJobError.unavailable }
          try await sleep( .seconds(1))
        } catch let error as InstallerJobError where error == .unavailable {
          lostConnections += 1
          guard lostConnections <= 8 else { throw error }
          try await sleep( .seconds(1))
        }
      }
        }
  }
#endif
