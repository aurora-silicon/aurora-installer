import Foundation
import zlib

/// A restore image member of any size, read in bounded chunks with range
/// reads: what the main installer's IPSWArchive.stream does for the stub
/// stage, for recoveryOS. A stored body is read as it lies; a deflated body
/// is inflated as it arrives. Nothing past the member's declared size is
/// handed on, and its length and CRC-32 are checked after the last chunk, so
/// a sink must keep what it writes private until `stream` returns.
extension RestoreImageDirectory {
  /// The main installer's cap for one stub member, the Recovery image included.
  public static let maximumMember = 8 << 30
  public static let streamChunk = 4 << 20

  /// `maximumInput` caps the body bytes read; reading past it is refused.
  public func stream(
    _ entry: Entry, chunkBytes: Int = streamChunk, maximumInput: Int = maximumMember, read: Read,
    consume: (Data) throws -> Void
  ) throws {
    guard chunkBytes > 0, chunkBytes <= 64 << 20, entry.size <= Self.maximumMember,
      entry.compressedSize <= Self.maximumMember, maximumInput > 0
    else { throw Failure.invalidArchive }
    let offset = try dataOffset(entry, read: read)
    var produced = 0
    var checksum: uLong = 0
    func emit(_ bytes: [UInt8]) throws {
      guard bytes.count <= entry.size - produced else { throw Failure.invalidArchive }
      checksum = bytes.withUnsafeBufferPointer {
        zlib.crc32(checksum, $0.baseAddress, uInt($0.count))
      }
      produced += bytes.count
      try consume(Data(bytes))
    }
    var taken = 0
    func next() throws -> [UInt8]? {
      guard taken < entry.compressedSize else { return nil }
      guard taken < maximumInput else { throw Failure.invalidArchive }
      let count = min(chunkBytes, entry.compressedSize - taken, maximumInput - taken)
      let bytes = try RestoreImageMember.exact(
        offset + taken, count, archiveSize: archiveSize, read: read)
      taken += count
      return bytes
    }
    if entry.method == 0 {
      while let bytes = try next() { try emit(bytes) }
    } else {
      var inflater = z_stream()
      guard
        inflateInit2_(&inflater, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
          == Z_OK
      else { throw Failure.invalidArchive }
      defer { inflateEnd(&inflater) }
      var input = [UInt8]()
      var cursor = 0
      while true {
        if cursor == input.count, let more = try next() {
          input = more
          cursor = 0
        }
        let before = (inflater.total_in, inflater.total_out)
        // One byte more than is left shows a body that decodes to more.
        var output = [UInt8](repeating: 0, count: min(chunkBytes, entry.size - produced + 1))
        let status = input.withUnsafeMutableBufferPointer { source in
          output.withUnsafeMutableBufferPointer { target in
            inflater.next_in = source.baseAddress.map { $0 + cursor }
            inflater.avail_in = uInt(source.count - cursor)
            inflater.next_out = target.baseAddress
            inflater.avail_out = uInt(target.count)
            return zlib.inflate(&inflater, Z_NO_FLUSH)
          }
        }
        cursor += Int(inflater.total_in - before.0)
        let count = Int(inflater.total_out - before.1)
        // Z_BUF_ERROR with no input left is a truncated stream.
        guard
          status == Z_STREAM_END
            || (status == Z_OK && (inflater.total_in > before.0 || count > 0))
        else { throw Failure.invalidArchive }
        if count > 0 { try emit(Array(output.prefix(count))) }
        if status == Z_STREAM_END {
          guard Int(inflater.total_in) == entry.compressedSize, taken == entry.compressedSize
          else { throw Failure.invalidArchive }
          break
        }
      }
    }
    guard produced == entry.size, UInt32(checksum) == entry.crc32 else {
      throw Failure.invalidArchive
    }
  }

  /// Whether a member's body starts with "AEA1": an Apple Encrypted Archive,
  /// which the stub keeps only once it is decoded.
  public func isAppleEncryptedArchive(_ entry: Entry, read: Read) throws -> Bool {
    let magic = Array("AEA1".utf8)
    guard entry.size >= magic.count else { return false }
    if entry.method == 0 {
      let offset = try dataOffset(entry, read: read)
      return try RestoreImageMember.exact(offset, magic.count, archiveSize: archiveSize, read: read)
        == magic
    }
    // A deflated body: inflate only until its first bytes are out, from at
    // most 8 MiB of input, as the main installer's readPrefix does.
    struct Enough: Error {}
    var prefix = [UInt8]()
    do {
      try stream(entry, chunkBytes: 65536, maximumInput: 8 << 20, read: read) { bytes in
        prefix += bytes.prefix(magic.count - prefix.count)
        if prefix.count == magic.count { throw Enough() }
      }
    } catch is Enough {}
    return prefix == magic
  }
}
