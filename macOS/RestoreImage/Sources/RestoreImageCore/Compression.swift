// SPDX-License-Identifier: MIT
import Compression
import Foundation
import zlib

func nativeLZFSE(_ data: Data, expected: Int) throws -> Data {
  var output = Data(count: expected + 1)
  let capacity = output.count
  let count = output.withUnsafeMutableBytes { out in
    data.withUnsafeBytes { input in
      compression_decode_buffer(
        out.bindMemory(to: UInt8.self).baseAddress!, capacity,
        input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
    }
  }
  try require(count == expected, "LZFSE output length mismatch.")
  return Data(output.prefix(count))
}
func boundedLZFSE(_ data: Data, maximum: Int) throws -> Data {
  var offset = 0
  var total = 0
  var expansion = 0
  while true {
    let magic = try data.part(offset, 4)
    if magic == Data("bvx$".utf8) {
      try require(offset + 4 == data.count && total <= maximum, "Invalid LZFSE termination.")
      return try nativeLZFSE(data, expected: total)
    }
    let raw = try data.little(offset + 4, 4)
    total += raw
    try require(raw <= maximum && total <= maximum, "LZFSE output budget exceeded.")
    var header: Int
    var payload: Int
    var matches = 0
    switch String(data: magic, encoding: .ascii) {
    case "bvx-":
      header = 8
      payload = raw
    case "bvxn":
      header = 12
      payload = try data.little(offset + 8, 4)
    case "bvx1":
      _ = try data.part(offset, 772)
      try require(
        try data.little(offset + 12, 4) <= segmentBytes + 4, "LZFSE literal budget exceeded.")
      matches = try data.little(offset + 16, 4)
      header = 772
      payload = try data.little(offset + 20, 4) + data.little(offset + 24, 4)
    case "bvx2":
      _ = try data.part(offset, 32)
      // Read the packed fields as UInt64: the high bit is not a signed size.
      func packed(_ start: Int) throws -> UInt64 {
        try data.part(start, 8).enumerated().reduce(0) {
          $0 | UInt64($1.element) << ($1.offset * 8)
        }
      }
      let v0 = try packed(offset + 8)
      let v1 = try packed(offset + 16)
      matches = Int((v0 >> 40) & 0xfffff)
      header = try data.little(offset + 24, 4)
      payload = Int((v0 >> 20) & 0xfffff) + Int((v1 >> 40) & 0xfffff)
      try require(header >= 32, "Invalid LZFSE V2 header length.")
    default: throw RestoreFailure("Unsupported LZFSE block.")
    }
    expansion += raw + matches * (315 + 2359)
    try require(
      expansion <= 512 * 1024 * 1024 && header + payload <= data.count - offset,
      "LZFSE expansion or payload bounds exceeded.")
    offset += header + payload
  }
}
func inflateZlib(_ data: Data, expected: Int) throws -> Data {
  var output = Data(count: expected + 1)
  var count = uLongf(output.count)
  let status = output.withUnsafeMutableBytes { out in
    data.withUnsafeBytes { input in
      uncompress(
        out.bindMemory(to: Bytef.self).baseAddress!, &count,
        input.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count))
    }
  }
  try require(status == Z_OK && count == expected, "zlib output length mismatch.")
  return Data(output.prefix(Int(count)))
}

func lzvnPayload(_ data: Data, expected: Int) throws -> Data {
  try require(expected > 0 && expected <= 65536 && data.count <= 65537, "Invalid LZVN bounds.")
  var cursor = 0
  var produced = 0
  var previousDistance = 0
  func read(_ count: Int) throws -> Int {
    let value = try data.little(cursor, count)
    cursor += count
    return value
  }
  while cursor < data.count {
    let opcode = try read(1)
    if opcode == 0x06 {
      _ = try data.part(cursor, 7)
      try require(produced == expected, "LZVN output length mismatch.")
      return try data.part(0, cursor + 7)
    }
    if opcode == 0x0e || opcode == 0x16 { continue }
    let literals: Int
    let matches: Int
    var distance = previousDistance
    if opcode >= 0xf0 {
      literals = 0
      matches = try opcode == 0xf0 ? read(1) + 16 : opcode & 15
    } else if opcode >= 0xe0 {
      matches = 0
      literals = try opcode == 0xe0 ? read(1) + 16 : opcode & 15
    } else if (0xa0...0xbf).contains(opcode) {
      let first = try read(1)
      let second = try read(1)
      literals = (opcode >> 3) & 3
      matches = (((opcode & 7) << 2) | (first & 3)) + 3
      distance = (first >> 2) | (second << 6)
      previousDistance = distance
    } else {
      literals = opcode >> 6
      matches = ((opcode >> 3) & 7) + 3
      switch opcode & 7 {
      case 0...5:
        distance = try ((opcode & 7) << 8) | read(1)
        previousDistance = distance
      case 6: break
      default:
        distance = try read(2)
        previousDistance = distance
      }
    }
    _ = try data.part(cursor, literals)
    cursor += literals
    try require(literals <= expected - produced, "LZVN literal budget exceeded.")
    produced += literals
    if matches > 0 {
      try require(distance > 0 && distance <= produced, "Invalid LZVN match distance.")
      try require(matches <= expected - produced, "LZVN match budget exceeded.")
      produced += matches
    }
  }
  throw RestoreFailure("Missing LZVN end-of-stream.")
}

func decompressStorage(_ storage: [Data]) throws -> Data {
  try require((1...2).contains(storage.count), "Invalid APFS storage count.")
  let attr = storage[0]
  try require(try attr.part(0, 4) == Data("fpmc".utf8), "Invalid APFS compression header.")
  let kind = try attr.little(4, 4)
  let size = try attr.little(8, 8)
  try require(
    size > 0 && size <= maxFileBytes && [3, 4, 7, 8, 11, 12].contains(kind),
    "Unsupported APFS compression or size.")
  var blocks: [Data] = []
  if kind % 2 == 1 {
    try require(
      storage.count == 1 && size <= 65536 && attr.count > 16 && attr.count <= 65553,
      "Invalid inline APFS storage.")
    blocks.append(try attr.part(16, attr.count - 16))
  } else {
    try require(storage.count == 2 && attr.count == 16, "Invalid APFS resource-fork storage.")
    let fork = storage[1]
    let count = (size + 65535) / 65536
    if kind == 4 {
      try require(
        try fork.count >= 264 + count * 8 && fork.big32(0) == 256 && fork.little(260, 4) == count,
        "Invalid zlib resource table.")
      var previous = 264 + count * 8
      for index in 0..<count {
        let start = try fork.little(264 + index * 8, 4) + 260
        let length = try fork.little(268 + index * 8, 4)
        try require(
          start >= previous && length > 0 && length <= 65537 && start <= fork.count - length,
          "Invalid zlib resource extent.")
        blocks.append(try fork.part(start, length))
        previous = start + length
      }
    } else {
      let table = (count + 1) * 4
      try require(
        try fork.count >= table && fork.little(0, 4) == table, "Invalid APFS resource table.")
      for index in 0..<count {
        let start = try fork.little(index * 4, 4)
        let end = try fork.little((index + 1) * 4, 4)
        try require(
          start >= table && end > start && end - start <= 65537 && end <= fork.count,
          "Invalid APFS resource extent.")
        blocks.append(try fork.part(start, end - start))
        try require(index != count - 1 || end == fork.count, "Unexpected APFS resource tail.")
      }
    }
  }
  var result = Data()
  for block in blocks {
    let expected = min(65536, size - result.count)
    let plain: Data
    switch kind {
    case 3, 4:
      plain =
        try block.first == 0xff ? Data(block.dropFirst()) : inflateZlib(block, expected: expected)
    case 7, 8:
      if block.first == 6 {
        plain = Data(block.dropFirst())
      } else {
        // APFS chunks can contain authenticated padding after LZVN's EOS.
        // Parse instructions to locate EOS; a byte search could match literals.
        // The full padded storage has already passed its recipe hash check.
        let payload = try lzvnPayload(block, expected: expected)
        let envelope =
          Data("bvxn".utf8) + littleBytes(expected, count: 4)
          + littleBytes(payload.count, count: 4) + payload + Data("bvx$".utf8)
        plain = try boundedLZFSE(envelope, maximum: expected)
      }
    default:
      plain =
        try block.first != UInt8(ascii: "b")
        ? Data(block.dropFirst()) : boundedLZFSE(block, maximum: expected)
    }
    try require(plain.count == expected, "APFS block output length mismatch.")
    result.append(plain)
  }
  try require(result.count == size, "APFS file length mismatch.")
  return result
}
