import CryptoKit
import Foundation

// The recipes are compiled into the library: a launchd-installed helper carries
// its inputs without relying on an app bundle or a SwiftPM build directory.
//
//   AuroraFirmwareRecipeGenerator RECIPE OUTPUT
//     the Neo's sealed recipe (pinned below)
//   AuroraFirmwareRecipeGenerator speaker-tuning|radio-firmware INDEX OUTPUT RECIPE...
//     a restore image list (index pinned below) and every recipe it names,
//     each checked against the index
let arguments = CommandLine.arguments
let digest = "40686fb3b064e35205cae8dc7061f0406c154326301f9e8dcb17d82df3e9c4b3"
/// SHA-256 of Resources/speaker-tuning/index.json: the pinned macOS release
/// and restore images speaker tuning is read from.
/// SHA-256 of Resources/radio-firmware/index.json: the stub restore images
/// Wi-Fi firmware is read from.
let radioFirmwareIndexDigest = "7cdb0d0ae85a33a494ded4b1809e96f09f33d9bdc291cd1234ef2c3ba1824132"
let speakerTuningIndexDigest = "2f1dd2b7020e2ea5a8a216104519bde762681fbfaeb42c8953c5f4c50849c322"

func sha256(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func read(_ path: String, maximum: Int) throws -> Data {
  let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
  guard bytes.count <= maximum else { throw CocoaError(.fileReadTooLarge) }
  return bytes
}

do {
  let indexes: [String: (digest: String, type: String, key: String)] = [
    "speaker-tuning": (speakerTuningIndexDigest, "EmbeddedSpeakerTuningRecipes", "AID"),
    "radio-firmware": (radioFirmwareIndexDigest, "EmbeddedRadioFirmwareRecipes", ""),
  ]
  if arguments.count >= 4, let kind = indexes[arguments[1]] {
    let index = try read(arguments[2], maximum: 1_048_576)
    guard sha256(index) == kind.digest,
      let document = try JSONSerialization.jsonObject(with: index) as? [String: Any],
      let images = document["images"] as? [[String: Any]]
    else { throw CocoaError(.fileReadCorruptFile) }
    var pinned = [String: String]()
    for image in images {
      guard let build = image["build"] as? String,
        let recipes = image["recipes"] as? [String: String]
      else { throw CocoaError(.fileReadCorruptFile) }
      for (key, sha) in recipes { pinned["\(build)-\(kind.key)\(key).json"] = sha }
    }
    var entries = [String]()
    for path in arguments[4...] {
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard name != "index.json" else { continue }
      let bytes = try read(path, maximum: 1_048_576)
      guard pinned.removeValue(forKey: name) == sha256(bytes) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      entries.append("    \"\(name)\": Data(base64Encoded: \"\(bytes.base64EncodedString())\")!,")
    }
    // Every recipe the index names, and nothing else.
    guard pinned.isEmpty else { throw CocoaError(.fileNoSuchFile) }
    let source = """
      import Foundation
      enum \(kind.type) {
        static let indexSHA256 = "\(kind.digest)"
        static let index = Data(base64Encoded: "\(index.base64EncodedString())")!
        static let recipes: [String: Data] = [
      \(entries.isEmpty ? ":" : entries.sorted().joined(separator: "\n"))
        ]
      }

      """
    try source.write(to: URL(fileURLWithPath: arguments[3]), atomically: true, encoding: .utf8)
    exit(0)
  }
  guard arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
  let bytes = try read(arguments[1], maximum: 1_048_576)
  guard sha256(bytes) == digest else { throw CocoaError(.fileReadCorruptFile) }
  let source = """
    import Foundation
    enum EmbeddedFirmwareRecipe {
      static let sha256 = "\(digest)"
      static let bytes = Data(base64Encoded: "\(bytes.base64EncodedString())")!
    }

    """
  try source.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
} catch {
  FileHandle.standardError.write(Data("Cannot embed the sealed firmware recipes: \(error)\n".utf8))
  exit(1)
}
