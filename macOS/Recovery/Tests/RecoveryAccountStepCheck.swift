@main struct Check {
  typealias Step = RecoveryAccountStep

  static func main() {
    let phases: [String?] = [
      nil, "allocating", "creating", "prepared", "awaiting-ownership", "finalized",
    ]
    for deferred in [false, true] {
      for moment in [Step.Moment.finished, .reopened] {
        // Not required: no account flags; reopening keeps the repair screen.
        let none = Step.resolve(required: false, phase: nil, deferred: deferred, moment: moment)
        precondition(!none.accountOptional && !none.accountNeedsAuthorization)
        precondition(none.stage == (moment == .finished ? .complete : nil))
        for phase in phases {
          let step = Step.resolve(required: true, phase: phase, deferred: deferred, moment: moment)
          // An account whose creation stopped part way asks for its password,
          // whenever Recovery shows it.
          if phase == "allocating" || phase == "creating" {
            precondition(step.stage == .account, "\(phase!) \(moment)")
            precondition(step.accountNeedsAuthorization && !step.accountOptional)
            continue
          }
          // Nothing else ever opens the account screen.
          precondition(step.stage != .account, "\(String(describing: phase)) \(moment)")
          precondition(step.accountOptional == (phase == nil))
          precondition(
            step.accountNeedsAuthorization == (phase != nil && phase != "finalized"))
          switch moment {
          case .finished:
            precondition(step.stage == .complete)
          case .reopened:
            // Prepared / awaiting-ownership after a deferring restart: the
            // repair screen stays, so Restore, Debug and Proxy stay reachable.
            let resumes = !deferred && phase != "finalized"
            precondition(
              step.stage == (resumes ? .complete : nil),
              "\(String(describing: phase)) deferred=\(deferred)")
          }
        }
      }
    }
    // The review's case: an account waiting for ownership, deferred by
    // Restart, then Recovery opened to repair startup.
    for phase in ["prepared", "awaiting-ownership"] {
      precondition(
        Step.resolve(required: true, phase: phase, deferred: true, moment: .reopened).stage == nil)
    }
    print("recovery-account-step: all checks passed")
  }
}
