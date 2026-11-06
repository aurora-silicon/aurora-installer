// SPDX-License-Identifier: MIT
import Foundation

/// Converts the touchscreen firmware shipped for K114/K116 into the bounded
/// HIDF v1 container consumed by the DockChannel HID driver. Factory values
/// remain per-machine inputs and are never compiled into the installer.
public enum KiwiFirmware {
  public static let firmwareName = "apple/kiwi/firmware.hidf"
  public static let calibrationName = "apple/kiwi/calibration.json"

  public static func supports(_ machine: String) -> Bool {
    ["k114c", "k114s", "k116c", "k116s"].contains(machine)
  }

  public struct Receipt: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceSHA256: String
    public let firmwareSHA256: String
    public let calibrationSHA256: String
    public let propertySHA256: [String: String]

    enum CodingKeys: String, CodingKey {
      case schema
      case sourceSHA256 = "source_sha256"
      case firmwareSHA256 = "firmware_sha256"
      case calibrationSHA256 = "calibration_sha256"
      case propertySHA256 = "property_sha256"
    }
  }

  public struct Conversion: Equatable, Sendable {
    public let files: [String: Data]
    public let receipt: Receipt
  }

  private struct RuntimeCalibration: Codable {
    struct Property: Codable {
      let byteCount: Int
      let sha256: String
      let value: Data

      enum CodingKeys: String, CodingKey {
        case byteCount = "byte_count"
        case sha256, value
      }
    }

    let schema: Int
    let machine: String
    let personality: String
    let properties: [String: Property]
  }

  public static func convert(
    _ input: Data, machine: String, factory: [String: Data]
  ) throws -> Conversion {
    let decoded = try FirmwareImage.decode(input, maximumBytes: 64 << 20)
    try require(decoded.type == "fsat", "Unexpected kiwi firmware image type.")
    return try convertPayload(
      decoded.bytes, machine: machine, factory: factory, sourceSHA256: input.sha256)
  }

  /// Kept internal so synthetic tests can exercise the converter without
  /// manufacturing an IMG4 envelope. Production callers use `convert`.
  static func convertPayload(
    _ payload: Data, machine: String, factory: [String: Data],
    sourceSHA256: String? = nil
  ) throws -> Conversion {
    let personality: String
    switch machine {
    case "k114c", "k114s": personality = "K114,2"
    case "k116c", "k116s": personality = "K116,0"
    default: throw RestoreFailure("Unsupported kiwi firmware machine.")
    }
    let xml = Data(payload.reversed().drop(while: { $0 == 0 }).reversed())
    let plist = try FirmwarePlist.decode(xml)
    guard case .dictionary(let personalities) = plist,
      let selected = personalities.first(where: { $0.key == personality })?.value,
      case .array(let sourceRecords) = selected,
      !sourceRecords.isEmpty, sourceRecords.count <= 4096
    else { throw RestoreFailure("Missing kiwi firmware personality.") }

    var records = [FirmwarePlist]()
    var resolved = [String: Data]()
    for source in sourceRecords {
      try Task.checkCancellation()
      guard case .dictionary(var entries) = source else {
        throw RestoreFailure("Invalid kiwi firmware record.")
      }
      if let requirement = entries.first(where: { $0.key == "Requirement" })?.value {
        guard case .boolean(let required) = requirement else {
          throw RestoreFailure("Invalid kiwi firmware requirement.")
        }
        if !required { continue }
        entries.removeAll { $0.key == "Requirement" }
      }
      let type = entries.first(where: { $0.key == "Type" })?.value.string
      if type == "Property" {
        let record = FirmwarePlist.dictionary(entries)
        guard let key = record["SysConfigKey"]?.string,
          !key.isEmpty, key.utf8.count <= 255, !key.contains("\0"),
          case .bytes(let reference)? = record["Reference"]
        else { throw RestoreFailure("Invalid kiwi factory property record.") }
        let value = try property(key: key, record: record, factory: factory)
        try require(
          value.count == reference.count,
          "Kiwi factory property type or length does not match its reference.")
        if let previous = resolved[key] {
          try require(previous == value, "Conflicting kiwi factory property values.")
        } else {
          resolved[key] = value
        }
        guard let index = entries.firstIndex(where: { $0.key == "Reference" }) else {
          throw RestoreFailure("Missing kiwi factory property reference.")
        }
        entries[index].value = .bytes(value)
      }
      records.append(.dictionary(entries))
    }
    try require(!records.isEmpty, "Kiwi firmware has no applicable records.")

    let prepared = try interfacePlaceholder(in: records)
    let serialized = try FirmwareCBOR.serialize(.array(prepared))
    try require(!serialized.bytes.isEmpty, "Kiwi firmware payload is empty.")
    var firmware = Data("HIDF".utf8)
    for value in [1, 32, serialized.bytes.count, serialized.interfaceOffset ?? 0] {
      firmware.append(littleBytes(value, count: 4))
    }
    firmware.append(Data(repeating: 0, count: 12))
    firmware.append(serialized.bytes)

    let runtimeProperties = resolved.mapValues {
      RuntimeCalibration.Property(byteCount: $0.count, sha256: $0.sha256, value: $0)
    }
    let runtime = RuntimeCalibration(
      schema: 1, machine: machine, personality: personality, properties: runtimeProperties)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let calibration = try encoder.encode(runtime)
    let propertyHashes = resolved.mapValues(\.sha256)
    let receipt = Receipt(
      schema: 1, sourceSHA256: sourceSHA256 ?? payload.sha256,
      firmwareSHA256: firmware.sha256, calibrationSHA256: calibration.sha256,
      propertySHA256: propertyHashes)
    return Conversion(
      files: [firmwareName: firmware, calibrationName: calibration], receipt: receipt)
  }

  private static func property(
    key: String, record: FirmwarePlist, factory: [String: Data]
  ) throws -> Data {
    var names = [key]
    if let path = record["DefaultPath"]?.string, !path.isEmpty {
      names.append(path)
      if let last = path.split(separator: "/").last { names.append(String(last)) }
    }
    var values = [Data]()
    for name in names where name.utf8.count <= 1024 {
      if let value = factory[name], !values.contains(value) { values.append(value) }
    }
    guard values.count == 1, let value = values.first, !value.isEmpty,
      value.count <= 64 << 20
    else { throw RestoreFailure("Required kiwi factory property is missing or ambiguous.") }
    return value
  }

  private static func interfacePlaceholder(in source: [FirmwarePlist]) throws -> [FirmwarePlist] {
    func replacing(_ object: FirmwarePlist, key: String, value: FirmwarePlist) throws
      -> FirmwarePlist
    {
      guard case .dictionary(var entries) = object else {
        throw RestoreFailure("Invalid kiwi interface configuration.")
      }
      if let index = entries.firstIndex(where: { $0.key == key }) {
        entries[index].value = value
      } else {
        entries.append(.init(key: key, value: value))
      }
      return .dictionary(entries)
    }
    var records = source
    for index in records.indices where records[index]["Type"]?.string == "Config" {
      guard let config = records[index]["Config"],
        var interfaces = config["Interface Config"]?.array
      else { throw RestoreFailure("Missing kiwi interface configuration.") }
      for interface in interfaces.indices
      where interfaces[interface]["HIDRecorder Descriptor"] == nil {
        interfaces[interface] = try replacing(
          interfaces[interface], key: "bInterfaceNumber", value: .interface)
      }
      records[index] = try replacing(
        records[index], key: "Config",
        value: replacing(config, key: "Interface Config", value: .array(interfaces)))
    }
    return records
  }
}

private enum FirmwareCBOR {
  struct Result {
    let bytes: Data
    let interfaceOffset: Int?
  }

  static func serialize(_ source: FirmwarePlist) throws -> Result {
    var output = Data()
    var interfaceOffset: Int?
    var objects = 0

    func header(_ major: UInt8, _ value: UInt32) -> Data {
      if value < 24 { return Data([major | UInt8(value)]) }
      if value <= 0xff { return Data([major | 24, UInt8(value)]) }
      if value <= 0xffff {
        return Data([
          major | 25, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
      }
      return Data([
        major | 26, UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
      ])
    }

    func append(_ value: FirmwarePlist, depth: Int = 0) throws {
      objects += 1
      try require(
        depth <= 64 && objects <= 100000 && output.count <= 64 << 20,
        "Kiwi CBOR serialization exceeds its budget.")
      switch value {
      case .dictionary(let entries):
        try require(entries.count <= 65535, "Kiwi CBOR dictionary is too large.")
        output.append(header(0xa0, UInt32(entries.count)))
        for entry in entries {
          try append(.string(entry.key), depth: depth + 1)
          try append(entry.value, depth: depth + 1)
        }
      case .array(let entries):
        try require(entries.count <= 65535, "Kiwi CBOR array is too large.")
        output.append(header(0x80, UInt32(entries.count)))
        for entry in entries { try append(entry, depth: depth + 1) }
      case .string(let text):
        let bytes = Data(text.utf8) + Data([0])
        try require(bytes.count <= 65535, "Kiwi CBOR string is too large.")
        output.append(header(0x60, UInt32(bytes.count)))
        output.append(bytes)
      case .integer(let number): output.append(header(0, number))
      case .bytes(let bytes):
        try require(bytes.count <= 64 << 20, "Kiwi CBOR byte string is too large.")
        let prefix = header(0x40, UInt32(bytes.count))
        output.append(Data(repeating: 0xd3, count: (4 - (output.count + prefix.count) % 4) % 4))
        output.append(prefix)
        output.append(bytes)
      case .boolean(let flag): output.append(flag ? 0xf5 : 0xf4)
      case .interface:
        try require(interfaceOffset == nil, "Multiple kiwi interface placeholders.")
        interfaceOffset = output.count
        output.append(0)
      }
    }

    try append(source)
    try require(output.count <= 64 << 20, "Kiwi CBOR output exceeds its budget.")
    return Result(bytes: output, interfaceOffset: interfaceOffset)
  }
}
