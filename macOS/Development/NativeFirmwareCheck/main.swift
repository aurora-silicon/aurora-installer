import AuroraFirmware
import Darwin
import Foundation

@main struct AuroraFirmwareCheck {
  static func main() async {
    do {
      guard [3, 4].contains(CommandLine.arguments.count),
        ["extract", "verify", "zip"].contains(CommandLine.arguments[1])
      else { throw RestoreFailure("usage: AuroraFirmwareCheck extract|verify|zip OUTPUT [CHECKPOINT]") }
      let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
      if CommandLine.arguments[1] == "zip" {
        let source = try IPSWHTTPRangeReader(url: plan.sourceURL, sizeBytes: plan.sourceSizeBytes)
        let archive = try await withDeadline(seconds: 180) { try await IPSWArchive.open(source) }
        guard let image = archive.members.first(where: { $0.name == plan.systemImageMemberName }),
          let manifest = archive.members.first(where: { $0.name == "BuildManifest.plist" }),
          image.compressionMethod == 0
        else { throw RestoreFailure("Required restore-image members are absent.") }
        let offset = try await archive.dataOffset(for: image)
        guard offset == plan.systemImageDataOffset else {
          throw RestoreFailure("ZIP64 image offset differs from authenticated recipe.")
        }
        let bytes = try await archive.read(manifest, maximumBytes: 8 * 1024 * 1024)
        _ = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        let report: [String: Any] = [
          "sourceSizeBytes": plan.sourceSizeBytes, "memberCount": archive.members.count,
          "systemImageMember": image.name, "systemImageDataOffset": offset,
          "manifestSizeBytes": bytes.count,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) + Data([10]))
        return
      }
      let extractor = FirmwareExtractor()
      let checkpoint =
        CommandLine.arguments.count == 4
        ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true) : nil
      let receipt: FirmwareExtractionReceipt
      if CommandLine.arguments[1] == "verify" {
        receipt = try extractor.verify(plan, at: output)
      } else {
        receipt = try await withDeadline(seconds: 180) {
          let progress: @Sendable (FirmwareExtractionProgress) -> Void = { update in
            let line = "\(update.stage.rawValue) \(update.completedBytes)/\(update.totalBytes)\n"
            FileHandle.standardError.write(Data(line.utf8))
          }
          if let checkpoint {
            return try await extractor.extractOrResume(
              plan, to: output, cacheDirectory: checkpoint, progress: progress)
          }
          return try await extractor.extract(plan, to: output, progress: progress)
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
