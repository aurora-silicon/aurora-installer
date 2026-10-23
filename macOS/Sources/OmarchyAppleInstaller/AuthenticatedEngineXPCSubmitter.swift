#if os(macOS)
  import Darwin
  import Foundation
  import Security
  import RecoveryAccountCore

  @objc public protocol ClosedEngineXPCService {
    /// Answers as soon as the helper is up. The app calls this before it
    /// sends anything, so a helper that launchd cannot keep alive fails in
    /// seconds instead of leaving a request queued forever.
    func ping(reply: @escaping @Sendable (Bool) -> Void)

    /// The helper's build version, or an empty string when it carries none.
    /// Helpers installed by the installer package predate this call and never
    /// answer it.
    func helperVersion(reply: @escaping @Sendable (String) -> Void)

    func recoveryAccount(
      action: String, ticket: String, username: String, password: Data,
      recoveryTemplate: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void)

    /// Removes the installer app the installer package left in
    /// /Applications, when that is safe; replies with a summary for logs.
    /// See `PackageInstalledAppRetirement`.
    func retirePackageInstalledApps(reply: @escaping @Sendable (String) -> Void)

    /// Yes if no job runs and no other app holds the replacement; the helper
    /// then refuses new jobs until it is replaced, the hold is released, or
    /// it lapses. The same token renews the hold. Helpers older than this
    /// call never answer it.
    func prepareForReplacement(token: String, reply: @escaping @Sendable (Bool) -> Void)

    func cancelReplacement(token: String, reply: @escaping @Sendable () -> Void)

    func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func startJob(
      request: Data, packageDirectory: FileHandle, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func jobStatus(request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    /// Sets a failed job aside after the person chose Start over and replies
    /// with its last snapshot. Helpers older than this call never answer it.
    func abandonJob(request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    func retryRecoveryJob(
      request: Data, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
  }

  public enum EngineXPCSubmissionError: Error, Equatable, Sendable {
    case invalidMachServiceName
    case invalidCodeSigningRequirement
    case unsafeHandoffPackage
    case connectionFailed
    /// The helper did not answer a ping within the allowed time. Seen when
    /// launchd respawns a helper that exits at startup: the mach message
    /// stays queued and nothing ever replies or interrupts.
    case helperUnresponsive
    case recoveryAuthorizationFailed
    case machineOwnerCredentialsRejected
    case helperRejected(domain: String, code: Int)
    /// The pinned engine stopped with an error. Display and diagnostics only:
    /// nothing in it may decide trust, and the summary is untrusted text.
    case engineFailed(EngineFailureNotice)
    case emptyResponse
    /// The request was never handed to the helper: it didn't answer before
    /// sending, or no connection could be made. Nothing started.
    case notSubmitted
  }

  public struct AuthenticatedEngineXPCSubmitter:
    EngineHandoffSubmitting, Sendable
  {
    private let machServiceName: String
    private let helperCodeSigningRequirement: String
    private let journalProgress: (@Sendable (Data) -> Void)?
    private let jobContext: InstallerJobExecutionContext?

    public init(
      machServiceName: String,
      helperCodeSigningRequirement: String,
      journalProgress: (@Sendable (Data) -> Void)? = nil,
      jobContext: InstallerJobExecutionContext? = nil
    ) throws {
      guard Self.isMachServiceName(machServiceName) else {
        throw EngineXPCSubmissionError.invalidMachServiceName
      }
      guard
        EngineCodeSigningRequirement.isValid(
          helperCodeSigningRequirement
        )
      else {
        throw EngineXPCSubmissionError.invalidCodeSigningRequirement
      }
      self.machServiceName = machServiceName
      self.helperCodeSigningRequirement = helperCodeSigningRequirement
      self.journalProgress = journalProgress
      self.jobContext = jobContext
    }

    /// A privileged connection to the helper, pinned to its code-signing
    /// requirement; each call gets its own so a dead one never lingers.
    private func makeConnection() -> NSXPCConnection {
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.setCodeSigningRequirement(helperCodeSigningRequirement)
      return connection
    }

    /// Confirms the helper answers before any credentials or package are
    /// sent. A missing service fails through the connection handlers; a
    /// service launchd cannot keep alive answers nothing at all, which is
    /// what the timeout is for.
    public func ping(timeout: Duration = .seconds(8)) async throws {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answered: Bool = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCPingGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.helperUnresponsive)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          connectionHandle.invalidate()
          return
        }
        proxy.ping { answer in
          gate.resume(returning: answer)
          connectionHandle.invalidate()
        }
      }
      guard answered else {
        throw EngineXPCSubmissionError.helperUnresponsive
      }
    }

    /// How a ping went, for deciding what to do with an installed helper.
    public enum PingResult: Equatable, Sendable {
      /// The helper answered yes.
      case answered
      /// The connection ended before the timeout without a yes: nothing is
      /// listening, or the helper refused this app, as a helper from another
      /// build does, or it is uninstalling itself.
      case refused
      /// No answer within the timeout: the helper may just be busy with a long
      /// job, so it must not be treated as broken or replaced on that alone.
      case noAnswer
    }

    public func pingResult(timeout: Duration = .seconds(8)) async -> PingResult {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timedOut = EngineXPCFlag()
      let timer = Task {
        try await Task.sleep(for: timeout)
        timedOut.set()
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answered: Bool? = await withCheckedContinuation { continuation in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.ping { answer in
          gate.resume(returning: answer)
          connectionHandle.invalidate()
        }
      }
      if answered == true {
        return .answered
      }
      return timedOut.isSet ? .noAnswer : .refused
    }

    /// Nil when the helper doesn't answer in time, as helpers older than the
    /// call never do.
    public func prepareForReplacement(
      token: String, timeout: Duration = .seconds(3)
    ) async -> Bool? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { continuation in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.prepareForReplacement(token: token) { granted in
          gate.resume(returning: granted)
          connectionHandle.invalidate()
        }
      }
    }

    public func cancelReplacement(token: String, timeout: Duration = .seconds(3)) async {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
        let gate = EngineXPCOptionalBoolGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: nil) }
        connection.invalidationHandler = { gate.resume(returning: nil) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: nil)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: nil)
          connectionHandle.invalidate()
          return
        }
        proxy.cancelReplacement(token: token) {
          gate.resume(returning: true)
          connectionHandle.invalidate()
        }
      }
    }

    /// Asks the helper to remove the installer app the package left behind.
    /// Returns the helper's summary, or nil when it does not answer in time.
    public func retirePackageInstalledApps(timeout: Duration = .seconds(10)) async -> String? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let summary: String = await withCheckedContinuation { continuation in
        let gate = EngineXPCStringGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: "") }
        connection.invalidationHandler = { gate.resume(returning: "") }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: "")
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: "")
          connectionHandle.invalidate()
          return
        }
        proxy.retirePackageInstalledApps { reported in
          gate.resume(returning: reported)
          connectionHandle.invalidate()
        }
      }
      return summary.isEmpty ? nil : summary
    }

    /// The build version the running helper reports, or nil when it reports
    /// none, does not answer in time, or cannot be reached. An older helper
    /// that lacks the call simply never replies, so the timeout is short.
    public func helperVersion(timeout: Duration = .seconds(3)) async -> String? {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let version: String = await withCheckedContinuation { continuation in
        let gate = EngineXPCStringGate(continuation: continuation)
        connection.interruptionHandler = { gate.resume(returning: "") }
        connection.invalidationHandler = { gate.resume(returning: "") }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(returning: "")
          }) as? ClosedEngineXPCService
        else {
          gate.resume(returning: "")
          connectionHandle.invalidate()
          return
        }
        proxy.helperVersion { reported in
          gate.resume(returning: reported)
          connectionHandle.invalidate()
        }
      }
      return version.isEmpty ? nil : version
    }

    public func removal(
      ticket: OmarchyRemovalTicket? = nil, confirmation: String = "",
      authorization: MachineOwnerAuthorization? = nil
    ) async throws -> OmarchyRemovalReply {
      // Failures before the request is handed over mean nothing started, and
      // are told apart from a reply lost after sending.
      do {
        try await ping()
      } catch {
        throw EngineXPCSubmissionError.notSubmitted
      }
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.notSubmitted)
          handle.invalidate()
          return
        }
        proxy.removal(
          ticket: ticket?.id.uuidString ?? "", confirmation: confirmation,
          machineOwner: authorization?.username ?? "", password: authorization?.password ?? Data()
        ) { response, error in
          defer { handle.invalidate() }
          if let error {
            gate.resume(throwing: error)
          } else if let response {
            gate.resume(returning: response)
          } else {
            gate.resume(throwing: EngineXPCSubmissionError.emptyResponse)
          }
        }
      }
      return try JSONDecoder().decode(OmarchyRemovalReply.self, from: data)
    }

    public func recoveryAccount(
      action: String, ticket: String = "", username: String = "", password: Data = Data()
    ) async throws -> RecoveryAccountReply {
      let template =
        action == "handoff" || action == "prepare"
        ? try NativeRecoveryTemplate.archiveData(from: NativeRecoveryTemplate.bundledURL()) : Data()
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: .seconds(180))
        handle.invalidate()
      }
      defer { timer.cancel() }
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        proxy.recoveryAccount(
          action: action, ticket: ticket, username: username, password: password,
          recoveryTemplate: template
        ) { response, error in
          defer { handle.invalidate() }
          if let error {
            // A busy, retiring or replaced helper arrives as helperRejected.
            gate.resume(throwing: EngineXPCErrorBridge.submissionError(error))
          } else if let response {
            gate.resume(returning: response)
          } else {
            gate.resume(throwing: EngineXPCSubmissionError.emptyResponse)
          }
        }
      }
      let reply = try JSONDecoder().decode(RecoveryAccountReply.self, from: data)
      if let message = reply.message { throw AccountSetupFailure(message) }
      return reply
    }

    public func submit(
      _ handoff: PreparedEngineHandoff,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      let descriptor = Darwin.open(
        handoff.packageURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        Darwin.close(descriptor)
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      let directoryHandle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: true
      )
      if let jobContext {
        return try await submitPersistentJob(
          directoryHandle: directoryHandle, authorization: authorization,
          operation: operation, context: jobContext)
      }
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      if let journalProgress {
        connection.exportedInterface = NSXPCInterface(
          with: ClosedEngineProgressClient.self
        )
        connection.exportedObject = EngineProgressClientRelay(
          handler: journalProgress
        )
      }

      return try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.invalidationHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.activate()

        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(
              throwing: EngineXPCSubmissionError.connectionFailed
            )
            connectionHandle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
          connectionHandle.invalidate()
          return
        }

        proxy.submit(
          packageDirectory: directoryHandle,
          operation: operation.rawValue,
          machineOwner: authorization.username,
          password: authorization.password
        ) { response, error in
          defer { connectionHandle.invalidate() }
          if let error {
            gate.resume(
              throwing: EngineXPCErrorBridge.submissionError(error)
            )
          } else if let response, !response.isEmpty {
            gate.resume(returning: response)
          } else {
            gate.resume(
              throwing: EngineXPCSubmissionError.emptyResponse
            )
          }
        }
      }
    }

    private func jobCall(
      _ invoke:
        @escaping @Sendable (
          any ClosedEngineXPCService, @escaping @Sendable (Data?, NSError?) -> Void
        ) -> Void
    ) async throws -> InstallerJobSnapshot {
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: .seconds(8))
        handle.invalidate()
      }
      defer { timer.cancel() }
      let bytes: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        invoke(proxy) { data, error in
          defer { handle.invalidate() }
          if let error {
            gate.resume(throwing: InstallerJobXPCCodec.decodedError(error))
          } else if let data, data.count <= 12 * 1_048_576 {
            gate.resume(returning: data)
          } else {
            gate.resume(throwing: InstallerJobError.unsafeState)
          }
        }
      }
      return try JSONDecoder().decode(InstallerJobSnapshot.self, from: bytes)
    }

    private func submitPersistentJob(
      directoryHandle: FileHandle, authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation, context: InstallerJobExecutionContext
    ) async throws -> Data {
      let ticket = try InstallerJobTicket(
        bindingDigest: context.bindingDigest, selection: context.selection)
      let hint = PendingInstallerJob(
        ticket: ticket, helperMachServiceName: machServiceName,
        helperCodeSigningRequirement: helperCodeSigningRequirement)
      // Persist before sending: losing the start reply cannot lose the lookup.
      try context.store.save(hint)
      let request = try JSONEncoder().encode(
        InstallerJobStartRequest(
          ticket: ticket, operation: operation.rawValue,
          installConf: context.installConf.serializedData))
      do {
        _ = try await jobCall { proxy, reply in
          proxy.startJob(
            request: request, packageDirectory: directoryHandle,
            machineOwner: authorization.username, password: authorization.password, reply: reply)
        }
      } catch let error as EngineXPCSubmissionError where error == .connectionFailed {
        // Observe only. Never resend credentials or replay a possibly admitted job.
      } catch let error as InstallerJobError where error == .notAdmitted {
        try? context.store.clear()
        throw EngineXPCSubmissionError.notSubmitted
      }
      do {
        let snapshot = try await observeJob(hint)
        if let failure = snapshot.initialFailureWithoutDiskChanges {
          try context.store.clear(ifMatching: hint)
          throw failure
        }
        let (transcript, handoff) = try snapshot.requireResult()
        context.completed(handoff)
        return transcript
      } catch let error as EngineXPCSubmissionError where error == .machineOwnerCredentialsRejected
      {
        if try context.store.load() == hint { try context.store.clear(ifMatching: hint) }
        throw error
      }
    }

    /// Whether a lookup hint belongs to this connection's helper. A hint
    /// recorded by another build of this installer names the same service
    /// with that build's exact helper requirement; `otherBuild` admits it.
    /// The connection itself only ever talks to a helper that meets this
    /// build's requirement, whatever the hint says.
    static func admits(
      _ hint: PendingInstallerJob, machServiceName: String, helperCodeSigningRequirement: String,
      otherBuild: Bool
    ) -> Bool {
      hint.helperMachServiceName == machServiceName
        && (otherBuild || hint.helperCodeSigningRequirement == helperCodeSigningRequirement)
    }

    private func admit(_ hint: PendingInstallerJob, otherBuild: Bool) throws {
      guard
        Self.admits(
          hint, machServiceName: machServiceName,
          helperCodeSigningRequirement: helperCodeSigningRequirement, otherBuild: otherBuild)
      else { throw InstallerJobError.identityMismatch }
    }

    /// Read-only. `otherBuild` looks up a job another build of this installer
    /// recorded, for example before the installer was updated; the lookup
    /// hint itself is left as it is.
    public func jobStatus(
      _ hint: PendingInstallerJob, journalOffset: UInt64 = 0, otherBuild: Bool = false
    ) async throws -> InstallerJobSnapshot {
      try admit(hint, otherBuild: otherBuild)
      try hint.ticket.validate()
      let request = try JSONEncoder().encode(
        InstallerJobStatusRequest(
          ticket: hint.ticket, journalOffset: journalOffset))
      let snapshot = try await jobCall { proxy, reply in
        proxy.jobStatus(request: request, reply: reply)
      }
      guard snapshot.identifier == hint.ticket.identifier,
        snapshot.bindingDigest == hint.ticket.bindingDigest,
        snapshot.selection == hint.ticket.selection,
        snapshot.plan == nil || snapshot.plan?.bindingDigest == hint.ticket.bindingDigest
      else { throw InstallerJobError.identityMismatch }
      if let expected = hint.recoveryAttempt, snapshot.recoveryAttempt != expected {
        throw InstallerJobError.unavailable
      }
      return snapshot
    }

    /// The helper decides whether the job may be set aside. A job it keeps no
    /// record of is already gone, so only the lookup hint remains to clear.
    /// `otherBuild` sets aside a job another build of this installer
    /// recorded; the helper still decides whether it may.
    public func abandonJob(
      _ hint: PendingInstallerJob, store: PendingInstallerJobStore, otherBuild: Bool = false
    ) async throws {
      try admit(hint, otherBuild: otherBuild)
      try hint.ticket.validate()
      let request = try JSONEncoder().encode(InstallerJobAbandonRequest(ticket: hint.ticket))
      do {
        let snapshot = try await jobCall { proxy, reply in
          proxy.abandonJob(request: request, reply: reply)
        }
        guard snapshot.identifier == hint.ticket.identifier,
          snapshot.bindingDigest == hint.ticket.bindingDigest,
          snapshot.selection == hint.ticket.selection
        else { throw InstallerJobError.identityMismatch }
      } catch let error as InstallerJobError where error == .unavailable {
        // The helper has no record of this job.
      }
      try store.clear(ifMatching: hint)
    }

    /// `adoptingOtherBuild` continues a job another build of this installer
    /// recorded, once the person has authorized the retry with the
    /// machine-owner password. The saved hint then names this build's helper.
    /// If the helper doesn't admit the retry, the original hint is restored.
    public func retryRecoveryJob(
      _ hint: PendingInstallerJob, store: PendingInstallerJobStore,
      authorization: MachineOwnerAuthorization, adoptingOtherBuild: Bool = false
    ) async throws -> InstallerJobSnapshot {
      try admit(hint, otherBuild: adoptingOtherBuild)
      let attempt = UUID()
      let pending = hint.rebound(
        toHelperCodeSigningRequirement: helperCodeSigningRequirement, recoveryAttempt: attempt)
      try store.save(pending)
      let request = try JSONEncoder().encode(
        InstallerJobRecoveryRequest(ticket: hint.ticket, attempt: attempt))
      do {
        _ = try await jobCall { proxy, reply in
          proxy.retryRecoveryJob(
            request: request, machineOwner: authorization.username,
            password: authorization.password, reply: reply)
        }
      } catch let error as EngineXPCSubmissionError where error == .connectionFailed {
        // Observe this exact attempt; credentials are never resent automatically.
      } catch let error as InstallerJobError where error == .notAdmitted {
        try store.save(hint)
        throw EngineXPCSubmissionError.notSubmitted
      }
      return try await observeJob(pending)
    }

    /// Waits for the helper to answer before a pending job is looked up, as
    /// it may still be starting after the installer package replaced it.
    public func waitForHelper(attempts: Int = 20) async throws {
      try await InstallerJobObservation.waitForHelper(
        attempts: attempts, ping: { try await self.ping(timeout: .seconds(3)) })
    }

    /// Read-only polling needs no credential and survives replacing the GUI.
    /// `otherBuild` observes a job another build of this installer recorded.
    public func observeJob(_ hint: PendingInstallerJob, otherBuild: Bool = false) async throws
      -> InstallerJobSnapshot
    {
      try await InstallerJobObservation.wait(
        fetch: { offset in
          try await self.jobStatus(hint, journalOffset: offset, otherBuild: otherBuild)
        },
        journal: journalProgress)
    }

    public func writeInstallConf(
      _ conf: InstallConf,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      authorization: MachineOwnerAuthorization
    ) async throws -> InstallConfHandoff {
      try await ping()
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        proxy.writeInstallConf(
          document: conf.serializedData,
          storeIdentifier: storeIdentifier,
          offsetBytes: offsetBytes,
          lengthBytes: lengthBytes,
          machineOwner: authorization.username,
          password: authorization.password
        ) { response, error in
          defer { handle.invalidate() }
          do {
            let payload = try InstallConfXPCCodec.decodeReply(data: response, error: error)
            gate.resume(returning: payload)
          } catch {
            gate.resume(throwing: error)
          }
        }
      }
      return try InstallConfXPCCodec.decode(data)
    }

    static func isMachServiceName(_ value: String) -> Bool {
      guard (3...255).contains(value.utf8.count),
        value.contains("."),
        value.first != ".",
        value.last != "."
      else {
        return false
      }
      return value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
          || byte == 45
          || byte == 46
      }
    }
  }

  enum InstallConfXPCCodec {
    static func encode(_ handoff: InstallConfHandoff) throws -> Data {
      try JSONEncoder().encode(handoff)
    }

    static func decode(_ data: Data) throws -> InstallConfHandoff {
      try JSONDecoder().decode(InstallConfHandoff.self, from: data)
    }

    static func encodeReply(
      error: (any Error)?,
      encrypt: Bool
    ) -> (Data?, NSError?) {
      func payload(_ handoff: InstallConfHandoff) -> (Data?, NSError?) {
        do {
          return (try encode(handoff), nil)
        } catch {
          return (nil, EngineXPCErrorBridge.serviceError(for: error))
        }
      }
      guard let error else {
        return payload(.recorded)
      }
      if let esp = error as? InstallConfESPError {
        return payload(
          esp.followedConfirmedWrite ? .unconfirmed(encrypt: encrypt) : .notRecorded
        )
      }
      return (nil, EngineXPCErrorBridge.serviceError(for: error))
    }

    static func decodeReply(data: Data?, error: NSError?) throws -> Data {
      if let error {
        throw EngineXPCErrorBridge.submissionError(error)
      }
      guard let data, !data.isEmpty else {
        throw EngineXPCSubmissionError.emptyResponse
      }
      return data
    }
  }

  enum EngineXPCErrorBridge {
    private static let recoveryAuthorizationDomain =
      InstallerProductIdentity.appIdentifier + ".recovery-authorization"
    private static let recoveryAuthorizationCode = 1
    // Dedicated domain so the app can tell "wrong password" from every other
    // helper rejection. Skew-safe: an older app maps this unknown domain to the
    // generic helperRejected case exactly as it does today.
    static let machineOwnerAuthorizationDomain =
      InstallerProductIdentity.appIdentifier + ".machine-owner-authorization"
    static let machineOwnerAuthorizationCode = 1
    // The engine's typed failure. The code is the EngineFailureReason raw
    // value; userInfo carries only an exit status, a Boolean and one redacted,
    // bounded summary line. Never the stderr tail, never credentials.
    // Skew-safe like the domain above: an older app sees helperRejected.
    static let engineFailureDomain = InstallerProductIdentity.appIdentifier + ".engine-failure"
    static let exitStatusKey = "exitStatus"
    static let diskUnchangedKey = "diskUnchanged"
    static let summaryKey = "summary"

    static func serviceError(for error: any Error) -> NSError {
      if let executionError = error as? PinnedAsahiEngineExecutionError,
        case .engineFailed(let report) = executionError
      {
        let notice = report.notice
        return NSError(
          domain: engineFailureDomain,
          code: notice.reason.rawValue,
          userInfo: [
            exitStatusKey: NSNumber(value: notice.exitStatus),
            diskUnchangedKey: NSNumber(value: notice.diskUnchanged),
            summaryKey: EngineFailureNotice.sanitizedSummary(notice.summary) as NSString,
          ]
        )
      }
      if let executionError = error
        as? PinnedAsahiEngineExecutionError,
        executionError == .recoveryAuthorizationFailed
      {
        return NSError(
          domain: recoveryAuthorizationDomain,
          code: recoveryAuthorizationCode,
          userInfo: [:]
        )
      }
      if let helperError = error as? ClosedEngineHelperError,
        helperError == .invalidMachineOwnerCredentials
      {
        return NSError(
          domain: machineOwnerAuthorizationDomain,
          code: machineOwnerAuthorizationCode,
          userInfo: [:]
        )
      }
      return error as NSError
    }

    static func submissionError(
      _ error: NSError
    ) -> EngineXPCSubmissionError {
      if error.domain == recoveryAuthorizationDomain,
        error.code == recoveryAuthorizationCode
      {
        return .recoveryAuthorizationFailed
      }
      if error.domain == machineOwnerAuthorizationDomain,
        error.code == machineOwnerAuthorizationCode
      {
        return .machineOwnerCredentialsRejected
      }
      if error.domain == engineFailureDomain {
        let exitStatus = (error.userInfo[exitStatusKey] as? NSNumber)?.int32Value ?? -1
        let unchanged = error.userInfo[diskUnchangedKey] as? NSNumber
        // Only an explicit Boolean true counts; anything else makes no claim.
        let diskUnchanged =
          unchanged.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return .engineFailed(
          EngineFailureNotice(
            reason: EngineFailureReason(rawValue: error.code) ?? .unclassified,
            exitStatus: exitStatus,
            diskUnchanged: diskUnchanged,
            summary: error.userInfo[summaryKey] as? String ?? ""
          )
        )
      }
      return .helperRejected(
        domain: error.domain,
        code: error.code
      )
    }
  }

  public enum RecoveryAuthorizationRetryPolicy {
    public static func isEligible(after error: any Error) -> Bool {
      guard let submissionError = error as? EngineXPCSubmissionError
      else {
        return false
      }
      return submissionError == .recoveryAuthorizationFailed
    }
  }

  enum EngineCodeSigningRequirement {
    static func isValid(_ value: String) -> Bool {
      guard !value.isEmpty, value.utf8.count <= 4_096 else {
        return false
      }
      var requirement: SecRequirement?
      let status = SecRequirementCreateWithString(
        value as CFString,
        SecCSFlags(),
        &requirement
      )
      return status == errSecSuccess && requirement != nil
    }
  }

  private final class SendableXPCConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
      self.connection = connection
    }

    func invalidate() {
      connection.invalidate()
    }
  }

  /// One-shot resume for `ping`, the same shape as the reply gate below.
  private final class EngineXPCPingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?

    init(continuation: CheckedContinuation<Bool, any Error>) {
      self.continuation = continuation
    }

    func resume(returning value: Bool) {
      takeContinuation()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Bool, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }

  private final class EngineXPCFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
  }

  private final class EngineXPCOptionalBoolGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?

    init(continuation: CheckedContinuation<Bool?, Never>) {
      self.continuation = continuation
    }

    func resume(returning value: Bool?) {
      lock.lock()
      let candidate = continuation
      continuation = nil
      lock.unlock()
      candidate?.resume(returning: value)
    }
  }

  private final class EngineXPCStringGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(continuation: CheckedContinuation<String, Never>) {
      self.continuation = continuation
    }

    func resume(returning value: String) {
      lock.lock()
      let candidate = continuation
      continuation = nil
      lock.unlock()
      candidate?.resume(returning: value)
    }
  }

  private final class EngineXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(continuation: CheckedContinuation<Data, any Error>) {
      self.continuation = continuation
    }

    func resume(returning data: Data) {
      takeContinuation()?.resume(returning: data)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Data, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }

  private final class EngineXPCVoidGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
      self.continuation = continuation
    }

    func resume(returning _: Void) {
      takeContinuation()?.resume(returning: ())
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Void, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }
#endif
