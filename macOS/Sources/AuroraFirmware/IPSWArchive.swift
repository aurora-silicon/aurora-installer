// SPDX-License-Identifier: MIT
import Foundation
import zlib

public protocol FirmwareRangeReading: Sendable {
  var sizeBytes: Int { get }
  func read(offset: Int, count: Int) async throws -> Data
}

/// Exact HTTP ranges from an admitted restore-image URL. CRC validates ZIP
/// transport integrity; source/file hashes and AEA authentication remain the
/// caller's authority for firmware admission.
public struct IPSWHTTPRangeReader: FirmwareRangeReading {
  public let sizeBytes: Int
  private let url: URL

  public init(url: URL, sizeBytes: Int) throws {
    try require(
      appleRangeURL(url.absoluteString) && sizeBytes >= 22 && sizeBytes <= 128 << 30,
      "Invalid restore-image range source.")
    self.url = url
    self.sizeBytes = sizeBytes
  }

  public func read(offset: Int, count: Int) async throws -> Data {
    try require(
      offset >= 0 && count > 0 && count <= 8 * 1024 * 1024 && offset <= sizeBytes - count,
      "Restore-image range exceeds its budget.")
    let end = offset + count - 1
    var request = URLRequest(url: url)
    request.timeoutInterval = 45
    request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let bytes = try await httpBytes(request, maximum: count) { response in
      let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? ""
      try require(
        response.statusCode == 206
          && response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(sizeBytes)"
          && response.value(forHTTPHeaderField: "Content-Length") == String(count)
          && (encoding.isEmpty || encoding == "identity"),
        "Restore-image server did not return the exact requested range.")
    }
    try require(bytes.count == count, "Restore-image range is truncated.")
    return bytes
  }
}

public struct IPSWArchiveMember: Equatable, Sendable {
  public let name: String
  public let compressedSize: Int
  public let sizeBytes: Int
  public let compressionMethod: Int
  public let localHeaderOffset: Int
  public let crc32: UInt32
  let flags: Int
  let mode: Int
  let isDirectory: Bool
}

/// Single-disk ZIP/ZIP64 metadata and bounded stored/deflate member reads.
/// No file extraction, process launch or whole-image fallback is performed.
public struct IPSWArchive: Sendable {
  public let members: [IPSWArchiveMember]
  private let source: any FirmwareRangeReading
  private let directoryOffset: Int

  public static func open(_ source: any FirmwareRangeReading) async throws -> Self {
    try require(source.sizeBytes >= 22 && source.sizeBytes <= 128 << 30, "Invalid IPSW size.")
    let tailSize = min(source.sizeBytes, 65535 + 22)
    let tailOffset = source.sizeBytes - tailSize
    let tail = try await exact(source, offset: tailOffset, count: tailSize)
    guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
      (try? tail.little($0, 4)) == 0x06054b50
        && (try? tail.little($0 + 20, 2)) == tail.count - $0 - 22
    }) else { throw RestoreFailure("IPSW end-of-directory record is missing.") }
    try require(
      try tail.little(end + 4, 2) == 0 && tail.little(end + 6, 2) == 0,
      "Split restore archives are unsupported.")
    var entries = try tail.little(end + 10, 2)
    try require(try tail.little(end + 8, 2) == entries, "Inconsistent ZIP entry count.")
    var size = try tail.little(end + 12, 4)
    var offset = try tail.little(end + 16, 4)
    var directoryEnd = tailOffset + end
    if entries == 0xffff || size == 0xffffffff || offset == 0xffffffff {
      let locator = try await exact(source, offset: directoryEnd - 20, count: 20)
      try require(
        try locator.little(0, 4) == 0x07064b50 && locator.little(4, 4) == 0
          && locator.little(16, 4) == 1,
        "Invalid ZIP64 locator.")
      let position = try locator.little(8, 8)
      try require(position <= directoryEnd - 20 - 56, "Invalid ZIP64 record position.")
      let record = try await exact(source, offset: position, count: 56)
      try require(
        try record.little(0, 4) == 0x06064b50 && record.little(4, 8) == 44
          && record.little(16, 4) == 0 && record.little(20, 4) == 0
          && position + 56 == directoryEnd - 20,
        "Unsupported ZIP64 end-of-directory record.")
      let count64 = try record.little(32, 8)
      let size64 = try record.little(40, 8)
      let offset64 = try record.little(48, 8)
      try require(
        try record.little(24, 8) == count64
          && (entries == 0xffff || entries == count64)
          && (size == 0xffffffff || size == size64)
          && (offset == 0xffffffff || offset == offset64),
        "ZIP64 and legacy directory records disagree.")
      entries = count64
      size = size64
      offset = offset64
      directoryEnd = position
    }
    try require(
      entries > 0 && entries <= 100_000 && size > 0 && size <= 8 * 1024 * 1024
        && offset <= directoryEnd - size && offset >= 0,
      "IPSW directory exceeds its metadata budget.")
    let central = try await exact(source, offset: offset, count: size)
    var cursor = 0
    var names = Set<String>()
    var localOffsets = Set<Int>()
    var members: [IPSWArchiveMember] = []
    for _ in 0..<entries {
      try Task.checkCancellation()
      let fixed = try central.part(cursor, 46)
      try require(try fixed.little(0, 4) == 0x02014b50, "Invalid ZIP central header.")
      let flags = try fixed.little(8, 2)
      let nameSize = try fixed.little(28, 2)
      let extraSize = try fixed.little(30, 2)
      let commentSize = try fixed.little(32, 2)
      let variable = try central.part(cursor + 46, nameSize + extraSize + commentSize)
      let rawName = try variable.part(0, nameSize)
      guard let name = String(data: rawName, encoding: .utf8) else {
        throw RestoreFailure("Unsupported IPSW filename encoding.")
      }
      let directory = name.hasSuffix("/")
      try require(
        safeRelative(directory ? String(name.dropLast()) : name) && name.utf8.count <= 4096
          && !names.contains(name) && !name.contains("\0"),
        "Unsafe or duplicate IPSW member name.")
      names.insert(name)
      let sizes = try extended(
        extra: variable.part(nameSize, extraSize),
        size: fixed.little(24, 4), compressed: fixed.little(20, 4),
        offset: fixed.little(42, 4), disk: fixed.little(34, 2))
      try require(
        sizes.disk == 0 && sizes.offset >= 0 && sizes.offset <= offset - 30
          && sizes.compressed <= offset - sizes.offset - 30 && !localOffsets.contains(sizes.offset),
        "IPSW member extends into its directory.")
      localOffsets.insert(sizes.offset)
      members.append(IPSWArchiveMember(
        name: name, compressedSize: sizes.compressed, sizeBytes: sizes.size,
        compressionMethod: try fixed.little(10, 2), localHeaderOffset: sizes.offset,
        crc32: UInt32(try fixed.little(16, 4)), flags: flags,
        mode: (try fixed.little(38, 4)) >> 16, isDirectory: directory))
      cursor += 46 + nameSize + extraSize + commentSize
    }
    try require(cursor == central.count, "Unexpected data in the IPSW central directory.")
    return Self(members: members, source: source, directoryOffset: offset)
  }

  /// Resolve a large stored image without downloading its body. Authenticated
  /// AEA decoding can then request only its admitted segment ranges.
  public func dataOffset(for member: IPSWArchiveMember) async throws -> Int {
    try require(members.contains(member), "Member does not belong to this IPSW directory.")
    try require(
      !member.isDirectory && [0, 0o100000].contains(member.mode & 0o170000)
        && member.flags & ~0x080e == 0 && [0, 8].contains(member.compressionMethod),
      "Unsupported IPSW member type, encryption or compression.")
    let header = try await Self.exact(source, offset: member.localHeaderOffset, count: 30)
    try require(
      try header.little(0, 4) == 0x04034b50 && header.little(6, 2) == member.flags
        && header.little(8, 2) == member.compressionMethod,
      "IPSW local and central header identities disagree.")
    let nameSize = try header.little(26, 2)
    let extraSize = try header.little(28, 2)
    let start = member.localHeaderOffset + 30
    try require(start <= directoryOffset - nameSize - extraSize, "Invalid IPSW local header extent.")
    let variable = try await Self.exact(source, offset: start, count: nameSize + extraSize)
    try require(try variable.part(0, nameSize) == Data(member.name.utf8), "IPSW local filename changed.")
    let localCRC = try header.little(14, 4)
    let local = try Self.extended(
      extra: variable.part(nameSize, extraSize), size: header.little(22, 4),
      compressed: header.little(18, 4), offset: 0, disk: 0)
    if member.flags & 8 == 0 {
      try require(
        localCRC == member.crc32 && local.size == member.sizeBytes
          && local.compressed == member.compressedSize, "IPSW local member sizes disagree.")
    } else {
      try require(
        (localCRC == 0 || localCRC == member.crc32)
          && (local.size == 0 || local.size == member.sizeBytes)
          && (local.compressed == 0 || local.compressed == member.compressedSize),
        "IPSW data-descriptor header disagrees with directory.")
    }
    let dataOffset = start + nameSize + extraSize
    let nextHeader = members.lazy.map(\.localHeaderOffset).filter { $0 > member.localHeaderOffset }.min()
      ?? directoryOffset
    try require(dataOffset <= nextHeader - member.compressedSize, "IPSW member data overlaps another record.")
    return dataOffset
  }

  public func read(
    _ member: IPSWArchiveMember, maximumBytes: Int,
    expectedSHA256: String? = nil
  ) async throws -> Data {
    try require(
      maximumBytes >= 0 && maximumBytes <= maxFileBytes && member.sizeBytes <= maximumBytes
        && member.compressedSize <= maximumBytes + 65536,
      "IPSW member exceeds its extraction budget.")
    if let expectedSHA256 { try require(validHash(expectedSHA256), "Invalid member digest.") }
    let offset = try await dataOffset(for: member)
    var compressed = Data()
    while compressed.count < member.compressedSize {
      let count = min(1024 * 1024, member.compressedSize - compressed.count)
      compressed.append(try await Self.exact(source, offset: offset + compressed.count, count: count))
    }
    let bytes: Data
    if member.compressionMethod == 0 {
      try require(member.compressedSize == member.sizeBytes, "Stored IPSW member size mismatch.")
      bytes = compressed
    } else {
      bytes = try Self.inflateRaw(compressed, expected: member.sizeBytes)
    }
    let checksum = bytes.withUnsafeBytes {
      zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
    }
    try require(UInt32(checksum) == member.crc32, "IPSW member CRC mismatch.")
    if let expectedSHA256 { try require(bytes.sha256 == expectedSHA256, "IPSW member digest mismatch.") }
    return bytes
  }

  private static func exact(_ source: any FirmwareRangeReading, offset: Int, count: Int) async throws -> Data {
    try require(offset >= 0 && count > 0 && count <= 8 * 1024 * 1024 && offset <= source.sizeBytes - count,
      "Invalid IPSW range bounds.")
    let bytes = try await source.read(offset: offset, count: count)
    try require(bytes.count == count, "IPSW range was truncated.")
    return bytes
  }

  private static func extended(extra: Data, size: Int, compressed: Int, offset: Int, disk: Int) throws
    -> (size: Int, compressed: Int, offset: Int, disk: Int)
  {
    var position = 0
    var zip64: Data?
    while position < extra.count {
      let tag = try extra.little(position, 2)
      let count = try extra.little(position + 2, 2)
      let data = try extra.part(position + 4, count)
      if tag == 1 {
        try require(zip64 == nil, "Duplicate ZIP64 extra field.")
        zip64 = data
      }
      position += 4 + count
    }
    var cursor = 0
    func value(_ legacy: Int, sentinel: Int, width: Int) throws -> Int {
      if legacy != sentinel { return legacy }
      guard let zip64 else { throw RestoreFailure("Missing ZIP64 size or offset.") }
      defer { cursor += width }
      return try zip64.little(cursor, width)
    }
    return (try value(size, sentinel: 0xffffffff, width: 8),
            try value(compressed, sentinel: 0xffffffff, width: 8),
            try value(offset, sentinel: 0xffffffff, width: 8),
            try value(disk, sentinel: 0xffff, width: 4))
  }

  private static func inflateRaw(_ bytes: Data, expected: Int) throws -> Data {
    var stream = z_stream()
    try require(inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
      "Cannot initialize IPSW deflate decoder.")
    defer { inflateEnd(&stream) }
    var output = Data(count: expected + 1)
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { target in
      bytes.withUnsafeBytes { input in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(bytes.count)
        stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(capacity)
        return inflate(&stream, Z_FINISH)
      }
    }
    try require(status == Z_STREAM_END && stream.total_in == bytes.count && stream.total_out == expected,
      "IPSW deflate stream is truncated, oversized or has trailing data.")
    return Data(output.prefix(expected))
  }
}
