#if os(macOS)
  import Darwin
  import Foundation

  enum NativeInspectionError: LocalizedError, Equatable, Sendable {
    case invalidMetadata
    case metadataChanged
    case invalidPolicy
    case invalidLayout
    case invalidFirmwareVersion
    case systemVolumeUnreadable
    case queryTimedOut
    case queryFailed

    var errorDescription: String? {
      switch self {
      case .metadataChanged:
        "The installation resources changed. Please prepare the installation again."
      case .invalidMetadata: "The installation’s space requirements could not be verified."
      case .invalidPolicy, .invalidFirmwareVersion:
        "This Mac’s installation requirements could not be verified."
      case .invalidLayout: "The internal disk layout changed or could not be verified."
      case .systemVolumeUnreadable: "An existing system volume could not be checked safely."
      case .queryTimedOut: "macOS took too long to check the disk. Please try again."
      case .queryFailed: "macOS could not complete the disk check."
      }
    }
  }

  /// The selected catalog authenticates these bytes before they influence a plan.
  /// Initial inspection uses only the small source-pinned baseline below.
  struct NativeInstallationMetadata: Decodable, Sendable {
    struct Template: Decodable, Sendable {
      struct Partition: Decodable, Sendable {
        let size: String
        let expand: Bool?
      }
      let target: String?
      let name: String
      let partitions: [Partition]
      let supportedFirmware: [String]?
      enum CodingKeys: String, CodingKey {
        case target = "omarchy_target"
        case name = "default_os_name"
        case supportedFirmware = "supported_fw"
        case partitions
      }
    }
    let templates: [Template]
    enum CodingKeys: String, CodingKey { case templates = "os_list" }

    private struct SelectedTemplate: Decodable {
      let value: Template?
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Template.CodingKeys.self)
        if (try? container.decode(String.self, forKey: .target)) == "apple-silicon-full-os" {
          value = try Template(from: decoder)
        } else {
          value = nil
        }
      }
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      templates = try container.decode([SelectedTemplate].self, forKey: .templates).compactMap(
        \.value)
    }

    init(data: Data) throws {
      guard !data.isEmpty, data.count <= 65_536 else { throw NativeInspectionError.invalidMetadata }
      self = try JSONDecoder().decode(Self.self, from: data)
      _ = try target()
    }

    static func authenticated(_ staged: StagedInstallerArtifact) throws -> Self {
      guard staged.fileURL.isFileURL, staged.artifact.role == "metadata",
        staged.artifact.expectedSizeBytes <= 65_536
      else { throw NativeInspectionError.invalidMetadata }
      let fd = open(staged.fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw NativeInspectionError.metadataChanged }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size >= 0, UInt64(info.st_size) == staged.artifact.expectedSizeBytes
      else { throw NativeInspectionError.metadataChanged }
      let data = try file.read(upToCount: 65_537) ?? Data()
      guard UInt64(data.count) == staged.artifact.expectedSizeBytes,
        SHA256Digest(hashing: data).rawValue == staged.artifact.expectedDigest
      else { throw NativeInspectionError.metadataChanged }
      return try Self(data: data)
    }

    func target() throws -> Template {
      let matching = templates.filter { $0.target == "apple-silicon-full-os" }
      guard matching.count == 1, let target = matching.first, !target.name.isEmpty,
        !target.partitions.isEmpty, target.partitions.count <= 128
      else { throw NativeInspectionError.invalidMetadata }
      return target
    }

    func bounds(stubBytes: UInt64) throws -> (floor: UInt64, recommended: UInt64) {
      let target = try target()
      var root: UInt64 = 0
      for partition in target.partitions {
        root = try NativeInspectionMath.add(
          root, NativeInspectionMath.alignUp(Self.bytes(partition.size)))
      }
      let recommended =
        target.partitions.contains { $0.expand == true }
        ? try NativeInspectionMath.add(root, root) : root
      return (
        try NativeInspectionMath.add(stubBytes, root),
        try NativeInspectionMath.add(stubBytes, recommended)
      )
    }

    static func bytes(_ string: String) throws -> UInt64 {
      var value = string.uppercased().replacingOccurrences(of: " ", with: "")
      var base: Double = 1000
      if value.hasSuffix("IB") {
        base = 1024
        value.remove(at: value.index(value.endIndex, offsetBy: -2))
      }
      for (suffix, power) in [("TB", 4), ("GB", 3), ("MB", 2), ("KB", 1), ("B", 0)] {
        guard value.hasSuffix(suffix) else { continue }
        guard let number = Double(value.dropLast(suffix.count)), number.isFinite, number > 0 else {
          throw NativeInspectionError.invalidMetadata
        }
        let result = number * pow(base, Double(power))
        guard result.isFinite, result >= 1, result < Double(UInt64.max) else {
          throw NativeInspectionError.invalidMetadata
        }
        return UInt64(result)
      }
      throw NativeInspectionError.invalidMetadata
    }
  }

  enum NativeInspectionMath {
    static let unit: UInt64 = 1_048_576
    static func add(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
      let sum = left.addingReportingOverflow(right)
      guard !sum.overflow else { throw NativeInspectionError.invalidLayout }
      return sum.partialValue
    }
    static func alignUp(_ value: UInt64) throws -> UInt64 {
      try add(value, unit - 1) / unit * unit
    }
    static func alignDown(_ value: UInt64) -> UInt64 { value / unit * unit }
  }

  struct NativeInspectionHardware: Decodable, Sendable {
    let chipID: UInt64
    let bootVersion: String?
    let macOSVersion: String?
    let recoveryVersion: String?
  }

  struct NativeInspectionPolicy: Decodable, Sendable {
    struct Device: Decodable, Sendable {
      let minimum: String
      let expert: Bool
    }
    struct Firmware: Decodable, Sendable {
      let version: String
      let minimumMacOS: String
      let minimumBoot: String
      let minimumRecovery: String
      let expert: Bool
      let models: [String]?
      let sourceURL: String
    }
    let runtimeVersion: String
    let sourceSHA256: String
    let chipMinimum: [String: String]
    let devices: [String: Device]
    let firmware: [Firmware]
    let baselineMetadata: NativeInstallationMetadata

    static func sealed() throws -> Self {
      try JSONDecoder().decode(Self.self, from: Data(NativeInspectionPolicySource.json.utf8))
    }

    func supports(_ identifier: String, hardware: NativeInspectionHardware) -> Bool {
      guard identifier.hasPrefix("apple,"), let chip = chipMinimum[String(hardware.chipID)],
        !chip.isEmpty, let device = devices[String(identifier.dropFirst(6))]
      else { return false }
      return !device.expert
    }

    func stubBytes(
      _ identifier: String, hardware: NativeInspectionHardware,
      metadata: NativeInstallationMetadata
    ) throws -> UInt64 {
      let small: UInt64 = 2_499_805_184
      let large: UInt64 = 5_999_951_872
      guard let chip = chipMinimum[String(hardware.chipID)],
        let device = devices[String(identifier.dropFirst(6))]
      else { throw NativeInspectionError.invalidPolicy }
      if try Version.atLeast(chip, "26.0") { return large }
      guard let boot = hardware.bootVersion, let macOS = hardware.macOSVersion,
        let recovery = hardware.recoveryVersion
      else { return small }
      let target = try metadata.target()
      do {
        let minimum = try Version.atLeast(chip, device.minimum) ? chip : device.minimum
        var selected: Firmware?
        for entry in firmware {
          if try Version.atLeast(entry.version, minimum),
            target.supportedFirmware?.contains(entry.version) ?? true,
            entry.models?.contains(String(identifier.dropFirst(6))) ?? true,
            !entry.expert,
            try Version.atLeast(boot, entry.minimumBoot),
            try Version.atLeast(macOS, entry.minimumMacOS),
            try Version.atLeast(recovery, entry.minimumRecovery)
          {
            selected = entry
          }
        }
        if let selected, try Version.atLeast(selected.version, "26.0") { return large }
      } catch NativeInspectionError.invalidFirmwareVersion {
        // Match the retained inspection contract for unreadable recovery
        // versions. Installation still independently admits usable firmware.
        return small
      }
      return small
    }

    struct Version {
      private enum Part: Equatable {
        case number(Int)
        case text(String)
      }
      private let parts: [Part]
      init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
          throw NativeInspectionError.invalidFirmwareVersion
        }
        var parts = value.components(separatedBy: CharacterSet(charactersIn: "-,. "))
          .map { Int($0).map(Part.number) ?? .text($0) }
        if parts.count > 3, parts[parts.count - 2] == .text("beta") {
          guard case .number(let number) = parts[parts.count - 3], number > Int.min else {
            throw NativeInspectionError.invalidFirmwareVersion
          }
          parts[parts.count - 3] = .number(number - 1)
          parts[parts.count - 2] = .number(99)
        }
        self.parts = parts
      }
      static func atLeast(_ lhs: String, _ rhs: String) throws -> Bool {
        let left = try Version(lhs)
        let right = try Version(rhs)
        for (a, b) in zip(left.parts, right.parts) where a != b {
          switch (a, b) {
          case (.number(let a), .number(let b)): return a > b
          case (.text(let a), .text(let b)): return a > b
          default: throw NativeInspectionError.invalidFirmwareVersion
          }
        }
        return left.parts.count >= right.parts.count
      }
    }
  }
#endif
