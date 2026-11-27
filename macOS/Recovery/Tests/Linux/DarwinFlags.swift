import Glibc

// Linux stand-ins for the BSD file flags RecoveryFileTransaction keeps
// (Linux has no st_flags or chflags): every file has none, and setting none
// succeeds. Only Tests/Linux/run.sh compiles this; the app is macOS-only.
extension stat {
  // swift-format-ignore: AlwaysUseLowerCamelCase
  var st_flags: UInt32 { 0 }
}

func chflags(_ path: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
  flags == 0 ? 0 : -1
}
