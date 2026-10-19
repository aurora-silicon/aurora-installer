import AuroraFirmware
import Darwin
import Foundation

@main struct AuroraFirmwareCheck {
  static func main() async {
    do {
      guard [3, 4].contains(CommandLine.arguments.count),
        ["extract", "verify"].contains(CommandLine.arguments[1])
      else { throw RestoreFailure("usage: AuroraFirmwareCheck extract|verify OUTPUT [CHECKPOINT]") }
      let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
      let extractor = FirmwareExtractor()
      let checkpoint = CommandLine.arguments.count == 4
        ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true) : nil
      let receipt: FirmwareExtractionReceipt
      if CommandLine.arguments[1] == "verify" {
        receipt = try extractor.verify(plan, at: output)
      } else {
        receipt = try await withDeadline(seconds: 180) {
          try await extractor.extract(plan, to: output, cacheDirectory: checkpoint) { update in
            let line = "\(update.stage.rawValue) \(update.completedBytes)/\(update.totalBytes)\n"
            FileHandle.standardError.write(Data(line.utf8))
          }
        }
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      FileHandle.standardOutput.write(try encoder.encode(receipt) + Data([10]))
    } catch {
      FileHandle.standardError.write(Data("Native firmware check failed: \(error)\n".utf8))
      exit(1)
    }
  }
}
