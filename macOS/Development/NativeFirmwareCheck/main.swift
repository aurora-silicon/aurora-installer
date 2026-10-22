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
      if (CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "policy")
        || CommandLine.arguments == [CommandLine.arguments[0], "policy-live"]
      {
        let inputs: [String: Data]
        if CommandLine.arguments[1] == "policy-live" {
          guard let live = try NeoRegulatoryPolicy.liveInputs() else {
            throw RestoreFailure("The live macOS policy tables do not match the pins.")
          }
          inputs = live
        } else {
          let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
          inputs = try Dictionary(
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
        }
        let policies = try NeoRegulatoryPolicy.derive(inputs)
        func inventory(_ files: [String: Data], strip: String = "") -> String {
          let index = files.keys.sorted().map { name in
            let sha = SHA256.hash(data: files[name]!).map { String(format: "%02x", $0) }.joined()
            return String(name.dropFirst(strip.count)) + "\t" + sha + "\n"
          }.joined()
          return SHA256.hash(data: Data(index.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let v1 = policies.filter { $0.key.contains("/policy/") }
        let v2 = policies.filter { $0.key.contains("/policy-v2/") }
        let report: [String: Any] = [
          "v1Count": v1.count, "v1InventorySHA256": inventory(v1),
          "v2Count": v2.count, "v2InventorySHA256": inventory(v2, strip: "mediatek/mt7932/"),
          "source": CommandLine.arguments[1] == "policy-live"
            ? "live-macOS" : "authenticated-inputs",
        ]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        return
      }
      if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "multitouch" {
        let path = CommandLine.arguments[2]
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RestoreFailure("Cannot open the firmware input.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG,
          info.st_size > 0 && info.st_size <= 16 << 20
        else { throw RestoreFailure("Firmware input exceeds its file budget.") }
        let input = try file.read(upToCount: Int(info.st_size) + 1) ?? Data()
        guard input.count == info.st_size else { throw RestoreFailure("Firmware input changed.") }
        let outputs = try MultitouchFirmware.convert(input, machine: CommandLine.arguments[3])
        func digest(_ data: Data) -> String {
          SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let report: [String: Any] = [
          "sourceSHA256": digest(input),
          "files": outputs.mapValues {
            ["bytes": $0.count, "sha256": digest($0)] as [String: Any]
          },
        ]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(
            withJSONObject: report, options: [.sortedKeys]) + Data([10]))
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
        ["extract", "extract-ipsw", "verify", "zip"].contains(CommandLine.arguments[1])
      else {
        throw RestoreFailure(
          "usage: AuroraFirmwareCheck extract|extract-ipsw|verify|zip OUTPUT [CHECKPOINT]; or policy INPUT; or policy-live; or multitouch INPUT MACHINE"
        )
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
      let extractor = FirmwareExtractor(
        preferLivePolicyTables: CommandLine.arguments[1] != "extract-ipsw")
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
