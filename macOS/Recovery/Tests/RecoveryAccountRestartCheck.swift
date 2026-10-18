import Foundation

struct RecoveryFailure: Error { let message: String }

@main struct RecoveryAccountRestartCheck {
  enum Injected: Error { case failure }
  static func main() throws {
    let original: [String: Any] = [
      "status": "installed", "recoveryAccountRequired": true, "stage1SHA256": "unchanged",
    ]
    var calls = [String]()
    try RecoveryAccountRestart.perform(
      receipt: original, hasPendingInstallation: false, isTargetDefault: { true },
      persist: { updated in
        calls.append("persist")
        precondition(updated["recoveryAccountDeferred"] as? Bool == true)
        precondition(updated["recoveryAccountRequired"] as? Bool == true)
        precondition(updated["stage1SHA256"] as? String == "unchanged")
      }, restart: { calls.append("restart") })
    precondition(calls == ["persist", "restart"])
    for (receipt, pending) in [
      (["status": "prepared"], false), (["status": "installed"], true),
    ] {
      do {
        try RecoveryAccountRestart.perform(
          receipt: receipt, hasPendingInstallation: pending, isTargetDefault: { true },
          persist: { _ in preconditionFailure("Unfinished setup changed") },
          restart: { preconditionFailure("Unfinished setup restarted") })
        preconditionFailure("Unfinished setup accepted")
      } catch is RecoveryFailure {}
    }
    do {
      try RecoveryAccountRestart.perform(
        receipt: original, hasPendingInstallation: false, isTargetDefault: { true },
        persist: { _ in throw Injected.failure },
        restart: { preconditionFailure("Unsaved deferral restarted") })
      preconditionFailure("Write failure lost")
    } catch Injected.failure {}
    calls = []
    do {
      try RecoveryAccountRestart.perform(
        receipt: original, hasPendingInstallation: false, isTargetDefault: { true },
        persist: { _ in calls.append("persist") }, restart: { throw Injected.failure })
      preconditionFailure("Restart failure lost")
    } catch Injected.failure {}
    precondition(calls == ["persist"])
    do {
      try RecoveryAccountRestart.perform(
        receipt: original, hasPendingInstallation: false, isTargetDefault: { false },
        persist: { _ in preconditionFailure("Wrong boot target persisted") },
        restart: { preconditionFailure("Wrong boot target restarted") })
      preconditionFailure("Unselected target accepted")
    } catch is RecoveryFailure {}
    var reads = 0
    do {
      try RecoveryAccountRestart.perform(
        receipt: original, hasPendingInstallation: false,
        isTargetDefault: {
          reads += 1
          return reads == 1
        }, persist: { _ in },
        restart: { preconditionFailure("Changed boot target restarted") })
      preconditionFailure("Changed target accepted")
    } catch is RecoveryFailure {}
    print("PASS restart ordering, deferred account resume and no restart before committed setup")
  }
}
