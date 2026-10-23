// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import RestoreImageCore

@main struct RestoreImageCLI {
  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["capabilities"] {
      print("restore-image firmware-ranges verify-stage1")
      return
    }
    guard
      args.count == 3
        || (args.count == 4 && ["firmware-ranges", "verify-stage1"].contains(args[0]))
    else {
      FileHandle.standardError.write(
        Data("usage: omarchy-restore-image INPUT_AEA INPUT_SHA256 OUTPUT_DMG\n".utf8))
      exit(64)
    }
    let task = Task {
      if args.count == 4 && args[0] == "verify-stage1" {
        try verifyStage1(URL(fileURLWithPath: args[1]), digest: args[2], size: args[3])
      } else if args.count == 4 {
        try await withDeadline(seconds: 240) {
          try await extractFirmwareRanges(
            URL(fileURLWithPath: args[1]), digest: args[2], output: URL(fileURLWithPath: args[3]))
        }
      } else {
        try await withDeadline(seconds: 1800) {
          try await decodeImage(
            URL(fileURLWithPath: args[0]), digest: args[1], output: URL(fileURLWithPath: args[2]))
        }
      }
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { value in
      let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
      source.setEventHandler { task.cancel() }
      source.resume()
      return source
    }
    defer {
      for source in sources { source.cancel() }
    }
    do { try await task.value } catch {
      FileHandle.standardError.write(
        Data("omarchy-restore-image: \(error.localizedDescription)\n".utf8))
      exit((error as? RestoreFailure)?.fallback == true ? 75 : 1)
    }
  }
}
