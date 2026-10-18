import Foundation

/// Deferring the separate account never marks its ownership as completed.
/// Keep the normal Recovery resume path available after the restart.
enum RecoveryAccountRestart {
  static func perform(
    receipt: [String: Any], hasPendingInstallation: Bool,
    isTargetDefault: () throws -> Bool,
    persist: ([String: Any]) throws -> Void, restart: () throws -> Void
  ) throws {
    guard receipt["status"] as? String == "installed", !hasPendingInstallation else {
      throw RecoveryFailure(message: "Finish installing the startup software before restarting.")
    }
    guard try isTargetDefault() else {
      throw RecoveryFailure(
        message:
          "Select this installation in Apple menu → Startup Disk before restarting. Your Mac has not been restarted."
      )
    }
    var deferred = receipt
    deferred["recoveryAccountDeferred"] = true
    try persist(deferred)
    guard try isTargetDefault() else {
      throw RecoveryFailure(
        message: "The startup disk changed. Select this installation before restarting.")
    }
    try restart()
  }
}
