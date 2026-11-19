// SPDX-License-Identifier: MIT
import Compression
import CryptoKit
import Foundation

/// A whole disk image inside an Apple OTA update archive, such as
/// `AssetData/payloadv2/basesystem_patches/arm64eBaseSystem.dmg`.
///
/// Apple stores it as a `BXDIFF50` patch with no control data: it patches
/// nothing, and its output is a single PBZX stream. The 60-byte header is
/// the magic, 8 bytes the format leaves unused here, the output, control
/// and stream lengths (64-bit little-endian), and the output's SHA-1. The
/// stream is `pbzx`, a big-endian chunk size, then chunks of a big-endian
/// output length, a big-endian stored length and the stored bytes: kept as
/// they are when the two lengths agree, an XZ stream otherwise. The
/// reference engine decodes this member the same way
/// (the reference engine's `util.py`, `copy_recompress` and `PBZX`).
///
/// A patch with control data rewrites an earlier image and is refused.
public enum UpdateArchiveFullImage {
  public static let headerBytes = 60
  /// The largest chunk this decoder admits. Apple's use 1 MiB.
  public static let maximumChunkBytes = 16 << 20
  /// The largest image this decoder produces, the stub stage's own cap.
  public static let maximumOutputBytes = 8 << 30

  public struct Header: Equatable, Sendable {
    public let outputBytes: Int
    public let streamBytes: Int
    /// The SHA-1 of the whole output, as Apple records it.
    public let sha1: Data
    /// The header as read, which the streamed member must repeat.
    let encoded: Data

    /// Parses the member's first `headerBytes`. `memberBytes` is the
    /// member's length in its archive: the stream must fill the rest of it.
    public init(_ bytes: Data, memberBytes: Int) throws {
      guard bytes.count == UpdateArchiveFullImage.headerBytes,
        bytes.prefix(8) == Data("BXDIFF50".utf8)
      else { throw RestoreFailure("Update archive image is not a BXDIFF50 patch.") }
      let output = try bytes.little(16, 8)
      let control = try bytes.little(24, 8)
      let stream = try bytes.little(32, 8)
      guard control == 0 else {
        throw UpdateArchiveImagePatchUnsupported()
      }
      try require(
        output > 0 && output <= UpdateArchiveFullImage.maximumOutputBytes && stream > 12
          && memberBytes >= UpdateArchiveFullImage.headerBytes
          && stream == memberBytes - UpdateArchiveFullImage.headerBytes,
        "Update archive image lengths disagree with its archive member.")
      outputBytes = output
      streamBytes = stream
      sha1 = try bytes.part(40, 20)
      encoded = Data(bytes)
    }
  }

  /// Decodes the member as its bytes arrive, in order, and hands each chunk
  /// to `emit`. `finish` then checks the output's length and SHA-1 and that
  /// the stream ended on a chunk boundary. A caller must keep what `emit`
  /// receives private until `finish` returns.
  public final class Decoder {
    private let header: Header
    private var pending = Data()
    private var cursor = 0
    private var consumed = 0
    private var produced = 0
    private var chunkBytes = 0
    private var digest = Insecure.SHA1()
    private let scratch: UnsafeMutableRawPointer
    private var finished = false

    public init(header: Header) {
      self.header = header
      scratch = UnsafeMutableRawPointer.allocate(
        byteCount: max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZMA)),
        alignment: 16)
    }
    deinit { scratch.deallocate() }

    /// The member's bytes from its start, header included.
    public func consume(_ bytes: Data, emit: (Data) throws -> Void) throws {
      try require(!finished, "Update archive image was already finished.")
      try require(
        bytes.count <= UpdateArchiveFullImage.headerBytes + header.streamBytes - consumed,
        "Update archive image is longer than its header says.")
      consumed += bytes.count
      pending.append(bytes)
      while let chunk = try next() {
        try require(chunk.count <= header.outputBytes - produced, "Update archive image overflows.")
        produced += chunk.count
        digest.update(data: chunk)
        try emit(chunk)
      }
      if cursor > 0 && cursor >= pending.count / 2 {
        pending = Data(pending[(pending.startIndex + cursor)...])
        cursor = 0
      }
    }

    public func finish() throws {
      try require(!finished, "Update archive image was already finished.")
      finished = true
      try require(
        consumed == UpdateArchiveFullImage.headerBytes + header.streamBytes
          && cursor == pending.count && produced == header.outputBytes,
        "Update archive image is truncated.")
      try require(Data(digest.finalize()) == header.sha1, "Update archive image SHA-1 mismatch.")
    }

    private var available: Int { pending.count - cursor }

    private func take(_ count: Int) -> Data {
      let start = pending.startIndex + cursor
      cursor += count
      return pending.subdata(in: start..<(start + count))
    }

    /// The next decoded chunk, or nil until more bytes arrive.
    private func next() throws -> Data? {
      if chunkBytes == 0 {
        guard available >= UpdateArchiveFullImage.headerBytes + 12 else { return nil }
        try require(
          take(UpdateArchiveFullImage.headerBytes) == header.encoded,
          "Update archive image header changed.")
        let start = take(12)
        try require(start.prefix(4) == Data("pbzx".utf8), "Update archive image is not PBZX.")
        chunkBytes = try Self.big(start, 4)
        try require(
          chunkBytes > 0 && chunkBytes <= UpdateArchiveFullImage.maximumChunkBytes,
          "Update archive image chunk size is out of bounds.")
      }
      guard available >= 16 else { return nil }
      let start = pending.startIndex + cursor
      let lengths = pending.subdata(in: start..<(start + 16))
      let output = try Self.big(lengths, 0)
      let stored = try Self.big(lengths, 8)
      try require(
        output > 0 && output <= chunkBytes && stored > 0 && stored <= output,
        "Update archive image chunk lengths are out of bounds.")
      guard available >= 16 + stored else { return nil }
      _ = take(16)
      let body = take(stored)
      if stored == output { return body }
      var decoded = Data(count: output + 1)
      let count = decoded.withUnsafeMutableBytes { target in
        body.withUnsafeBytes { source in
          compression_decode_buffer(
            target.bindMemory(to: UInt8.self).baseAddress!, output + 1,
            source.bindMemory(to: UInt8.self).baseAddress!, stored, scratch, COMPRESSION_LZMA)
        }
      }
      try require(count == output, "Update archive image XZ chunk is invalid.")
      decoded.count = output
      return decoded
    }

    private static func big(_ bytes: Data, _ offset: Int) throws -> Int {
      let value = try bytes.part(offset, 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      try require(value <= UInt64(Int.max), "Integer exceeds supported bounds.")
      return Int(value)
    }
  }
}

/// The image is a real patch of an earlier one, not a whole image.
public struct UpdateArchiveImagePatchUnsupported: Error, Equatable, Sendable {
  public init() {}
}
