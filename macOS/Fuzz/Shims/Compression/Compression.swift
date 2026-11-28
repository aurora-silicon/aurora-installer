// SPDX-License-Identifier: MIT
// The names mirror the Apple API this module stands in for.
// swift-format-ignore-file: AlwaysUseLowerCamelCase, TypeNamesShouldBeCapitalized

// Fuzz-only stand-in for Apple's Compression framework on Linux. A "stream"
// carries its decoded length as a little-endian UInt32 at byte 4 (where an
// LZFSE block keeps its raw size) and decodes to that many zero bytes,
// truncated to the buffer like the real call; a stream shorter than eight
// bytes is invalid and decodes to nothing. This keeps the callers' length
// handling reachable without an LZMA or LZFSE decoder.
#if !os(Linux)
  #error("Fuzz-only stand-in: it must never be built for an Apple platform.")
#endif

public struct compression_algorithm: Equatable, Sendable {
  public let rawValue: UInt32
  public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_LZFSE = compression_algorithm(0x801)
public let COMPRESSION_LZMA = compression_algorithm(0x306)
public let COMPRESSION_ZLIB = compression_algorithm(0x205)
public let COMPRESSION_LZ4 = compression_algorithm(0x100)

public func compression_decode_scratch_buffer_size(_ algorithm: compression_algorithm) -> Int {
  64
}
public func compression_decode_buffer(
  _ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
  _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm
) -> Int {
  guard srcSize >= 8 else { return 0 }
  var declared = 0
  for index in 0..<4 { declared |= Int(src[4 + index]) << (index * 8) }
  let count = min(declared, dstSize)
  dst.initialize(repeating: 0, count: count)
  return count
}
