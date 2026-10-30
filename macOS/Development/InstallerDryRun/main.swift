import AuroraAppleInstallerTrustCore
import AuroraFirmware
import AuroraInstallerUXCore
import Darwin
import Foundation

/// `InstallerDryRun --machine M.json --metadata installer-data.json
///  --payload-digest sha256:… [--esp-archive esp.zip]
///  [--experimental bootloader-only|full-send]`
///
/// Replays a recorded machine through native inspection, planning and
/// boot-chain admission and prints the result as JSON. It reads only the
/// files it is given and has no disk, helper or network authority.
@main struct InstallerDryRun {
  static func main() async {
    do {
      var options = [String: String]()
      var arguments = CommandLine.arguments.dropFirst()
      while let key = arguments.popFirst() {
        guard key.hasPrefix("--"), let value = arguments.popFirst() else { throw usage }
        options[String(key.dropFirst(2))] = value
      }
      guard let machine = options["machine"], let metadata = options["metadata"],
        let digest = options["payload-digest"],
        Set(options.keys).isSubset(of: [
          "machine", "metadata", "payload-digest", "esp-archive", "experimental",
        ])
      else { throw usage }
      var experimental: ExperimentalHardwareLevel?
      if let level = options["experimental"] {
        guard let parsed = ExperimentalHardwareLevel(rawValue: level) else { throw usage }
        experimental = parsed
      }
      var archive: IPSWArchive?
      if let path = options["esp-archive"] {
        archive = try await IPSWArchive.open(LocalFileRangeReader(path: path))
      }
      let output = try await NativeInstallerDryRun.run(
        machine: Data(contentsOf: URL(fileURLWithPath: machine)),
        metadata: Data(contentsOf: URL(fileURLWithPath: metadata)),
        payloadDigest: digest, archive: archive, experimental: experimental)
      FileHandle.standardOutput.write(try withStage1Caution(output))
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      FileHandle.standardError.write(Data("dry run failed: \(error)\n".utf8))
      exit(1)
    }
  }

  /// Adds the warning the plan screen shows before a fresh install on a Mac
  /// whose iBoot refuses, or may refuse, the common Stage 1: the
  /// `stage1CautionPanel` text and the acknowledgement the owner ticks. The
  /// app picks the Mac by `hw.targettype`; a recorded Mac has its identifier.
  static func withStage1Caution(_ output: Data) throws -> Data {
    guard var result = try JSONSerialization.jsonObject(with: output) as? [String: Any],
      let device = result["device_identifier"] as? String,
      let reason = Stage1Caution.reason(for: device)
    else { return output }
    result["stage1_caution"] = [
      "headline": PlainLanguage.stage1CautionHeadline, "reason": reason,
      "recovery": PlainLanguage.stage1CautionRecovery,
      "acknowledgement": PlainLanguage.planAcknowledgement(
        resizesMacOS: false, stage1Caution: true),
      "acknowledgement_resize": PlainLanguage.planAcknowledgement(
        resizesMacOS: true, stage1Caution: true),
    ]
    return try JSONSerialization.data(
      withJSONObject: result, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
  }

  static let usage = NSError(
    domain: "InstallerDryRun", code: 64,
    userInfo: [
      NSLocalizedDescriptionKey:
        "usage: InstallerDryRun --machine M.json --metadata META.json --payload-digest sha256:HEX [--esp-archive ESP.zip] [--experimental bootloader-only|full-send]"
    ])
}

struct LocalFileRangeReader: FirmwareRangeReading {
  let sizeBytes: Int
  let handle: FileHandle

  init(path: String) throws {
    handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    sizeBytes = Int(try handle.seekToEnd())
  }

  func read(offset: Int, count: Int) async throws -> Data {
    guard offset >= 0, count >= 0, offset + count <= sizeBytes else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try handle.seek(toOffset: UInt64(offset))
    guard let data = try handle.read(upToCount: count), data.count == count else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return data
  }
}
