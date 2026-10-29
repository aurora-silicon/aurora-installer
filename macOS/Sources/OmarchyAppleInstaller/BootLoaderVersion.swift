import Foundation

/// The bootloader a Stage 1 image carries, from its version marker. aura, Aurora's
/// bootloader, writes `##aura_ver##<version>`; installs made before the switch
/// (asahi m1n1, Aurora's m1n1 and early aura) carry `##m1n1_ver##<version>`.
/// Both are the same raw image format, so a legacy install is upgraded in place.
struct BootLoaderVersion: Codable, Equatable, Sendable, CustomStringConvertible {
  enum Loader: String, Codable, Sendable {
    case aura
    case m1n1
  }

  static let auraMarker = Data("##aura_ver##".utf8)
  static let legacyMarker = Data("##m1n1_ver##".utf8)

  let loader: Loader
  let version: String

  /// A pre-aura install, which should be offered the aura upgrade.
  var isLegacy: Bool { loader != .aura }

  /// "aura 1.0b1" or "m1n1 v1.6.1".
  var description: String { "\(loader.rawValue) \(version)" }

  /// aura's marker first, then the legacy one; nil when neither is there. The
  /// version runs to the first NUL.
  static func find(in image: Data) -> BootLoaderVersion? {
    for (loader, marker) in [(Loader.aura, auraMarker), (.m1n1, legacyMarker)] {
      guard let range = image.range(of: marker) else { continue }
      let value = image[range.upperBound...].prefix { $0 != 0 }
      return BootLoaderVersion(loader: loader, version: String(decoding: value, as: UTF8.self))
    }
    return nil
  }
}
