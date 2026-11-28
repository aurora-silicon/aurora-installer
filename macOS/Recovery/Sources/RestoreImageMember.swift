import Foundation

/// Where a stored member of a restore image (`UniversalMac_*_Restore.ipsw`,
/// a ZIP archive, ZIP64 for every current image) keeps its bytes, found
/// with a few range reads and nothing else: the end of central directory
/// records, the central directory, and the member's local header. Recovery
/// reads the member's bytes from there itself (an Apple Encrypted Archive
/// is stored, not deflated), so no ZIP library or CryptoKit is needed.
///
/// The main installer's IPSWArchive does the same walk for every member and
/// also inflates; this file admits only what a stored member needs and
/// refuses anything it can't place exactly: several disks, a central
/// directory outside the archive or over 16 MiB, a duplicate or missing
/// name, an encrypted or compressed member, or a local header that doesn't
/// match its central directory entry.
public struct RestoreImageMember: Equatable {
  public let name: String
  /// The offset of the member's first byte in the archive.
  public let offset: Int
  public let size: Int
  public let crc32: UInt32

  public enum Failure: Error, Equatable {
    /// The archive's ZIP records are malformed or outside the archive.
    case invalidArchive
    /// No member has this name.
    case missing
    /// The member is encrypted or compressed, so its bytes aren't the file.
    case notStored
    /// A read returned other than the bytes asked for.
    case shortRead
  }

  /// Reads `count` bytes at `offset` of the archive.
  public typealias Read = (_ offset: Int, _ count: Int) throws -> Data

  static let maximumDirectory = 16 * 1024 * 1024

  public static func locate(_ name: String, archiveSize: Int, read: Read) throws -> Self {
    guard archiveSize >= 22, !name.isEmpty else { throw Failure.invalidArchive }
    func exact(_ offset: Int, _ count: Int) throws -> [UInt8] {
      guard offset >= 0, count >= 0, offset <= archiveSize - count else {
        throw Failure.invalidArchive
      }
      let bytes = try read(offset, count)
      guard bytes.count == count else { throw Failure.shortRead }
      return [UInt8](bytes)
    }

    // End of central directory: the last 22 bytes plus a comment of at most
    // 65535 bytes, so it is in the archive's last 65557 bytes.
    let tailSize = min(archiveSize, 22 + 65535)
    let tailStart = archiveSize - tailSize
    let tail = try exact(tailStart, tailSize)
    // The end record is where the signature and a comment length that
    // reaches exactly to the end agree; a comment that holds a second such
    // record makes the archive ambiguous, so it is refused.
    let ends = stride(from: tail.count - 22, through: 0, by: -1).filter {
      Field.u32(tail, $0) == 0x0605_4b50 && Field.u16(tail, $0 + 20) == tail.count - 22 - $0
    }
    guard ends.count == 1, let end = ends.first else { throw Failure.invalidArchive }
    var entries = Field.u16(tail, end + 10)
    var directorySize = Field.u32(tail, end + 12)
    var directoryOffset = Field.u32(tail, end + 16)
    guard Field.u16(tail, end + 4) == 0, Field.u16(tail, end + 6) == 0,
      Field.u16(tail, end + 8) == entries
    else { throw Failure.invalidArchive }
    var directoryLimit = tailStart + end
    if entries == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
      // ZIP64: its locator sits right before the end record and points at
      // the ZIP64 end record, which must end where the locator starts.
      let locatorAt = tailStart + end - 20
      let locator = try exact(locatorAt, 20)
      guard Field.u32(locator, 0) == 0x0706_4b50, Field.u32(locator, 4) == 0,
        Field.u32(locator, 16) == 1
      else { throw Failure.invalidArchive }
      let recordAt = Field.u64(locator, 8)
      guard recordAt >= 0, recordAt <= locatorAt - 56 else { throw Failure.invalidArchive }
      let record = try exact(recordAt, 56)
      guard Field.u32(record, 0) == 0x0606_4b50, Field.u64(record, 4) == locatorAt - recordAt - 12,
        Field.u32(record, 16) == 0, Field.u32(record, 20) == 0,
        Field.u64(record, 24) == Field.u64(record, 32)
      else { throw Failure.invalidArchive }
      // Values the end record gives (not 0xffff/0xffffffff) must agree.
      let wide = (Field.u64(record, 32), Field.u64(record, 40), Field.u64(record, 48))
      guard entries == 0xffff || entries == wide.0,
        directorySize == 0xffff_ffff || directorySize == wide.1,
        directoryOffset == 0xffff_ffff || directoryOffset == wide.2
      else { throw Failure.invalidArchive }
      (entries, directorySize, directoryOffset) = wide
      directoryLimit = recordAt
    }
    // u64 values over Int.max come back negative (Field.u64).
    guard entries >= 0, directorySize >= 0, directorySize <= maximumDirectory, directoryOffset >= 0,
      directoryOffset <= directoryLimit - directorySize, entries <= directorySize / 46
    else { throw Failure.invalidArchive }
    let directory = try exact(directoryOffset, directorySize)

    let wanted = [UInt8](name.utf8)
    var found: (flags: Int, method: Int, crc: UInt32, compressed: Int, size: Int, header: Int)?
    var at = 0
    for _ in 0..<entries {
      guard at <= directory.count - 46, Field.u32(directory, at) == 0x0201_4b50 else {
        throw Failure.invalidArchive
      }
      let nameLength = Field.u16(directory, at + 28)
      let extraLength = Field.u16(directory, at + 30)
      let commentLength = Field.u16(directory, at + 32)
      let next = at + 46 + nameLength + extraLength + commentLength
      guard next <= directory.count else { throw Failure.invalidArchive }
      if Array(directory[(at + 46)..<(at + 46 + nameLength)]) == wanted {
        guard found == nil else { throw Failure.invalidArchive }
        var compressed = Field.u32(directory, at + 20)
        var size = Field.u32(directory, at + 24)
        var header = Field.u32(directory, at + 42)
        guard Field.u16(directory, at + 34) == 0 else { throw Failure.invalidArchive }
        // The ZIP64 extra field holds, in this order, each of the three that
        // is 0xffffffff in the entry.
        let extra = Array(directory[(at + 46 + nameLength)..<(at + 46 + nameLength + extraLength)])
        // Each 0xffffffff must be replaced from the ZIP64 field, whose own
        // values may be anything, 0xffffffff included.
        var placeholders = [size, compressed, header].filter { $0 == 0xffff_ffff }.count
        var field = 0
        var sawZIP64 = false
        while field + 4 <= extra.count {
          let id = Field.u16(extra, field)
          let body = field + 4
          let end = body + Field.u16(extra, field + 2)
          guard end <= extra.count else { throw Failure.invalidArchive }
          if id == 0x0001 {
            guard !sawZIP64 else { throw Failure.invalidArchive }
            sawZIP64 = true
            var cursor = body
            func widen(_ value: inout Int) throws {
              guard value == 0xffff_ffff else { return }
              guard cursor + 8 <= end else { throw Failure.invalidArchive }
              value = Field.u64(extra, cursor)
              cursor += 8
              placeholders -= 1
            }
            try widen(&size)
            try widen(&compressed)
            try widen(&header)
          }
          field = end
        }
        guard field == extra.count, placeholders == 0, size >= 0, compressed >= 0, header >= 0
        else { throw Failure.invalidArchive }
        found = (
          Field.u16(directory, at + 8), Field.u16(directory, at + 10),
          UInt32(Field.u32(directory, at + 16)), compressed, size, header
        )
      }
      at = next
    }
    guard at == directory.count else { throw Failure.invalidArchive }
    guard let found else { throw Failure.missing }
    // Bit 0: encrypted. Method 0: stored, so the bytes are the file.
    guard found.flags & 1 == 0, found.method == 0, found.compressed == found.size else {
      throw Failure.notStored
    }

    // The local header repeats the name and method; its extra field may
    // differ from the central directory's, so its length is read here.
    guard found.header <= directoryOffset - 30 - wanted.count else { throw Failure.invalidArchive }
    let local = try exact(found.header, 30 + wanted.count)
    guard Field.u32(local, 0) == 0x0403_4b50, Field.u16(local, 6) & 1 == 0,
      Field.u16(local, 8) == 0,
      Field.u16(local, 26) == wanted.count, Array(local[30...]) == wanted
    else { throw Failure.invalidArchive }
    if found.flags & 8 == 0 {
      // Without a data descriptor the local CRC must match (its sizes may be
      // ZIP64 placeholders).
      guard UInt32(Field.u32(local, 14)) == found.crc else { throw Failure.invalidArchive }
    }
    let offset = found.header + 30 + wanted.count + Field.u16(local, 28)
    guard offset <= directoryOffset - found.size else { throw Failure.invalidArchive }
    return Self(name: name, offset: offset, size: found.size, crc32: found.crc)
  }

  enum Field {
    static func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    static func u32(_ bytes: [UInt8], _ at: Int) -> Int {
      u16(bytes, at) | u16(bytes, at + 2) << 16
    }
    /// Values over Int.max (never a real offset or size) come back negative.
    static func u64(_ bytes: [UInt8], _ at: Int) -> Int {
      Int(truncatingIfNeeded: UInt64(u32(bytes, at)) | UInt64(u32(bytes, at + 4)) << 32)
    }
  }
}
