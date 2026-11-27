import Foundation
import zlib

/// Every member of a restore image (`UniversalMac_*_Restore.ipsw`) and the
/// bytes of the small ones (property lists, link targets), read with range
/// reads like RestoreImageMember. This is what the main installer's
/// IPSWArchive admits, held to the same rules, for recoveryOS, where the
/// installer's framework doesn't run: a name must be UTF-8, relative and
/// unique; a member must be stored or deflated, unencrypted, and inside the
/// archive without overlapping the next record; its local header must agree
/// with its central entry; and a body's length and CRC-32 must match.
public struct RestoreImageDirectory {
  public struct Entry: Equatable {
    public let name: String
    public let compressedSize: Int
    public let size: Int
    public let method: Int
    public let localHeader: Int
    public let crc32: UInt32
    let flags: Int
    /// The Unix mode from the external attributes; 0 when none was stored.
    let mode: Int
    public let isDirectory: Bool
    public var isSymbolicLink: Bool { mode & 0o170000 == 0o120000 }
  }

  public typealias Failure = RestoreImageMember.Failure
  public typealias Read = RestoreImageMember.Read

  public let entries: [Entry]
  public let archiveSize: Int
  let directoryOffset: Int
  /// Each entry by its local header, and the next local header (or the
  /// central directory) after each record.
  let records: [Int: Entry]
  let recordEnds: [Int: Int]

  /// Property lists and link targets; the restore image's largest list,
  /// BuildManifest.plist, is a few MiB.
  public static let maximumSmallMember = 32 << 20

  public static func read(archiveSize: Int, read: Read) throws -> Self {
    guard archiveSize <= 128 << 30 else { throw Failure.invalidArchive }
    let (directory, directoryOffset, count) = try RestoreImageMember.centralDirectory(
      archiveSize: archiveSize, read: read)
    // The main installer's budget: 100,000 entries in at most 8 MiB.
    guard count > 0, count <= 100_000, !directory.isEmpty, directory.count <= 8 << 20 else {
      throw Failure.invalidArchive
    }
    typealias Field = RestoreImageMember.Field
    var entries = [Entry]()
    var names = Set<String>()
    var headers = Set<Int>()
    var at = 0
    for _ in 0..<count {
      guard at <= directory.count - 46, Field.u32(directory, at) == 0x0201_4b50 else {
        throw Failure.invalidArchive
      }
      let nameLength = Field.u16(directory, at + 28)
      let extraLength = Field.u16(directory, at + 30)
      let commentLength = Field.u16(directory, at + 32)
      let next = at + 46 + nameLength + extraLength + commentLength
      guard next <= directory.count else { throw Failure.invalidArchive }
      let rawName = Array(directory[(at + 46)..<(at + 46 + nameLength)])
      guard let name = utf8(rawName) else {
        throw Failure.invalidArchive
      }
      let isDirectory = rawName.last == UInt8(ascii: "/")
      guard safeRelative(isDirectory ? Array(rawName.dropLast()) : rawName),
        rawName.count <= 4096, names.insert(name).inserted
      else { throw Failure.invalidArchive }
      var compressed = Field.u32(directory, at + 20)
      var size = Field.u32(directory, at + 24)
      var header = Field.u32(directory, at + 42)
      let extra = Array(directory[(at + 46 + nameLength)..<(at + 46 + nameLength + extraLength)])
      try RestoreImageMember.widen(extra, &size, &compressed, &header)
      guard Field.u16(directory, at + 34) == 0, header <= directoryOffset - 30,
        compressed <= directoryOffset - header - 30, headers.insert(header).inserted
      else { throw Failure.invalidArchive }
      entries.append(
        Entry(
          name: name, compressedSize: compressed, size: size,
          method: Field.u16(directory, at + 10), localHeader: header,
          crc32: UInt32(Field.u32(directory, at + 16)), flags: Field.u16(directory, at + 8),
          mode: Field.u32(directory, at + 38) >> 16, isDirectory: isDirectory))
      at = next
    }
    guard at == directory.count else { throw Failure.invalidArchive }
    let starts = entries.map(\.localHeader).sorted()
    return Self(
      entries: entries, archiveSize: archiveSize, directoryOffset: directoryOffset,
      records: Dictionary(uniqueKeysWithValues: entries.map { ($0.localHeader, $0) }),
      recordEnds: Dictionary(
        uniqueKeysWithValues: zip(starts, Array(starts.dropFirst()) + [directoryOffset])))
  }

  /// `bytes` as a String if they are valid UTF-8: decoding replaces an
  /// invalid sequence, so only valid UTF-8 comes back byte for byte.
  /// (String(validating:as:) needs macOS 15; recoveryOS may be 13.)
  static func utf8(_ bytes: [UInt8]) -> String? {
    let string = String(decoding: bytes, as: UTF8.self)
    return Array(string.utf8) == bytes ? string : nil
  }

  /// A member name or link target as the file system sees it: judged on its
  /// UTF-8 bytes, not on Characters, which can hide a separator, a dot or NUL
  /// ("/\u{301}", "\0\u{301}").
  static func safeRelative(_ bytes: [UInt8]) -> Bool {
    let refused: [UInt8] = [UInt8(ascii: "\\"), 0, UInt8(ascii: "\r"), UInt8(ascii: "\n")]
    let dot = UInt8(ascii: ".")
    let parts = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    // As the main installer's safeRelative (#203): every '/' byte must also be
    // a Character of its own, so a Character split of an admitted path
    // matches the file system's ("a/\u{301}b" is one Character component).
    let characters = String(decoding: bytes, as: UTF8.self).split(
      separator: "/", omittingEmptySubsequences: false)
    return !bytes.isEmpty && !bytes.contains(where: refused.contains)
      && parts.count == characters.count
      && parts.allSatisfy { !$0.isEmpty && $0 != [dot] && $0 != [dot, dot] }
  }

  /// Where `entry`'s body starts, once its local record is admitted: a
  /// regular file (or a link when `symbolicLink`), stored or deflated, not
  /// encrypted, with a local header that names and sizes it as its central
  /// entry does, and a body that ends before the next record.
  public func dataOffset(_ entry: Entry, symbolicLink: Bool = false, read: Read) throws -> Int {
    typealias Field = RestoreImageMember.Field
    let kind = symbolicLink ? 0o120000 : 0o100000
    guard !entry.isDirectory, [0, kind].contains(entry.mode & 0o170000),
      [0, 8].contains(entry.method), entry.method != 0 || entry.compressedSize == entry.size,
      entry.flags & ~0x080e == 0, let end = recordEnds[entry.localHeader],
      records[entry.localHeader] == entry
    else { throw Failure.notStored }
    func exact(_ offset: Int, _ count: Int) throws -> [UInt8] {
      try RestoreImageMember.exact(offset, count, archiveSize: archiveSize, read: read)
    }
    let header = try exact(entry.localHeader, 30)
    let nameLength = Field.u16(header, 26)
    let extraLength = Field.u16(header, 28)
    let start = entry.localHeader + 30
    guard Field.u32(header, 0) == 0x0403_4b50, Field.u16(header, 6) == entry.flags,
      Field.u16(header, 8) == entry.method,
      start <= directoryOffset - nameLength - extraLength
    else { throw Failure.invalidArchive }
    let variable = try exact(start, nameLength + extraLength)
    guard Array(variable[..<nameLength]) == Array(entry.name.utf8) else {
      throw Failure.invalidArchive
    }
    var size = Field.u32(header, 22)
    var compressed = Field.u32(header, 18)
    var none = 0
    try RestoreImageMember.widen(Array(variable[nameLength...]), &size, &compressed, &none)
    let crc = UInt32(Field.u32(header, 14))
    if entry.flags & 8 == 0 {
      guard crc == entry.crc32, size == entry.size, compressed == entry.compressedSize else {
        throw Failure.invalidArchive
      }
    } else {
      // With a data descriptor the local fields may be zero.
      guard crc == 0 || crc == entry.crc32, size == 0 || size == entry.size,
        compressed == 0 || compressed == entry.compressedSize
      else { throw Failure.invalidArchive }
    }
    let offset = start + nameLength + extraLength
    guard offset <= end - entry.compressedSize else { throw Failure.invalidArchive }
    return offset
  }

  /// The whole body of a small member, inflated if it is deflated, with its
  /// length and CRC-32 checked.
  public func contents(
    _ entry: Entry, maximumBytes: Int = maximumSmallMember, symbolicLink: Bool = false,
    read: Read
  ) throws -> Data {
    guard maximumBytes >= 0, maximumBytes <= Self.maximumSmallMember, entry.size <= maximumBytes,
      // A link's body is capped as the main installer caps it.
      entry.compressedSize <= (symbolicLink ? 65536 : maximumBytes + 65536)
    else { throw Failure.invalidArchive }
    let offset = try dataOffset(entry, symbolicLink: symbolicLink, read: read)
    let body = try RestoreImageMember.exact(
      offset, entry.compressedSize, archiveSize: archiveSize, read: read)
    let bytes = entry.method == 0 ? body : try Self.inflate(body, size: entry.size)
    let checksum = bytes.withUnsafeBufferPointer {
      zlib.crc32(0, $0.baseAddress, uInt($0.count))
    }
    guard bytes.count == entry.size, UInt32(checksum) == entry.crc32 else {
      throw Failure.invalidArchive
    }
    return Data(bytes)
  }

  /// A raw deflate stream that must decode to exactly `size` bytes and end
  /// at its last input byte.
  static func inflate(_ input: [UInt8], size: Int) throws -> [UInt8] {
    var stream = z_stream()
    guard
      inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw Failure.invalidArchive }
    defer { inflateEnd(&stream) }
    // One byte more than declared shows a member that decodes to more.
    var output = [UInt8](repeating: 0, count: size + 1)
    var source = input
    let status = source.withUnsafeMutableBufferPointer { inBuffer in
      output.withUnsafeMutableBufferPointer { outBuffer in
        stream.next_in = inBuffer.baseAddress
        stream.avail_in = uInt(inBuffer.count)
        stream.next_out = outBuffer.baseAddress
        stream.avail_out = uInt(outBuffer.count)
        return zlib.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, Int(stream.total_in) == input.count,
      Int(stream.total_out) == size
    else { throw Failure.invalidArchive }
    return Array(output.prefix(size))
  }

  /// A link member's target: relative, at most 4096 bytes of UTF-8, and
  /// never `..` or a NUL. Where it may point is the plan's to judge.
  public func linkTarget(_ entry: Entry, read: Read) throws -> String {
    guard entry.isSymbolicLink, entry.size > 0, entry.size <= 4096 else {
      throw Failure.invalidArchive
    }
    let bytes = try contents(entry, maximumBytes: 4096, symbolicLink: true, read: read)
    guard let target = Self.utf8(Array(bytes)), Self.safeRelative(Array(bytes))
    else {
      throw Failure.invalidArchive
    }
    return target
  }
}
