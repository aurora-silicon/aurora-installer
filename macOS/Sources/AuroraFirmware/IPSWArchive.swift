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
/// caller's authority for firmware admission. A transient failure is retried
/// with backoff, and a read resumes after the bytes that already arrived.
public struct IPSWHTTPRangeReader: FirmwareRangeReading {
  public let sizeBytes: Int
  private let url: URL
  private let exchange: HTTPExchange

  public init(url: URL, sizeBytes: Int) throws {
    try self.init(url: url, sizeBytes: sizeBytes, exchange: .live)
  }

  init(url: URL, sizeBytes: Int, exchange: HTTPExchange) throws {
    try require(
      appleRangeURL(url.absoluteString) && sizeBytes >= 22 && sizeBytes <= 128 << 30,
      "Invalid restore-image range source.")
    self.url = url
    self.sizeBytes = sizeBytes
    self.exchange = exchange
  }

  /// Discover the archive length through a one-byte range, without accepting a
  /// whole-image response or redirect. Subsequent reads remain exactly bounded.
  public static func discover(url: URL) async throws -> Self {
    try await discover(url: url, exchange: .live)
  }

  static func discover(url: URL, exchange: HTTPExchange) async throws -> Self {
    try require(appleRangeURL(url.absoluteString), "Invalid restore-image source.")
    var request = URLRequest(url: url)
    request.timeoutInterval = 45
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    var size: Int?
    var bytes = Data()
    try await exchange.retrying {
      size = nil
      bytes = Data()
      try await exchange.perform(
        request,
        { response in
          try serverError(response)
          size = try discoveredSize(response)
        },
        { chunk in
          try require(bytes.count + chunk.count <= 1, "HTTP response exceeds its admitted length.")
          bytes.append(chunk)
        })
      // A connection that closed early without an error is retried too.
      if bytes.isEmpty { throw URLError(.networkConnectionLost) }
    }
    guard bytes.count == 1, let size else { throw RestoreFailure("Invalid restore-image length.") }
    return try Self(url: url, sizeBytes: size, exchange: exchange)
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

  static func serverError(_ response: HTTPURLResponse) throws {
    if (500...599).contains(response.statusCode) {
      throw HTTPServerError(status: response.statusCode)
    }
  }

  public func read(offset: Int, count: Int) async throws -> Data {
    try require(
      offset >= 0 && count > 0 && count <= 8 * 1024 * 1024 && offset <= sizeBytes - count,
      "Restore-image range exceeds its budget.")
    let end = offset + count - 1
    var data = Data()
    data.reserveCapacity(count)
    try await exchange.retrying {
      guard data.count < count else { return }
      let start = offset + data.count
      var request = URLRequest(url: url)
      request.timeoutInterval = 45
      request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      try await exchange.perform(
        request,
        { response in
          try Self.serverError(response)
          let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? ""
          try require(
            response.statusCode == 206
              && response.value(forHTTPHeaderField: "Content-Range")
                == "bytes \(start)-\(end)/\(sizeBytes)"
              && response.value(forHTTPHeaderField: "Content-Length") == String(end - start + 1)
              && (encoding.isEmpty || encoding == "identity"),
            "Restore-image server did not return the exact requested range.")
        },
        { chunk in
          try require(
            chunk.count <= count - data.count, "HTTP response exceeds its admitted length.")
          data.append(chunk)
        })
      // A connection that closed early without an error resumes too.
      if data.count < count { throw URLError(.networkConnectionLost) }
    }
    try require(data.count == count, "Restore-image range is truncated.")
    return data
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
  /// Developer payload override for this member, decided once when the
  /// archive directory is scanned with full knowledge of the member list.
  /// Nil in every production path.
  public var overrideURL: URL? = nil
  public var isSymbolicLink: Bool { mode & 0o170000 == 0o120000 }
}

/// Single-disk ZIP/ZIP64 metadata and bounded stored/deflate member reads.
/// No file extraction, process launch or whole-image fallback is performed.
public struct IPSWArchive: Sendable {
  /// A member body is read in ranges of this size, up to `rangesInFlight` at a
  /// time, so one slow response does not leave the link idle.
  static let rangeBytes = 4 << 20
  public static let rangesInFlight = 8

  /// Developer payload overrides, loaded exclusively from a manifest bundled in
  /// a developer build. Production packages never carry the override directory
  /// and the developer flag, so the mapping never fires there. The official
  /// archive is always verified against the signed catalog and used as-is;
  /// overrides replace members only at extraction time.
  private struct PayloadOverrides {
    struct Manifest: Decodable {
      struct Entry: Decodable {
        let member: String
        let file: String
        let fedoraOnly: Bool?
      }
      let overrides: [Entry]
    }

    let entries: [Manifest.Entry]
    let bundledDirectory: URL

    static func load() -> PayloadOverrides? {
      guard (Bundle.main.infoDictionary?["OmarchyDeveloperBuild"] as? Bool) == true,
        let resources = Bundle.main.resourceURL
      else { return nil }
      let bundled = resources.appendingPathComponent("Release/J616sOverride", isDirectory: true)
      guard
        let data = try? Data(contentsOf: bundled.appendingPathComponent("manifest.json")),
        let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
      else { return nil }
      return PayloadOverrides(entries: manifest.overrides, bundledDirectory: bundled)
    }

    func url(for member: String, memberNames: Set<String>) -> URL? {
      // Only Fedora archives carry root.img; NixOS archives install their own
      // boot and root images and must never receive these overrides.
      let fedoraArchive = memberNames.contains("root.img")
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      let directories = [
        bundledDirectory,
        support?.appendingPathComponent("org.aurorasilicon.installer/J616sOverride", isDirectory: true),
      ].compactMap { $0 }
      for entry in entries where entry.member == member {
        if entry.fedoraOnly == true && !fedoraArchive { continue }
        for directory in directories {
          let url = directory.appendingPathComponent(entry.file)
          if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
      }
      return nil
    }
  }

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
    // Overrides are decided once, with full knowledge of the archive: the
    // Fedora/NixOS distinction needs the complete member list (only Fedora
    // archives carry root.img). The decision is carried on the member so no
    // later call site can re-derive it with the wrong context.
    let overrides = PayloadOverrides.load()
    let memberNames = Set(members.map(\.name))
    let finalMembers = members.map { member -> IPSWArchiveMember in
      guard let url = overrides?.url(for: member.name, memberNames: memberNames),
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let overrideSize = (attrs[.size] as? NSNumber)?.intValue, overrideSize > 0
      else { return member }
      return IPSWArchiveMember(
        name: member.name, compressedSize: overrideSize, sizeBytes: overrideSize,
        compressionMethod: member.compressionMethod, localHeaderOffset: member.localHeaderOffset,
        crc32: member.crc32, flags: member.flags, mode: member.mode,
        isDirectory: member.isDirectory, overrideURL: url)
    }
    let ordered = finalMembers.map(\.localHeaderOffset).sorted()
    let ends = Dictionary(uniqueKeysWithValues: zip(ordered, Array(ordered.dropFirst()) + [offset]))
    return Self(
      members: finalMembers, source: source, directoryOffset: offset,
      records: Dictionary(uniqueKeysWithValues: finalMembers.map { ($0.localHeaderOffset, $0) }),
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

  private func recordOffset(for member: IPSWArchiveMember, symbolicLink: Bool = false) async throws
    -> Int
  {
    try require(
      records[member.localHeaderOffset] == member, "Member does not belong to this IPSW directory.")
    if member.overrideURL != nil {
      return 0
    }
    try require(
      [0, symbolicLink ? 0o120000 : member.isDirectory ? 0o040000 : 0o100000].contains(
        member.mode & 0o170000)
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
    if let overrideURL = member.overrideURL {
      let fh = try FileHandle(forReadingFrom: overrideURL)
      defer { try? fh.close() }
      return (try fh.read(upToCount: count)) ?? Data()
    }
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
    try await streamMember(
      member, maximumBytes: maximumBytes,
      maximumCompressedBytes: maximumCompressedBytes, expectedSHA256: expectedSHA256,
      symbolicLink: false, consume: consume)
  }

  /// Like `stream`, for a long member such as a disk image: the length, CRC
  /// and SHA-256 checks and `consume` each run on a queue of their own while
  /// the member is still being decoded, so decoding, hashing and the
  /// consumer's work overlap instead of adding up. Each sees every chunk in
  /// order, with at most a few chunks waiting. The same checks complete
  /// before this method returns, and `consume` is never called again once it
  /// has thrown or this method has returned.
  @discardableResult
  public func streamPipelined(
    _ member: IPSWArchiveMember, maximumBytes: Int, maximumCompressedBytes: Int,
    expectedSHA256: String? = nil, consume: @escaping @Sendable (Data) throws -> Void
  ) async throws -> String {
    let offset = try await admitStream(
      member, maximumBytes: maximumBytes, maximumCompressedBytes: maximumCompressedBytes,
      expectedSHA256: expectedSHA256, symbolicLink: false)
    let checks = MemberChecks(member)
    let pipeline = ChunkPipeline(stages: [{ try checks.add($0) }, consume])
    do {
      try await decode(member, at: offset) { try await pipeline.submit($0) }
      try await pipeline.finish()
    } catch {
      await pipeline.cancel()
      throw error
    }
    try Task.checkCancellation()
    return try checks.finish(expectedSHA256)
  }

  /// Read link metadata as bounded UTF-8 data. Regular extraction still rejects
  /// links; the caller must admit the target graph before publishing any link.
  public func symbolicLinkTarget(_ member: IPSWArchiveMember) async throws -> String {
    try require(
      member.isSymbolicLink && member.sizeBytes > 0 && member.sizeBytes <= 4096,
      "Invalid restore link metadata.")
    var bytes = Data()
    _ = try await streamMember(
      member, maximumBytes: 4096, maximumCompressedBytes: 65536,
      expectedSHA256: nil, symbolicLink: true, consume: { bytes.append($0) })
    guard let target = String(data: bytes, encoding: .utf8), safeRelative(target),
      !target.contains("\0")
    else { throw RestoreFailure("Unsafe restore link target.") }
    return target
  }

  private func streamMember(
    _ member: IPSWArchiveMember, maximumBytes: Int, maximumCompressedBytes: Int,
    expectedSHA256: String?, symbolicLink: Bool, consume: (Data) throws -> Void
  ) async throws -> String {
    let offset = try await admitStream(
      member, maximumBytes: maximumBytes, maximumCompressedBytes: maximumCompressedBytes,
      expectedSHA256: expectedSHA256, symbolicLink: symbolicLink)
    let checks = MemberChecks(member)
    try await decode(member, at: offset) { bytes in
      try checks.add(bytes)
      try consume(bytes)
    }
    try Task.checkCancellation()
    return try checks.finish(expectedSHA256)
  }

  /// The budgets and the member's local record, before any body byte is read.
  private func admitStream(
    _ member: IPSWArchiveMember, maximumBytes: Int, maximumCompressedBytes: Int,
    expectedSHA256: String?, symbolicLink: Bool
  ) async throws -> Int {
    try require(
      (0...(128 << 30)).contains(maximumBytes)
        && (0...(128 << 30)).contains(maximumCompressedBytes)
        && member.sizeBytes <= maximumBytes && member.compressedSize <= maximumCompressedBytes,
      "IPSW member exceeds its streaming budget.")
    if let expectedSHA256 { try require(validHash(expectedSHA256), "Invalid member digest.") }
    try require(!member.isDirectory, "A directory has no readable file body.")
    return try await recordOffset(for: member, symbolicLink: symbolicLink)
  }

  /// Decodes the member's body at `offset` and hands it to `deliver` in
  /// chunks of at most 4 MiB, never more than its declared size.
  private func decode(
    _ member: IPSWArchiveMember, at offset: Int, deliver: (Data) async throws -> Void
  ) async throws {
    var produced = 0
    func emit(_ bytes: Data) async throws {
      try Task.checkCancellation()
      try require(
        bytes.count <= member.sizeBytes - produced, "IPSW output exceeds its declared size.")
      produced += bytes.count
      try await deliver(bytes)
    }
    if let overrideURL = member.overrideURL {
      let fh = try FileHandle(forReadingFrom: overrideURL)
      defer { try? fh.close() }
      while produced < member.sizeBytes {
        try Task.checkCancellation()
        let toRead = min(Self.rangeBytes, member.sizeBytes - produced)
        guard let chunk = try fh.read(upToCount: toRead), !chunk.isEmpty else { break }
        try await emit(chunk)
      }
      try require(produced == member.sizeBytes, "Override member length mismatch.")
      return
    }
    let body = RangesAhead(source: source, offset: offset, count: member.compressedSize)
    defer { body.cancel() }
    if member.compressionMethod == 0 {
      try require(member.compressedSize == member.sizeBytes, "Stored IPSW member size mismatch.")
      while produced < member.sizeBytes {
        try Task.checkCancellation()
        guard let bytes = try await body.next() else { break }
        try await emit(bytes)
      }
    } else {
      var inflater = z_stream()
      try require(
        inflateInit2_(&inflater, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
          == Z_OK,
        "Cannot initialize IPSW streaming decoder.")
      defer { inflateEnd(&inflater) }
      var input = Data()
      var cursor = 0
      while true {
        try Task.checkCancellation()
        if cursor == input.count, let next = try await body.next() {
          input = next
          cursor = 0
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
        if count > 0 {
          // The buffer is handed on as it is; the next chunk gets its own.
          output.count = count
          try await emit(output)
        }
        if status == Z_STREAM_END {
          try require(
            inflater.total_in == member.compressedSize && produced == member.sizeBytes,
            "IPSW deflate stream has trailing data or an incorrect length.")
          break
        }
      }
    }
  }

  /// A member's length, CRC and SHA-256, kept as its chunks arrive in order.
  private final class MemberChecks: @unchecked Sendable {
    private let member: IPSWArchiveMember
    private var digest = SHA256()
    private var checksum: uLong = 0
    private var produced = 0

    init(_ member: IPSWArchiveMember) { self.member = member }

    func add(_ bytes: Data) throws {
      try require(
        bytes.count <= member.sizeBytes - produced, "IPSW output exceeds its declared size.")
      digest.update(data: bytes)
      checksum = bytes.withUnsafeBytes {
        zlib.crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
      }
      produced += bytes.count
    }

    func finish(_ expectedSHA256: String?) throws -> String {
      let hasOverride = member.overrideURL != nil
      try require(
        produced == member.sizeBytes && (hasOverride || UInt32(checksum) == member.crc32),
        "IPSW member length or CRC mismatch.")
      let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
      if let expectedSHA256 {
        try require(hash == expectedSHA256, "IPSW member digest mismatch.")
      }
      return hash
    }
  }

  private static func verifyCRC(_ bytes: Data, member: IPSWArchiveMember) throws {
    if member.overrideURL != nil { return }
    let checksum = bytes.withUnsafeBytes {
      zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
    }
    try require(UInt32(checksum) == member.crc32, "IPSW member CRC mismatch.")
  }

  /// Reads `count` bytes from `offset` in consecutive ranges ahead of the
  /// consumer and hands them over in order. The first call has one range in
  /// flight, and each later call doubles that up to `rangesInFlight`, so a
  /// consumer that stops early leaves little unread, while a long member keeps
  /// the link busy as the consumer works on each range. Ranges are only
  /// requested when the consumer asks for the next one, so at most
  /// `rangesInFlight` are in flight.
  private final class RangesAhead {
    private let source: any FirmwareRangeReading
    private var offset: Int
    private let end: Int
    private var window = 1
    private var pending: [Task<Data, any Error>] = []

    init(source: any FirmwareRangeReading, offset: Int, count: Int) {
      self.source = source
      self.offset = offset
      end = offset + count
    }

    func next() async throws -> Data? {
      while pending.count < window, offset < end {
        let reader = self.source
        let start = self.offset
        let count = min(IPSWArchive.rangeBytes, end - start)
        pending.append(Task { try await IPSWArchive.exact(reader, offset: start, count: count) })
        offset += count
      }
      guard !pending.isEmpty else { return nil }
      window = min(window * 2, IPSWArchive.rangesInFlight)
      let range = pending.removeFirst()
      return try await withTaskCancellationHandler {
        try await range.value
      } onCancel: {
        range.cancel()
      }
    }

    func cancel() {
      for range in pending { range.cancel() }
      pending.removeAll()
    }
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
