// SPDX-License-Identifier: MIT
import Foundation

/// The touchscreen firmware of the MacBook Pros with a touch panel (the ADT's
/// mtp-transport/kiwi interface): the restore image's `Ap,TouchASICFW` member
/// (an XML plist in an IM4P of type `tasf`) turned into the HIDF image the
/// DockChannel HID driver sends to the MTP, `apple/tpkiwifw-<machine>.bin`.
///
/// The container and the CBOR encoding are the trackpad's (HIDF v1, 32-byte
/// header, the interface number patched in at run time), with CBOR lengths
/// that grow as needed: the touch image carries byte strings above 64 KiB.
///
/// Calibration comes from this Mac. The image's `Property` records carry a
/// model default; the Mac's own value is the matching tag in its GpCD factory
/// record. A record takes the Mac's value when that value passes the record's
/// own checks (its Validation words, MaxSize and Checksum.PayloadSize), and
/// keeps the default otherwise. A `Property` with address 0 is a placeholder
/// for the host and is not sent; one marked required stops the conversion.
public enum KiwiFirmware {
  public static func outputName(machine: String) -> String {
    "apple/tpkiwifw-" + machine + ".bin"
  }

  public struct Conversion: Equatable, Sendable {
    public let files: [String: Data]
    /// Tags that took this Mac's calibration, and tags that kept the default.
    public let unitTags: [String]
    public let defaultTags: [String]
  }

  /// `factory` is the Mac's FactoryData snapshot (file name -> contents).
  public static func convert(
    _ input: Data, machine: String, factory: [String: Data]
  ) throws -> Conversion {
    try require(
      machine.range(of: #"\A[jk][0-9]+[a-z]*\z"#, options: .regularExpression) != nil,
      "Invalid touchscreen firmware machine.")
    let (type, payload) = try FirmwareImage.decode(input, maximumBytes: 64 << 20)
    try require(type == "tasf", "Unexpected touchscreen firmware image type.")
    let xml = Data(payload.reversed().drop(while: { $0 == 0 }).reversed())
    let names = factory.keys.filter { $0.hasPrefix("GpCD-") }
    try require(names.count <= 1, "More than one touchscreen calibration record.")
    let unit = try names.first.map { try calibration(factory[$0]!) } ?? [:]
    return try convertPlist(xml, machine: machine, unit: unit)
  }

  static func convertPlist(
    _ xml: Data, machine: String, unit: [String: Data]
  ) throws -> Conversion {
    guard case .dictionary(let personalities) = try FirmwarePlist.decode(xml) else {
      throw RestoreFailure("Invalid touchscreen firmware dictionary.")
    }
    // One personality per image; the self-test and GPIO-test variants are
    // factory tools, never loaded by the OS.
    let loadable = personalities.filter { !$0.key.contains("-") }
    try require(loadable.count == 1, "Touchscreen firmware has no single personality.")
    guard case .array(let source) = loadable[0].value, !source.isEmpty, source.count <= 4096
    else { throw RestoreFailure("Invalid touchscreen firmware records.") }

    var records = [FirmwarePlist]()
    var unitTags = [String]()
    var defaultTags = [String]()
    for record in source {
      try Task.checkCancellation()
      guard case .dictionary(var entries) = record else {
        throw RestoreFailure("Invalid touchscreen firmware record.")
      }
      if record["Type"]?.string == "Property" {
        guard let address = record["Address"]?.integer else {
          throw RestoreFailure("Touchscreen firmware property without an address.")
        }
        if address == 0 {
          if case .boolean(true)? = record["Requirement"]?["Type"] {
            throw RestoreFailure("Touchscreen firmware requires a host property.")
          }
          continue
        }
        let tag = record["Tag"]?.string ?? ""
        if let value = unit[tag], valid(value, for: record) {
          guard let index = entries.firstIndex(where: { $0.key == "Payload" }) else {
            throw RestoreFailure("Touchscreen firmware property without a payload.")
          }
          entries[index].value = .bytes(value)
          unitTags.append(tag)
        } else {
          defaultTags.append(tag)
        }
      }
      if record["Type"]?.string == "Config" {
        entries = try interfacePlaceholder(entries)
      }
      records.append(.dictionary(entries))
    }
    let (blob, interfaceOffset) = try serialize(.array(records))
    guard let interfaceOffset else {
      throw RestoreFailure("Missing touchscreen interface placeholder.")
    }
    var result = Data("HIDF".utf8)
    for value in [1, 32, blob.count, interfaceOffset] {
      result.append(littleBytes(value, count: 4))
    }
    result.append(Data(repeating: 0, count: 12))
    result.append(blob)
    return Conversion(
      files: [outputName(machine: machine): result], unitTags: unitTags,
      defaultTags: defaultTags)
  }

  /// A unit value fits a record when it is no larger than the record allows
  /// and carries the words the record's Validation and Checksum name.
  static func valid(_ value: Data, for record: FirmwarePlist) -> Bool {
    guard let maximum = record["MaxSize"]?.integer, !value.isEmpty, value.count <= maximum
    else { return false }
    func word(_ offset: UInt32, _ size: UInt32) -> UInt32? {
      let start = Int(offset)
      let count = Int(size)
      guard (1...4).contains(count), start <= value.count - count else { return nil }
      return value[start..<(start + count)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
    var checks = [FirmwarePlist]()
    switch record["Validation"] {
    case .array(let list)?: checks = list
    case .dictionary?: checks = [record["Validation"]!]
    case nil: break
    default: return false
    }
    for check in checks {
      guard let address = check["Address"]?.integer, let size = check["Size"]?.integer,
        let actual = word(address, size)
      else { return false }
      if let expected = check["Value"]?.integer, actual != expected { return false }
      if let low = check["MinValue"]?.integer, let high = check["MaxValue"]?.integer,
        !(low...high).contains(actual)
      {
        return false
      }
    }
    if let checksum = record["Checksum"], let footer = checksum["FooterSize"]?.integer,
      let offset = checksum["PayloadSize"]?["Offset"]?.integer,
      let size = checksum["PayloadSize"]?["Size"]?.integer
    {
      guard Int(footer) <= value.count, let stored = word(offset, size),
        Int(stored) == value.count - Int(footer)
      else { return false }
    }
    return true
  }

  /// The GpCD factory record: IMG4 { IM4P 'GpCD' { SEQUENCE { INTEGER, INTEGER,
  /// [private] { SET OF SEQUENCE { INTEGER tag, IA5String, OCTET STRING } } } } }.
  /// The tag is a little-endian four-character code.
  static func calibration(_ record: Data) throws -> [String: Data] {
    let input = Data(record)
    let outer = try FirmwareDER.element(input, at: 0, limit: input.count)
    try require(outer.tag == 0x30, "Invalid touchscreen calibration record.")
    let fields = try FirmwareDER.children(input, outer)
    try require(
      fields.count >= 2 && FirmwareDER.text(input, fields[0], "IMG4") && fields[1].tag == 0x30,
      "Invalid touchscreen calibration envelope.")
    let (type, payload) = try FirmwareImage.decode(
      input.subdata(in: fields[1].whole), maximumBytes: 32 << 20)
    try require(type == "GpCD", "Unexpected touchscreen calibration type.")
    let body = try FirmwareDER.element(payload, at: 0, limit: payload.count)
    try require(body.tag == 0x30, "Invalid touchscreen calibration body.")
    // Two INTEGERs, then one private element in high-tag-number form.
    var at = body.content.lowerBound
    for _ in 0..<2 {
      let field = try FirmwareDER.element(payload, at: at, limit: body.content.upperBound)
      try require(field.tag == 2, "Invalid touchscreen calibration header.")
      at = field.whole.upperBound
    }
    try require(
      at < body.content.upperBound && payload[at] & 0x1f == 0x1f,
      "Invalid touchscreen calibration directory.")
    at += 1
    var tagBytes = 0
    while at < body.content.upperBound && payload[at] & 0x80 != 0 {
      at += 1
      tagBytes += 1
      try require(tagBytes < 5, "Invalid touchscreen calibration directory tag.")
    }
    // Rebuild the element as a plain constructed one so the bounded reader
    // can take its length: same length bytes, one-byte tag.
    try require(at + 1 < body.content.upperBound, "Truncated touchscreen calibration.")
    let shifted = Data([0x30]) + payload.subdata(in: (at + 1)..<body.content.upperBound)
    let directory = try FirmwareDER.element(shifted, at: 0, limit: shifted.count)
    let sets = try FirmwareDER.children(shifted, directory)
    try require(sets.count == 1 && sets[0].tag == 0x31, "Invalid touchscreen calibration set.")
    var result = [String: Data]()
    for entry in try FirmwareDER.children(shifted, sets[0]) {
      let parts = try FirmwareDER.children(shifted, entry)
      try require(
        entry.tag == 0x30 && parts.count == 3 && parts[0].tag == 2 && parts[0].content.count == 4
          && parts[1].tag == 0x16 && parts[2].tag == 4,
        "Invalid touchscreen calibration entry.")
      let code = shifted[parts[0].content].reversed()
      try require(
        code.allSatisfy { (33...126).contains($0) }, "Invalid touchscreen calibration tag.")
      let tag = String(decoding: code, as: UTF8.self)
      try require(result[tag] == nil, "Repeated touchscreen calibration tag.")
      result[tag] = shifted.subdata(in: parts[2].content)
    }
    return result
  }

  private static func interfacePlaceholder(_ source: [FirmwarePlist.Entry]) throws
    -> [FirmwarePlist.Entry]
  {
    var entries = source
    guard let index = entries.firstIndex(where: { $0.key == "Config" }),
      case .dictionary(var config) = entries[index].value,
      let interfaceIndex = config.firstIndex(where: { $0.key == "Interface Config" }),
      case .array(var interfaces) = config[interfaceIndex].value
    else { throw RestoreFailure("Missing touchscreen interface configuration.") }
    for slot in interfaces.indices where interfaces[slot]["HIDRecorder Descriptor"] == nil {
      guard case .dictionary(var fields) = interfaces[slot] else {
        throw RestoreFailure("Invalid touchscreen interface configuration.")
      }
      if let number = fields.firstIndex(where: { $0.key == "bInterfaceNumber" }) {
        fields[number].value = .interface
      } else {
        fields.append(.init(key: "bInterfaceNumber", value: .interface))
      }
      interfaces[slot] = .dictionary(fields)
    }
    config[interfaceIndex].value = .array(interfaces)
    entries[index].value = .dictionary(config)
    return entries
  }

  /// CBOR as the MTP loader reads it: NUL-terminated strings, byte strings as
  /// 0x59 (two-byte length) or 0x5a (four-byte length) with their contents on a
  /// 4-byte boundary (0xd3 fill), and a one-byte interface number placeholder.
  static func serialize(_ value: FirmwarePlist) throws -> (Data, Int?) {
    var blob = Data()
    var interfaceOffset: Int?
    func big(_ value: Int, count: Int) -> Data {
      Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    func head(_ major: UInt8, _ count: Int) throws {
      try require(count >= 0 && count <= Int(UInt32.max), "Touchscreen CBOR length overflow.")
      if count < 24 {
        blob.append(major | UInt8(count))
      } else if count <= 0xff {
        blob.append(contentsOf: [major | 24, UInt8(count)])
      } else if count <= 0xffff {
        blob.append(major | 25)
        blob.append(big(count, count: 2))
      } else {
        blob.append(major | 26)
        blob.append(big(count, count: 4))
      }
    }
    func append(_ value: FirmwarePlist, depth: Int) throws {
      try require(
        depth <= 64 && blob.count <= 64 << 20, "Touchscreen serialization exceeds its budget.")
      switch value {
      case .dictionary(let entries):
        try head(0xa0, entries.count)
        for entry in entries {
          try append(.string(entry.key), depth: depth + 1)
          try append(entry.value, depth: depth + 1)
        }
      case .array(let entries):
        try head(0x80, entries.count)
        for entry in entries { try append(entry, depth: depth + 1) }
      case .string(let text):
        let bytes = Data(text.utf8) + Data([0])
        try head(0x60, bytes.count)
        blob.append(bytes)
      case .integer(let number):
        try head(0x00, Int(number))
      case .boolean(let flag):
        blob.append(flag ? 0xf5 : 0xf4)
      case .bytes(let bytes):
        let long = bytes.count > 0xffff
        try require(bytes.count <= 64 << 20, "Touchscreen data exceeds its budget.")
        let header = long ? 5 : 3
        blob.append(Data(repeating: 0xd3, count: (4 - (blob.count + header) % 4) % 4))
        blob.append(long ? 0x5a : 0x59)
        blob.append(big(bytes.count, count: long ? 4 : 2))
        blob.append(bytes)
      case .interface:
        try require(interfaceOffset == nil, "Multiple touchscreen interface placeholders.")
        interfaceOffset = blob.count
        blob.append(0)
      }
    }
    try append(value, depth: 0)
    return (blob, interfaceOffset)
  }
}
