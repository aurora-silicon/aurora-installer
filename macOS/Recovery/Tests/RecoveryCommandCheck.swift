@main struct RecoveryCommandCheck {
  static func main() {
    precondition(RecoveryCommand(["recover"]) == .recover)
    precondition(RecoveryCommand(["setup"]) == .setup)
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
    ] {
      precondition(RecoveryCommand(arguments) == nil, "\(arguments)")
    }
    for command in ["recover", "setup", "restart", "debug on/off", "proxy on/off"] {
      precondition(RecoveryCommand.usage.contains(command), command)
    }

    precondition(RecoveryPasswordInput.password("1111") == "1111")
    precondition(RecoveryPasswordInput.password("pass word ") == "pass word ")
    precondition(RecoveryPasswordInput.password("crlf\r") == "crlf")
    for line in [nil, "", "\r", "a\0b", "a\rb"] as [String?] {
      precondition(RecoveryPasswordInput.password(line) == nil, String(describing: line))
    }
    precondition(RecoveryPasswordInput.message.contains("standard input"))
    precondition(RecoveryPasswordInput.message.contains("Nothing was changed"))
    print("RecoveryCommandCheck: OK")
  }
}
