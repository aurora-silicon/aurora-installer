import AuroraFirmware
import CryptoKit
import Darwin
import Foundation

private actor MeasuredIPSWReader: FirmwareRangeReading {
  nonisolated let sizeBytes: Int
  private let source: IPSWHTTPRangeReader
  private var completedBytes = 0
  init(_ source: IPSWHTTPRangeReader) {
    self.source = source
    sizeBytes = source.sizeBytes
  }
  func read(offset: Int, count: Int) async throws -> Data {
    let bytes = try await source.read(offset: offset, count: count)
    completedBytes += bytes.count
    return bytes
  }
  func transferred() -> Int { completedBytes }
}

@main struct AuroraFirmwareCheck {
  static func main() async {
    do {
      if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "policy" {
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let inputs = try Dictionary(
          uniqueKeysWithValues: NeoRegulatoryPolicy.inputSHA256.keys.map { name in
            let file = try FileHandle(
              forReadingFrom: directory.appendingPathComponent("sunrise/" + name))
            defer { try? file.close() }
            let bytes = try file.read(upToCount: (32 << 20) + 1) ?? Data()
            guard bytes.count <= 32 << 20 else {
              throw RestoreFailure("Regulatory input exceeds its budget.")
            }
            return (name, bytes)
          })
        let policies = try NeoRegulatoryPolicy.derive(inputs)
        let index = policies.keys.sorted().map { name in
          let sha = SHA256.hash(data: policies[name]!).map { String(format: "%02x", $0) }.joined()
          return name + " " + sha + "\n"
        }.joined()
        let digest = SHA256.hash(data: Data(index.utf8)).map { String(format: "%02x", $0) }.joined()
        guard policies.count == 244,
          digest == "b1578bcc83fb3270c4fcef4f88de37b384ac1c46c8bc7093c5b2ea867d1c08c1"
        else {
          throw RestoreFailure("Regulatory output differs from the reference inventory.")
        }
        let report: [String: Any] = ["policyCount": policies.count, "inventorySHA256": digest]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        return
      }
      if CommandLine.arguments == [CommandLine.arguments[0], "plan"] {
        let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
        let report: [String: Any] = [
          "deviceIdentifier": plan.deviceIdentifier, "recipeSHA256": plan.recipeSHA256,
          "outputCount": plan.outputs.count, "rangeBytes": plan.authenticatedRangeBytes,
        ]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(
            withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        return
      }
      guard [3, 4].contains(CommandLine.arguments.count),
        ["extract", "verify", "zip"].contains(CommandLine.arguments[1])
      else {
        throw RestoreFailure("usage: AuroraFirmwareCheck extract|verify|zip OUTPUT [CHECKPOINT]")
      }
      let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
      if CommandLine.arguments[1] == "zip" {
        let source = try MeasuredIPSWReader(
          IPSWHTTPRangeReader(url: plan.sourceURL, sizeBytes: plan.sourceSizeBytes))
        let archive = try await withDeadline(seconds: 180) { try await IPSWArchive.open(source) }
        guard let image = archive.members.first(where: { $0.name == plan.systemImageMemberName }),
          let manifest = archive.members.first(where: { $0.name == "BuildManifest.plist" }),
          image.compressionMethod == 0
        else { throw RestoreFailure("Required restore-image members are absent.") }
        let offset = try await archive.dataOffset(for: image)
        guard offset == plan.systemImageDataOffset else {
          throw RestoreFailure("ZIP64 image offset differs from authenticated recipe.")
        }
        let bytes = try await archive.read(manifest, maximumBytes: 32 * 1024 * 1024)
        _ = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        let report: [String: Any] = [
          "sourceSizeBytes": plan.sourceSizeBytes, "memberCount": archive.members.count,
          "systemImageMember": image.name, "systemImageDataOffset": offset,
          "manifestSizeBytes": bytes.count,
          "manifestSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
          "returnedRangeBytes": await source.transferred(),
        ]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) + Data([10]))
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
