/// What the `aura` command in Recovery is asked to do. Recovery Terminal and a
/// remote Recovery shell reach the same actions as the window.
enum RecoveryCommand: Equatable {
  /// Restore Stage 2 and the retained firmware from the recovery baseline.
  case recover
  /// Run setup as Continue does: enroll the startup software for this
  /// installation, or the staged Stage 1 update. The owner's password is read
  /// from standard input, never from the command line.
  case setup
  /// Restart into the installation as Restart does on the last screen. A
  /// recovery account not created yet is deferred, as "Skip, Restart Now" does.
  case restart
  /// Turn an `aura-debug` or `aura-proxy` boot argument on or off.
  case bootArgument(flag: String, enabled: Bool)

  static let usage = "Usage: aura [recover | setup | restart | debug on/off | proxy on/off]"

  init?(_ arguments: [String]) {
    switch arguments {
    case ["recover"]: self = .recover
    case ["setup"]: self = .setup
    case ["restart"]: self = .restart
    case ["debug", "on"], ["debug", "off"], ["proxy", "on"], ["proxy", "off"]:
      self = .bootArgument(flag: "aura-" + arguments[0], enabled: arguments[1] == "on")
    default: return nil
    }
  }
}

/// The owner's password for `aura setup`: the first line of standard input.
enum RecoveryPasswordInput {
  static let message =
    "aura setup reads the password of this installation's owner as one line on standard input. Nothing was changed."

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
