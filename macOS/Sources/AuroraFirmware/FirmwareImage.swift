// SPDX-License-Identifier: MIT
import Foundation

/// Decodes the admitted IM4P member, without looking outside its DER bounds.
/// Source authentication belongs to the selected restore-image transaction.
public enum FirmwareImage {
  public static func decode(_ input: Data, maximumBytes: Int = 512 << 20) throws
    -> (type: String, bytes: Data)
  {
    try require(
      input.startIndex == 0 && !input.isEmpty && input.count <= 256 << 20
        && maximumBytes > 0 && maximumBytes <= 512 << 20, "Firmware image exceeds its budget.")
    let outer = try FirmwareDER.element(input, at: 0, limit: input.count)
    try require(
      outer.tag == 0x30 && outer.whole.count == input.count,
      "Invalid firmware image envelope.")
    let fields = try FirmwareDER.children(input, outer)
    try require(
      (4...5).contains(fields.count) && FirmwareDER.text(input, fields[0], "IM4P")
        && fields[1].tag == 0x16 && fields[1].content.count == 4
        && fields[2].tag == 0x16 && fields[3].tag == 4,
      "Invalid firmware image fields.")
    let typeBytes = input[fields[1].content]
    try require(typeBytes.allSatisfy { (33...126).contains($0) }, "Invalid firmware image type.")
    let type = String(decoding: typeBytes, as: UTF8.self)
    let data = input.subdata(in: fields[3].content)
    if fields.count == 4 {
      try require(data.count <= maximumBytes, "Firmware payload exceeds its budget.")
      return (type, data)
    }
    try require(fields[4].tag == 0x30, "Invalid firmware compression metadata.")
    let compression = try FirmwareDER.children(input, fields[4])
    try require(
      compression.count == 2 && compression.allSatisfy { $0.tag == 2 },
      "Invalid firmware compression fields.")
    func integer(_ field: FirmwareDER.Element) throws -> Int {
      let bytes = input[field.content]
      try require(
        !bytes.isEmpty && bytes.count <= 5 && bytes.first! < 128
          && (bytes.count == 1 || bytes.first! != 0 || bytes.dropFirst().first! >= 128),
        "Invalid firmware compression integer.")
      return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
    let kind = try integer(compression[0])
    let count = try integer(compression[1])
    try require(
      kind == 1 && count > 0 && count <= maximumBytes,
      "Unsupported firmware compression or decoded length.")
    let decoded = try boundedLZFSE(data, maximum: count)
    try require(decoded.count == count, "Firmware decoded length differs from its declaration.")
    return (type, decoded)
  }

  public static func controllerFirmware(in kernel: Data) throws -> [String: Data] {
    try require(
      kernel.startIndex == 0 && kernel.count <= 512 << 20,
      "Kernel firmware source exceeds its budget.")
    let marker = Data("2214A_RCFG".utf8)
    guard let match = kernel.range(of: marker) else {
      throw RestoreFailure("Required peripheral controller firmware is missing.")
    }
    let offset = match.lowerBound
    let size = try kernel.little(offset + 0x2f, 4)
    try require(size == 0x18000, "Unexpected peripheral controller firmware size.")
    return ["asmedia/asm2214a-apple.bin": try kernel.part(offset + 0x33, size)]
  }
}
