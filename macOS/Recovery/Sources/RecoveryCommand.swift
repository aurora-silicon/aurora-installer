/// What the `aura` command in Recovery is asked to do. Recovery Terminal and a
/// remote Recovery shell reach the same actions as the window.
enum RecoveryCommand: Equatable {
  /// Restore Stage 2 and the retained firmware from the recovery baseline.
  case recover
  /// Run setup as Continue does: enroll the startup software for this
  /// installation. The owner's password is read from standard input, never
  /// from the command line.
  case setup
  /// Enroll the Stage 1 update the macOS installer staged, as Update does.
  /// The password is read as for setup.
  case update
  /// Restart into the installation as Restart does on the last screen. A
  /// recovery account not created yet is deferred, as "Skip, Restart Now" does.
  case restart
  /// Turn an `aura-debug` or `aura-proxy` boot argument on or off.
  case bootArgument(flag: String, enabled: Bool)

  static let usage =
    "Usage: aura [recover | setup | update | restart | debug on/off | proxy on/off]"

  init?(_ arguments: [String]) {
    switch arguments {
    case ["recover"]: self = .recover
    case ["setup"]: self = .setup
    case ["update"]: self = .update
    case ["restart"]: self = .restart
    case ["debug", "on"], ["debug", "off"], ["proxy", "on"], ["proxy", "off"]:
      self = .bootArgument(flag: "aura-" + arguments[0], enabled: arguments[1] == "on")
    default: return nil
    }
  }

  /// Why this command can't run, or nil. `updatePending`: a staged Stage 1
  /// update is waiting. `installed`: setup finished (a receipt and no pending
  /// journal), so the window offers only Restore; an interrupted setup isn't
  /// installed and may run again. The command line names the change, so setup
  /// never turns into an update or the other way round.
  func refusal(updatePending: Bool, installed: Bool) -> String? {
    switch self {
    case .setup where updatePending:
      return
        "A startup software update is waiting. Run aura update to install it. Nothing was changed."
    case .setup where installed:
      return
        "This installation is already set up. To restore its startup software, run aura recover. Nothing was changed."
    case .update where !updatePending:
      return "No startup software update is waiting. Nothing was changed."
    default:
      return nil
    }
  }
}

/// The owner's password for `aura setup` and `aura update`: the first line of
/// standard input, which must be piped or redirected into the command itself.
enum RecoveryPasswordInput {
  static let message =
    "aura setup and aura update read the password of this installation's owner as one line on standard input. Nothing was changed."
  static let terminalMessage =
    "aura setup and aura update read the owner's password from a pipe, not from the keyboard, which would show it. To type it, use the Aurora Installer window. Nothing was changed."

  /// The password in `line`, or nil when it is empty or holds a NUL, which the
  /// authorization prompt can't pass on.
  static func password(_ line: String?) -> String? {
    guard var password = line else { return nil }
    if password.hasSuffix("\r") { password.removeLast() }
    guard !password.isEmpty, !password.contains("\0"), !password.contains("\r") else {
      return nil
    }
    return password
  }
}
