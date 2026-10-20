// SPDX-License-Identifier: MIT
import CryptoKit
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

  /// Discover the archive length through a one-byte range, without accepting a
  /// whole-image response or redirect. Subsequent reads remain exactly bounded.
  public static func discover(url: URL) async throws -> Self {
    try require(appleRangeURL(url.absoluteString), "Invalid restore-image source.")
    var request = URLRequest(url: url)
    request.timeoutInterval = 45
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    var size: Int?
    let bytes = try await httpBytes(request, maximum: 1) { response in
      size = try discoveredSize(response)
    }
    guard bytes.count == 1, let size else { throw RestoreFailure("Invalid restore-image length.") }
    return try Self(url: url, sizeBytes: size)
  }

  static func discoveredSize(_ response: HTTPURLResponse) throws -> Int {
    let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
    let suffix = range.dropFirst("bytes 0-0/".count)
    let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? ""
    try require(
      response.statusCode == 206 && range.hasPrefix("bytes 0-0/")
        && !suffix.isEmpty && suffix.utf8.allSatisfy({ (48...57).contains($0) })
        && response.value(forHTTPHeaderField: "Content-Length") == "1"
        && (encoding.isEmpty || encoding == "identity"), "Restore-image range discovery failed.")
    guard let size = Int(suffix), (22...(128 << 30)).contains(size) else {
      throw RestoreFailure("Invalid restore-image length.")
    }
    return size
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
          && response.value(forHTTPHeaderField: "Content-Range")
            == "bytes \(offset)-\(end)/\(sizeBytes)"
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
  public let isDirectory: Bool
}

/// Single-disk ZIP/ZIP64 metadata and bounded stored/deflate member reads.
/// No file extraction, process launch or whole-image fallback is performed.
public struct IPSWArchive: Sendable {
  public let members: [IPSWArchiveMember]
  private let source: any FirmwareRangeReading
  private let directoryOffset: Int
  private let records: [Int: IPSWArchiveMember]
  private let recordEnds: [Int: Int]

  public static func open(_ source: any FirmwareRangeReading) async throws -> Self {
    try require(source.sizeBytes >= 22 && source.sizeBytes <= 128 << 30, "Invalid IPSW size.")
    let tailSize = min(source.sizeBytes, 65535 + 22)
    let tailOffset = source.sizeBytes - tailSize
    let tail = try await exact(source, offset: tailOffset, count: tailSize)
    guard
      let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
        (try? tail.little($0, 4)) == 0x0605_4b50
          && (try? tail.little($0 + 20, 2)) == tail.count - $0 - 22
      })
    else { throw RestoreFailure("IPSW end-of-directory record is missing.") }
    try require(
      try tail.little(end + 4, 2) == 0 && tail.little(end + 6, 2) == 0,
      "Split restore archives are unsupported.")
    var entries = try tail.little(end + 10, 2)
    try require(try tail.little(end + 8, 2) == entries, "Inconsistent ZIP entry count.")
    var size = try tail.little(end + 12, 4)
    var offset = try tail.little(end + 16, 4)
    var directoryEnd = tailOffset + end
    if entries == 0xffff || size == 0xffff_ffff || offset == 0xffff_ffff {
      let locator = try await exact(source, offset: directoryEnd - 20, count: 20)
      try require(
        try locator.little(0, 4) == 0x0706_4b50 && locator.little(4, 4) == 0
          && locator.little(16, 4) == 1,
        "Invalid ZIP64 locator.")
      let position = try locator.little(8, 8)
      try require(position <= directoryEnd - 20 - 56, "Invalid ZIP64 record position.")
      let record = try await exact(source, offset: position, count: 56)
      try require(
        try record.little(0, 4) == 0x0606_4b50 && record.little(4, 8) == 44
          && record.little(16, 4) == 0 && record.little(20, 4) == 0
          && position + 56 == directoryEnd - 20,
        "Unsupported ZIP64 end-of-directory record.")
      let count64 = try record.little(32, 8)
      let size64 = try record.little(40, 8)
      let offset64 = try record.little(48, 8)
      try require(
        try record.little(24, 8) == count64
          && (entries == 0xffff || entries == count64)
          && (size == 0xffff_ffff || size == size64)
          && (offset == 0xffff_ffff || offset == offset64),
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
      try require(try fixed.little(0, 4) == 0x0201_4b50, "Invalid ZIP central header.")
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
      members.append(
        IPSWArchiveMember(
          name: name, compressedSize: sizes.compressed, sizeBytes: sizes.size,
          compressionMethod: try fixed.little(10, 2), localHeaderOffset: sizes.offset,
          crc32: UInt32(try fixed.little(16, 4)), flags: flags,
          mode: (try fixed.little(38, 4)) >> 16, isDirectory: directory))
      cursor += 46 + nameSize + extraSize + commentSize
    }
    try require(cursor == central.count, "Unexpected data in the IPSW central directory.")
    let ordered = members.map(\.localHeaderOffset).sorted()
    let ends = Dictionary(uniqueKeysWithValues: zip(ordered, Array(ordered.dropFirst()) + [offset]))
    return Self(
      members: members, source: source, directoryOffset: offset,
      records: Dictionary(uniqueKeysWithValues: members.map { ($0.localHeaderOffset, $0) }),
      recordEnds: ends)
  }

  /// Resolve a large stored image without downloading its body. Authenticated
  /// AEA decoding can then request only its admitted segment ranges.
  public func dataOffset(for member: IPSWArchiveMember) async throws -> Int {
    try require(!member.isDirectory, "A directory has no readable file body.")
    return try await recordOffset(for: member)
  }

  /// Admit every local record, including unused files, before a payload can
  /// influence disk preparation. Bodies remain subject to their own read budget.
  public func validateEntries() async throws {
    for member in members {
      try Task.checkCancellation()
      _ = try await recordOffset(for: member)
    }
  }

  private func recordOffset(for member: IPSWArchiveMember) async throws -> Int {
    try require(
      records[member.localHeaderOffset] == member, "Member does not belong to this IPSW directory.")
    try require(
      [0, member.isDirectory ? 0o040000 : 0o100000].contains(member.mode & 0o170000)
        && (!member.isDirectory || member.sizeBytes == 0)
        && (member.compressionMethod != 0 || member.compressedSize == member.sizeBytes)
        && member.flags & ~0x080e == 0 && [0, 8].contains(member.compressionMethod),
      "Unsupported IPSW member type, encryption or compression.")
    let header = try await Self.exact(source, offset: member.localHeaderOffset, count: 30)
    try require(
      try header.little(0, 4) == 0x0403_4b50 && header.little(6, 2) == member.flags
        && header.little(8, 2) == member.compressionMethod,
      "IPSW local and central header identities disagree.")
    let nameSize = try header.little(26, 2)
    let extraSize = try header.little(28, 2)
    let start = member.localHeaderOffset + 30
    try require(
      start <= directoryOffset - nameSize - extraSize, "Invalid IPSW local header extent.")
    let variable = try await Self.exact(source, offset: start, count: nameSize + extraSize)
    try require(
      try variable.part(0, nameSize) == Data(member.name.utf8), "IPSW local filename changed.")
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
    let nextHeader = recordEnds[member.localHeaderOffset]!
    try require(
      dataOffset <= nextHeader - member.compressedSize, "IPSW member data overlaps another record.")
    return dataOffset
  }

  /// Read only a small decompressed header of a large image. A partial read
  /// cannot authenticate the rest of a member: the caller must first admit the
  /// archive's signed digest. Complete small members also receive CRC/end checks.
  /// Both output and compressed input have independent, hard limits.
  public func readPrefix(
    _ member: IPSWArchiveMember, maximumBytes: Int,
    maximumCompressedBytes: Int = 8 << 20
  ) async throws -> Data {
    try require(
      maximumBytes > 0 && maximumBytes <= 1 << 20
        && maximumCompressedBytes > 0 && maximumCompressedBytes <= 8 << 20,
      "Invalid archive prefix budget.")
    let offset = try await dataOffset(for: member)
    let count = min(maximumBytes, member.sizeBytes)
    if member.compressionMethod == 0 {
      try require(member.compressedSize == member.sizeBytes, "Stored IPSW member size mismatch.")
      try require(count <= maximumCompressedBytes, "Archive prefix exceeds its input budget.")
      let bytes = count == 0 ? Data() : try await Self.exact(source, offset: offset, count: count)
      if count == member.sizeBytes { try Self.verifyCRC(bytes, member: member) }
      return bytes
    }
    var stream = z_stream()
    try require(
      inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
      "Cannot initialize archive prefix decoder.")
    defer { inflateEnd(&stream) }
    // One extra byte detects an understated size when this is a complete read.
    let complete = count == member.sizeBytes
    var output = Data(count: count + (complete ? 1 : 0))
    var input = Data()
    var cursor = 0
    var fetched = 0
    while true {
      try Task.checkCancellation()
      if cursor == input.count {
        let next = min(65536, member.compressedSize - fetched, maximumCompressedBytes - fetched)
        try require(next > 0, "Archive prefix is truncated or exceeds its input budget.")
        input = try await Self.exact(source, offset: offset + fetched, count: next)
        cursor = 0
        fetched += next
      }
      let previousIn = Int(stream.total_in)
      let previousOut = Int(stream.total_out)
      let capacity = output.count - previousOut
      let inputCount = input.count - cursor
      let status = output.withUnsafeMutableBytes { target in
        input.withUnsafeBytes { bytes in
          stream.next_in = UnsafeMutablePointer(
            mutating: bytes.bindMemory(to: Bytef.self).baseAddress!.advanced(by: cursor))
          stream.avail_in = uInt(inputCount)
          stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!.advanced(by: previousOut)
          stream.avail_out = uInt(capacity)
          return inflate(&stream, Z_NO_FLUSH)
        }
      }
      cursor += Int(stream.total_in) - previousIn
      try require(
        (status == Z_OK || status == Z_STREAM_END) && stream.total_out <= member.sizeBytes
          && (Int(stream.total_in) > previousIn || Int(stream.total_out) > previousOut),
        "Invalid archive prefix deflate stream.")
      if status == Z_STREAM_END {
        try require(
          stream.total_in == member.compressedSize && stream.total_out == member.sizeBytes,
          "Archive member end disagrees with its directory.")
        let bytes = Data(output.prefix(Int(stream.total_out)))
        try Self.verifyCRC(bytes, member: member)
        return bytes
      }
      if !complete && stream.total_out == count { return Data(output.prefix(count)) }
    }
  }

  public func read(
    _ member: IPSWArchiveMember, maximumBytes: Int,
    expectedSHA256: String? = nil
  ) async throws -> Data {
    try require(
      maximumBytes >= 0 && maximumBytes <= maxFileBytes && member.sizeBytes <= maximumBytes
        && member.compressedSize <= maximumBytes + 65536,
      "IPSW member exceeds its extraction budget.")
    var bytes = Data()
    _ = try await stream(
      member, maximumBytes: maximumBytes, maximumCompressedBytes: maximumBytes + 65536,
      expectedSHA256: expectedSHA256, consume: { bytes.append($0) })
    return bytes
  }

  /// Delivers bounded chunks without retaining a complete compressed or decoded
  /// member. A sink must keep its output private until this method returns:
  /// final length, CRC and optional digest checks can reject the last chunk.
  @discardableResult
  public func stream(
    _ member: IPSWArchiveMember, maximumBytes: Int, maximumCompressedBytes: Int,
    expectedSHA256: String? = nil, consume: (Data) throws -> Void
  ) async throws -> String {
    try require(
      (0...(128 << 30)).contains(maximumBytes)
        && (0...(128 << 30)).contains(maximumCompressedBytes)
        && member.sizeBytes <= maximumBytes && member.compressedSize <= maximumCompressedBytes,
      "IPSW member exceeds its streaming budget.")
    if let expectedSHA256 { try require(validHash(expectedSHA256), "Invalid member digest.") }
    let offset = try await dataOffset(for: member)
    var digest = SHA256()
    var checksum: uLong = 0
    var produced = 0
    func emit(_ bytes: Data) throws {
      try Task.checkCancellation()
      try require(bytes.count <= member.sizeBytes - produced, "IPSW output exceeds its declared size.")
      digest.update(data: bytes)
      checksum = bytes.withUnsafeBytes {
        zlib.crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
      }
      produced += bytes.count
      try consume(bytes)
    }
    if member.compressionMethod == 0 {
      try require(member.compressedSize == member.sizeBytes, "Stored IPSW member size mismatch.")
      while produced < member.sizeBytes {
        try Task.checkCancellation()
        let count = min(4 << 20, member.sizeBytes - produced)
        let bytes = try await Self.exact(source, offset: offset + produced, count: count)
        try emit(bytes)
      }
    } else {
      var inflater = z_stream()
      try require(
        inflateInit2_(&inflater, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
        "Cannot initialize IPSW streaming decoder.")
      defer { inflateEnd(&inflater) }
      var input = Data()
      var cursor = 0
      var fetched = 0
      while true {
        try Task.checkCancellation()
        if cursor == input.count && fetched < member.compressedSize {
          let count = min(4 << 20, member.compressedSize - fetched)
          input = try await Self.exact(source, offset: offset + fetched, count: count)
          cursor = 0
          fetched += count
        }
        let previousInput = inflater.total_in
        let previousOutput = inflater.total_out
        // The extra byte detects output beyond the directory's declared size.
        var output = Data(count: min(1 << 20, member.sizeBytes - produced + 1))
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { target in
          input.withUnsafeBytes { bytes in
            inflater.next_in = UnsafeMutablePointer(
              mutating: bytes.bindMemory(to: Bytef.self).baseAddress?.advanced(by: cursor))
            inflater.avail_in = uInt(input.count - cursor)
            inflater.next_out = target.bindMemory(to: Bytef.self).baseAddress
            inflater.avail_out = uInt(capacity)
            return inflate(&inflater, Z_NO_FLUSH)
          }
        }
        cursor += Int(inflater.total_in - previousInput)
        let count = Int(inflater.total_out - previousOutput)
        try require(
          (status == Z_STREAM_END
            || (status == Z_OK && (inflater.total_in > previousInput || count > 0)))
            && count <= member.sizeBytes - produced,
          "IPSW deflate stream is truncated or oversized.")
        if count > 0 { try emit(Data(output.prefix(count))) }
        if status == Z_STREAM_END {
          try require(
            inflater.total_in == member.compressedSize && produced == member.sizeBytes,
            "IPSW deflate stream has trailing data or an incorrect length.")
          break
        }
      }
    }
    try Task.checkCancellation()
    try require(produced == member.sizeBytes && UInt32(checksum) == member.crc32,
      "IPSW member length or CRC mismatch.")
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    if let expectedSHA256 { try require(hash == expectedSHA256, "IPSW member digest mismatch.") }
    return hash
  }

  private static func verifyCRC(_ bytes: Data, member: IPSWArchiveMember) throws {
    let checksum = bytes.withUnsafeBytes {
      zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
    }
    try require(UInt32(checksum) == member.crc32, "IPSW member CRC mismatch.")
  }

  private static func exact(_ source: any FirmwareRangeReading, offset: Int, count: Int)
    async throws -> Data
  {
    try require(
      offset >= 0 && count > 0 && count <= 8 * 1024 * 1024 && offset <= source.sizeBytes - count,
      "Invalid IPSW range bounds.")
    let bytes = try await source.read(offset: offset, count: count)
    try require(bytes.count == count, "IPSW range was truncated.")
    return bytes
  }

  private static func extended(extra: Data, size: Int, compressed: Int, offset: Int, disk: Int)
    throws
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
    return (
      try value(size, sentinel: 0xffff_ffff, width: 8),
      try value(compressed, sentinel: 0xffff_ffff, width: 8),
      try value(offset, sentinel: 0xffff_ffff, width: 8),
      try value(disk, sentinel: 0xffff, width: 4)
    )
  }

}
