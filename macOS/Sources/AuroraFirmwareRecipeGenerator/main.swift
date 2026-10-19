import CryptoKit
import Foundation

// The recipe is compiled into the library: a launchd-installed helper carries
// its inputs without relying on an app bundle or a SwiftPM build directory.
let arguments = CommandLine.arguments
let digest = "595d5acf3c4bca51c5749fc45691a7873f9216e2527436be9101757aae472834"
do {
  guard arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
  let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
  guard bytes.count <= 1_048_576,
    SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest
  else { throw CocoaError(.fileReadCorruptFile) }
  let source = """
  import Foundation
  enum EmbeddedFirmwareRecipe {
    static let sha256 = "\(digest)"
    static let bytes = Data(base64Encoded: "\(bytes.base64EncodedString())")!
  }

  """
  try source.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
} catch {
  FileHandle.standardError.write(Data("Cannot embed the sealed firmware recipe: \(error)\n".utf8))
  exit(1)
}
