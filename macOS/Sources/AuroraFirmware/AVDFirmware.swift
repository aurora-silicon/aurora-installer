// SPDX-License-Identifier: MIT
import Foundation

/// Optional per-SoC MCPU reload images. Firmware is never part of the installer.
/// Source identity and ownership must be admitted by the caller before conversion.
public enum AVDFirmware {
  public struct Source: Equatable, Sendable {
    public let component: String
    public let imageType: String
  }

  public struct SoC: Equatable, Sendable {
    public let size: Int?
    public let version: UInt32?
    public let preloaded: Bool
    public let sources: [Source]

    init(size: Int? = nil, version: UInt32? = nil, preloaded: Bool = false, sources: [Source] = [])
    {
      self.size = size
      self.version = version
      self.preloaded = preloaded
      self.sources = sources
    }
  }

  // Unmeasured layouts stay disabled; no family aliases or cross-SoC fallback.
  // T6040's version is the observed macOS property, not a proved image offset.
  // iBoot/IPCE preloads its boot image; the disk image is only a reload copy.
  public static let socs: [String: SoC] = [
    "t8103": SoC(), "t6000": SoC(), "t6001": SoC(), "t6002": SoC(),
    "t8112": SoC(), "t6020": SoC(), "t6021": SoC(), "t6022": SoC(),
    "t8122": SoC(), "t6030": SoC(), "t6031": SoC(), "t6034": SoC(),
    "t8132": SoC(), "t6040": SoC(size: 60616, version: 0x23f3_b998, preloaded: true),
    "t6041": SoC(), "t6042": SoC(), "t8140": SoC(), "t8142": SoC(),
  ]

  public static func name(chipID: UInt64) -> String? {
    let soc = String(format: "t%04llx", chipID)
    return socs[soc] == nil ? nil : "apple/avd-apple-\(soc).bin"
  }

  /// Validate an already unwrapped reload copy. Absence and unknown layouts
  /// leave the kernel's open firmware available; malformed present images fail.
  public static func reloadImage(_ data: Data?, chipID: UInt64) throws -> FirmwarePackageInput? {
    let soc = String(format: "t%04llx", chipID)
    guard let data, let spec = socs[soc], let size = spec.size, let version = spec.version,
      let name = name(chipID: chipID)
    else { return nil }
    try require(data.startIndex == 0 && data.count == size, "Unexpected AVD reload image size.")
    return FirmwarePackageInput(name: name, bytes: data, version: version)
  }

  public static func collect(_ components: [String: Data], chipID: UInt64) throws
    -> FirmwarePackageInput?
  {
    let soc = String(format: "t%04llx", chipID)
    guard let spec = socs[soc] else { return nil }
    return try collect(components, chipID: chipID, spec: spec)
  }

  static func collect(_ components: [String: Data], chipID: UInt64, spec: SoC) throws
    -> FirmwarePackageInput?
  {
    guard let size = spec.size else { return nil }
    var image: FirmwarePackageInput?
    for source in spec.sources {
      guard let data = components[source.component] else { continue }
      try require(data.count <= 16 << 20, "AVD source exceeds its size limit.")
      let decoded = try FirmwareImage.decode(data, maximumBytes: size)
      try require(decoded.type == source.imageType, "Unexpected selected AVD image type.")
      let candidate = try reloadImage(decoded.bytes, chipID: chipID)
      try require(
        image == nil || image?.bytes == candidate?.bytes, "Conflicting AVD reload images.")
      image = candidate
    }
    return image
  }
}
