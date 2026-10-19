import AuroraFirmware
import Darwin
import Foundation

@main struct AuroraFirmwareCheck {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 3,
        ["extract", "verify"].contains(CommandLine.arguments[1])
      else { throw RestoreFailure("usage: AuroraFirmwareCheck extract|verify OUTPUT") }
      let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
      let extractor = FirmwareExtractor()
      let receipt: FirmwareExtractionReceipt
      if CommandLine.arguments[1] == "verify" {
        receipt = try extractor.verify(plan, at: output)
      } else {
        receipt = try await withDeadline(seconds: 180) {
          try await extractor.extract(plan, to: output) { update in
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
