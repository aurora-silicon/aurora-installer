#if os(macOS)
  import Darwin
  import Foundation

  protocol NativeRecoveryHandoffExecuting: Sendable {
    func execute(package: ImportedEngineHandoffPackage, journal: URL,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool) async throws -> Data
  }

  struct NativeRecoveryHandoffExecutor: NativeRecoveryHandoffExecuting {
    let platform: any NativeRecoveryHandoffOperating
    let owner: uid_t

    init() { platform = NativeRecoveryHandoffPlatform(); owner = 0 }
    init(platform: any NativeRecoveryHandoffOperating, owner: uid_t) {
      self.platform = platform
      self.owner = owner
    }

    func execute(package: ImportedEngineHandoffPackage, journal url: URL,
      authorization: MachineOwnerAuthorization, requirement: String, fullReadback: Bool) async throws -> Data {
      let journal = try NativeRecoveryJournal(url: url, package: package, owner: owner)
      let before = try journal.snapshot()
      if before.state == .prepared || before.state == .complete { return try journal.complete() }
      try journal.beginHandoff()
      let target = try await platform.prepare(package: package, snapshot: before,
        authorization: authorization, requirement: requirement,
        fullReadback: fullReadback || before.state == .started)
      do { try platform.select(target, authorization: authorization) }
      catch NativeHandoffValidationError.authorizationFailed {
        guard try journal.snapshot().state == .started else {
          throw NativeRecoveryJournalError.invalidState
        }
        throw PinnedAsahiEngineExecutionError.recoveryAuthorizationFailed
      }
      try journal.recordPrepared()
      return try journal.complete()
    }
  }
#endif
