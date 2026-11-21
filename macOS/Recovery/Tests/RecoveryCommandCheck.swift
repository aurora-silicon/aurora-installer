@main struct RecoveryCommandCheck {
  static func main() {
    precondition(RecoveryCommand(["recover"]) == .recover)
    precondition(RecoveryCommand(["setup"]) == .setup)
    precondition(RecoveryCommand(["update"]) == .update)
    precondition(RecoveryCommand(["restart"]) == .restart)
    precondition(
      RecoveryCommand(["debug", "on"]) == .bootArgument(flag: "aura-debug", enabled: true))
    precondition(
      RecoveryCommand(["debug", "off"]) == .bootArgument(flag: "aura-debug", enabled: false))
    precondition(
      RecoveryCommand(["proxy", "on"]) == .bootArgument(flag: "aura-proxy", enabled: true))
    precondition(
      RecoveryCommand(["proxy", "off"]) == .bootArgument(flag: "aura-proxy", enabled: false))
    // The password never comes from the command line, and nothing else is accepted.
    for arguments in [
      [], ["setup", "secret"], ["setup", "--password", "secret"], ["restart", "now"], ["debug"],
      ["debug", "yes"], ["proxy", "on", "now"], ["Setup"], ["recover", "--force"], ["install"],
      ["update", "secret"],
    ] {
      precondition(RecoveryCommand(arguments) == nil, "\(arguments)")
    }
    for command in ["recover", "setup", "update", "restart", "debug on/off", "proxy on/off"] {
      precondition(RecoveryCommand.usage.contains(command), command)
    }

    // The command line names the change: setup never becomes an update or back.
    precondition(RecoveryCommand.setup.refusal(updatePending: false) == nil)
    precondition(RecoveryCommand.update.refusal(updatePending: true) == nil)
    precondition(
      RecoveryCommand.setup.refusal(updatePending: true)?.contains("Run aura update") == true)
    precondition(
      RecoveryCommand.update.refusal(updatePending: false)?.contains("Nothing was changed") == true)
    for command in [
      RecoveryCommand.recover, .restart, .bootArgument(flag: "aura-debug", enabled: true),
    ] {
      precondition(command.refusal(updatePending: true) == nil)
      precondition(command.refusal(updatePending: false) == nil)
    }

    precondition(RecoveryPasswordInput.password("1111") == "1111")
    precondition(RecoveryPasswordInput.password("pass word ") == "pass word ")
    precondition(RecoveryPasswordInput.password("crlf\r") == "crlf")
    for line in [nil, "", "\r", "a\0b", "a\rb"] as [String?] {
      precondition(RecoveryPasswordInput.password(line) == nil, String(describing: line))
    }
    precondition(RecoveryPasswordInput.message.contains("standard input"))
    precondition(RecoveryPasswordInput.message.contains("Nothing was changed"))
    precondition(RecoveryPasswordInput.terminalMessage.contains("Aurora Installer window"))
    precondition(RecoveryPasswordInput.terminalMessage.contains("Nothing was changed"))
    print("RecoveryCommandCheck: OK")
  }
}
