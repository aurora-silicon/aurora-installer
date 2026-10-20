// SPDX-License-Identifier: MIT
import Foundation

public enum MultitouchFirmware {
  public static func convert(_ input: Data, machine: String) throws -> [String: Data] {
    try require(
      machine.range(of: #"\Aj[0-9]+[a-z]*\z"#, options: .regularExpression) != nil,
      "Invalid multitouch firmware machine.")
    let (type, payload) = try FirmwareImage.decode(input, maximumBytes: 16 << 20)
    try require(type == "mtfw", "Unexpected multitouch firmware image type.")
    let xml = Data(payload.reversed().drop(while: { $0 == 0 }).reversed())
    let plist = try FirmwarePlist.decode(xml)
    guard case .dictionary(let entries) = plist else {
      throw RestoreFailure("Invalid multitouch firmware dictionary.")
    }
    var result = [String: Data]()
    for entry in entries {
      let kind: String
      let bytes: Data
      if entry.key.hasPrefix("C1FD") || entry.key.hasPrefix("C1FE") {
        kind = "tpmtfw"
        bytes = try trackpad(entry.value)
      } else if entry.key.hasPrefix("C1FB") {
        kind = "dfrmtfw"
        bytes = try touchbar(entry.value)
      } else {
        continue
      }
      let name = "apple/" + kind + "-" + machine + ".bin"
      try require(result[name] == nil, "Multiple multitouch inputs select the same output.")
      result[name] = bytes
    }
    return result
  }

  private static func trackpad(_ source: FirmwarePlist) throws -> Data {
    guard case .array(var records) = source else {
      throw RestoreFailure("Invalid trackpad firmware.")
    }
    func replacing(_ object: FirmwarePlist, key: String, value: FirmwarePlist) throws
      -> FirmwarePlist
    {
      guard case .dictionary(var entries) = object else {
        throw RestoreFailure("Invalid trackpad configuration.")
      }
      if let index = entries.firstIndex(where: { $0.key == key }) {
        entries[index].value = value
      } else {
        entries.append(.init(key: key, value: value))
      }
      return .dictionary(entries)
    }
    for index in records.indices where records[index]["Type"]?.string == "Config" {
      guard let config = records[index]["Config"],
        var interfaces = config["Interface Config"]?.array
      else { throw RestoreFailure("Missing trackpad interface configuration.") }
      for index in interfaces.indices where interfaces[index]["HIDRecorder Descriptor"] == nil {
        interfaces[index] = try replacing(
          interfaces[index], key: "bInterfaceNumber", value: .interface)
      }
      records[index] = try replacing(
        records[index], key: "Config",
        value: replacing(config, key: "Interface Config", value: .array(interfaces)))
    }
    var blob = Data()
    var interfaceOffset: Int?
    func big(_ value: UInt32, count: Int) -> Data {
      Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    func serialize(_ value: FirmwarePlist, depth: Int = 0) throws {
      try require(
        depth <= 64 && blob.count <= 16 << 20, "Trackpad serialization exceeds its budget.")
      switch value {
      case .dictionary(let entries):
        try require(entries.count < 16, "Too many trackpad dictionary entries.")
        blob.append(UInt8(0xa0 + entries.count))
        for entry in entries {
          try serialize(.string(entry.key), depth: depth + 1)
          try serialize(entry.value, depth: depth + 1)
        }
      case .array(let entries):
        try require(entries.count < 24, "Too many trackpad array entries.")
        blob.append(UInt8(0x80 + entries.count))
        for entry in entries { try serialize(entry, depth: depth + 1) }
      case .string(let text):
        let bytes = Data(text.utf8) + Data([0])
        try require(bytes.count <= 255, "Trackpad string exceeds its budget.")
        blob.append(
          bytes.count < 24 ? Data([UInt8(0x60 + bytes.count)]) : Data([0x78, UInt8(bytes.count)]))
        blob.append(bytes)
      case .integer(let value):
        if value < 24 {
          blob.append(UInt8(value))
        } else if value <= 255 {
          blob.append(contentsOf: [0x18, UInt8(value)])
        } else if value <= 65535 {
          blob.append(0x19)
          blob.append(big(value, count: 2))
        } else {
          blob.append(0x1a)
          blob.append(big(value, count: 4))
        }
      case .boolean(let flag): blob.append(flag ? 0xf5 : 0)
      case .bytes(let bytes):
        try require(bytes.count <= 65535, "Trackpad data exceeds its wire length.")
        let pad = (4 - (blob.count + 3) % 4) % 4
        blob.append(Data(repeating: 0xd3, count: pad))
        blob.append(0x59)
        blob.append(big(UInt32(bytes.count), count: 2))
        blob.append(bytes)
      case .interface:
        try require(interfaceOffset == nil, "Multiple trackpad interface placeholders.")
        interfaceOffset = blob.count
        blob.append(0)
      }
    }
    try serialize(.array(records))
    guard let interfaceOffset else {
      throw RestoreFailure("Missing trackpad interface placeholder.")
    }
    var result = Data("HIDF".utf8)
    for value in [1, 32, blob.count, interfaceOffset] {
      result.append(littleBytes(value, count: 4))
    }
    result.append(Data(repeating: 0, count: 12))
    result.append(blob)
    return result
  }

  private static func touchbar(_ source: FirmwarePlist) throws -> Data {
    guard let records = source.array else { throw RestoreFailure("Invalid Touch Bar firmware.") }
    var output = Data("Z2FW".utf8) + littleBytes(1, count: 4)
    func number(_ record: FirmwarePlist, _ key: String) throws -> Int {
      guard let value = record[key]?.integer else {
        throw RestoreFailure("Missing Touch Bar integer.")
      }
      return Int(value)
    }
    func command(_ kind: Int, _ count: Int) {
      output.append(littleBytes(kind, count: 4))
      output.append(littleBytes(count, count: 4))
    }
    func pad(_ count: Int) { output.append(Data(repeating: 0, count: (4 - count % 4) % 4)) }
    for record in records where record["Type"]?.string == "Config" {
      guard let initData = record["Config"]?["SPI Config"]?["Init Payload"]?.data else {
        throw RestoreFailure("Missing Touch Bar initialization payload.")
      }
      command(0, initData.count)
      output.append(initData)
      pad(initData.count)
    }
    for record in records {
      try Task.checkCancellation()
      try require(output.count <= 16 << 20, "Touch Bar firmware exceeds its budget.")
      switch record["Type"]?.string {
      case "Binary":
        guard let bytes = record["Payload"]?.data, bytes.count <= 262140 else {
          throw RestoreFailure("Invalid Touch Bar binary payload.")
        }
        command(1, 14 + bytes.count)
        let header =
          littleBytes(0x3001, count: 2) + littleBytes((bytes.count + 3) / 4, count: 2)
          + littleBytes(try number(record, "Address"), count: 4)
        output.append(header)
        output.append(littleBytes(header.dropFirst(2).reduce(0) { $0 + Int($1) }, count: 2))
        output.append(bytes)
        output.append(littleBytes(bytes.reduce(0) { $0 + Int($1) }, count: 4))
        pad(14 + bytes.count)
      case "Property": command(2, try number(record, "Address"))
      case "RequestCalibration":
        command(1, 2)
        output.append(littleBytes(0x1f01, count: 2))
        pad(2)
      case "ReadModifyWrite":
        command(1, 16)
        var bytes = littleBytes(0x1e33, count: 2)
        for key in ["Address", "Mask", "Value"] {
          bytes.append(littleBytes(try number(record, key), count: 4))
        }
        output.append(bytes)
        output.append(littleBytes(bytes.dropFirst(2).reduce(0) { $0 + Int($1) }, count: 2))
      default: continue
      }
    }
    return output
  }
}
