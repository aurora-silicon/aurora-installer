import CryptoKit
import Foundation

// The recipe is compiled into the library: a launchd-installed helper carries
// its inputs without relying on an app bundle or a SwiftPM build directory.
let arguments = CommandLine.arguments
let digest = "40686fb3b064e35205cae8dc7061f0406c154326301f9e8dcb17d82df3e9c4b3"
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
