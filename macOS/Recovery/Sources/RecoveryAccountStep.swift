/// Which screen the recovery account sends the person to, from the
/// installation receipt and the account's recorded phase.
struct RecoveryAccountStep: Equatable {
  enum Moment: Equatable {
    /// Setup or a restore just finished on this screen.
    case finished
    /// Recovery opened again on an installation that is already set up.
    case reopened
  }

  /// The screen to show; nil keeps the one showing (the repair screen when
  /// Recovery opens again).
  let stage: Stage?
  /// The account wasn't started: the completion screen offers it.
  let accountOptional: Bool
  /// The account exists but isn't a volume owner yet.
  let accountNeedsAuthorization: Bool

  /// `required` is the receipt's `recoveryAccountRequired`, `deferred` its
  /// `recoveryAccountDeferred` (set when Restart left the account as it was).
  static func resolve(required: Bool, phase: String?, deferred: Bool, moment: Moment) -> Self {
    let optional = required && phase == nil
    let needsAuthorization = required && phase != nil && phase != "finalized"
    // Only an account whose creation stopped part way needs its password
    // again. One that is created and waits only for ownership never sends
    // the person anywhere: Restart starts Aurora and defers it.
    let unfinished = ["allocating", "creating"].contains(phase ?? "")
    let stage: Stage?
    if needsAuthorization && unfinished {
      stage = .account
    } else {
      switch moment {
      case .finished:
        stage = .complete
      case .reopened:
        // Setup that finished but was never restarted resumes at its
        // completion screen. Once Restart deferred the account, or the
        // account is an owner, Recovery opens on the repair screen
        // (Restore, Enable Debug, Enable Proxy).
        stage = required && !deferred && phase != "finalized" ? .complete : nil
      }
    }
    return Self(
      stage: stage, accountOptional: optional, accountNeedsAuthorization: needsAuthorization)
  }
}
