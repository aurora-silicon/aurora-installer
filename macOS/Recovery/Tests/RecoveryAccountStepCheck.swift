@main struct Check {
  typealias Step = RecoveryAccountStep

  static func main() {
    let phases: [String?] = [
      nil, "allocating", "creating", "prepared", "awaiting-ownership", "finalized",
    ]
    for moment in [Step.Moment.finished, .reopened] {
      // Not required: no account flags; reopening keeps the repair screen.
      let none = Step.resolve(required: false, phase: nil, moment: moment)
      precondition(!none.accountOptional && !none.accountNeedsAuthorization)
      precondition(!none.accountUnfinished)
      precondition(none.stage == (moment == .finished ? .complete : nil))
      for phase in phases {
        let step = Step.resolve(required: true, phase: phase, moment: moment)
        let label = "\(String(describing: phase)) \(moment)"
        let unfinished = phase == "allocating" || phase == "creating"
        precondition(step.accountOptional == (phase == nil), label)
        precondition(
          step.accountNeedsAuthorization == (phase != nil && phase != "finalized"), label)
        precondition(step.accountUnfinished == unfinished, label)
        switch moment {
        case .finished:
          // Only a creation that stopped part way asks for its password.
          precondition(step.stage == (unfinished ? .account : .complete), label)
        case .reopened:
          // Every phase, however the last restart happened: the repair
          // screen stays, so Restore, Debug and Proxy stay reachable.
          precondition(step.stage == nil, label)
        }
      }
    }
    print("recovery-account-step: all checks passed")
  }
}
