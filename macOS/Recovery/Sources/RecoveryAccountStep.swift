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
  /// The account's creation stopped part way: setting it up again asks for
  /// its password.
  let accountUnfinished: Bool

  /// `required` is the receipt's `recoveryAccountRequired`.
  static func resolve(required: Bool, phase: String?, moment: Moment) -> Self {
    let optional = required && phase == nil
    let needsAuthorization = required && phase != nil && phase != "finalized"
    // Only an account whose creation stopped part way needs its password
    // again. One that is created and waits only for ownership never sends
    // the person anywhere: Restart starts Aurora and defers it.
    let unfinished = needsAuthorization && ["allocating", "creating"].contains(phase ?? "")
    let stage: Stage?
    switch moment {
    case .finished:
      stage = unfinished ? .account : .complete
    case .reopened:
      // Recovery opened again is there to repair startup: the repair screen
      // (Restore, Enable Debug, Enable Proxy) always stays, whatever the
      // account's state, and however the last restart happened. An optional
      // or unfinished account stays reachable from Utilities → Create
      // Recovery Account….
      stage = nil
    }
    return Self(
      stage: stage, accountOptional: optional, accountNeedsAuthorization: needsAuthorization,
      accountUnfinished: unfinished)
  }
}
