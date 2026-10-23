// SPDX-License-Identifier: MIT
import Compression
import CryptoKit
import Foundation
import XCTest
import zlib

@testable import AuroraFirmware

/// Measures the image path's stages on the machine running the tests and
/// prints them. It runs only when asked for by name, for example through the
/// native checks' `test-filter` input, because it takes a while.
final class DecodeThroughputReportTests: XCTestCase {
  private struct Source: FirmwareRangeReading {
    let bytes: Data
    var sizeBytes: Int { bytes.count }
    func read(offset: Int, count: Int) async throws -> Data {
      bytes.subdata(in: offset..<(offset + count))
    }
  }

  func testDecodeThroughputReport() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["NATIVE_TEST_FILTER"]?.contains("ThroughputReport")
        == true, "Run by name to measure.")
    let raw = Self.filesystemLikeImage(bytes: 512 << 20)
    let deflated = try Self.deflate(raw)
    let archive = try await IPSWArchive.open(Source(bytes: Self.zip(raw: raw, deflated: deflated)))
    let member = try XCTUnwrap(archive.members.first)
    var report = [String]()
    func rate(_ name: String, bytes: Int, _ seconds: Double) {
      report.append(
        String(format: "%@: %.0f MB/s (%.2f s)", name, Double(bytes) / seconds / 1e6, seconds))
    }
    func time(_ body: () async throws -> Void) async rethrows -> Double {
      let start = ContinuousClock.now
      try await body()
      let elapsed = ContinuousClock.now - start
      return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
    report.append(
      "image: \(raw.count) bytes, deflate-6 \(deflated.count) bytes, "
        + String(format: "%.1f%% zero 4 KiB blocks", Self.zeroFraction(raw) * 100))

    // The writer's consumer: device-like writes to a private file.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "decode-throughput-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func writer() throws -> (Int32, @Sendable (Data) throws -> Void) {
      let descriptor = open(
        directory.appendingPathComponent(UUID().uuidString).path, O_RDWR | O_CREAT, 0o600)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      final class Offset: @unchecked Sendable { var value: off_t = 0 }
      let offset = Offset()
      return (
        descriptor,
        { bytes in
          let written = bytes.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, $0.count, offset.value)
          }
          guard written == bytes.count else { throw CocoaError(.fileWriteUnknown) }
          offset.value += off_t(written)
        }
      )
    }

    let (first, write) = try writer()
    var inline = ""
    let serial = try await time {
      inline = try await archive.stream(
        member, maximumBytes: member.sizeBytes, maximumCompressedBytes: member.compressedSize,
        consume: write)
    }
    close(first)
    rate("decode, hash and write, one after another (before)", bytes: raw.count, serial)

    let (second, overlappedWrite) = try writer()
    var overlapped = ""
    let parallel = try await time {
      overlapped = try await archive.streamOverlapped(
        member, maximumBytes: member.sizeBytes, maximumCompressedBytes: member.compressedSize,
        consume: overlappedWrite)
    }
    close(second)
    XCTAssertEqual(overlapped, inline)
    rate("decode, hash and write overlapped (after)", bytes: raw.count, parallel)

    let inflating = try await time { _ = try Self.inflate(deflated, size: raw.count) }
    rate("zlib inflate alone", bytes: raw.count, inflating)
    let hashing = await time { _ = SHA256.hash(data: raw) }
    rate("SHA-256 alone", bytes: raw.count, hashing)
    let checksumming = await time {
      _ = raw.withUnsafeBytes {
        zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
      }
    }
    rate("CRC-32 alone", bytes: raw.count, checksumming)
    for (name, algorithm) in [
      ("Compression ZLIB (same deflate stream)", COMPRESSION_ZLIB),
      ("Compression LZFSE", COMPRESSION_LZFSE), ("Compression LZ4", COMPRESSION_LZ4),
    ] {
      let encoded =
        algorithm == COMPRESSION_ZLIB ? deflated : try Self.encode(raw, algorithm: algorithm)
      var decoded = Data()
      let seconds = try await time {
        decoded = try Self.decode(encoded, size: raw.count, algorithm: algorithm)
      }
      XCTAssertEqual(decoded.count, raw.count)
      XCTAssertTrue(decoded == raw, name)
      rate("\(name), \(encoded.count) bytes", bytes: raw.count, seconds)
    }
    print("DECODE THROUGHPUT REPORT\n" + report.joined(separator: "\n"))
  }

  /// Zero blocks, repetitive text-like blocks and random blocks in about the
  /// proportions of a filesystem image.
  private static func filesystemLikeImage(bytes count: Int) -> Data {
    var data = Data(count: count)
    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next() -> UInt64 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }
    let words = Array("the quick install of linux on apple silicon writes blocks ".utf8)
    data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      for block in stride(from: 0, to: count, by: 4096) {
        let kind = next() % 100
        if kind < 56 { continue }
        for index in block..<min(block + 4096, count) {
          buffer[index] =
            kind < 86
            ? words[(index &+ Int(kind)) % words.count] &+ UInt8(index % 512 == 0 ? 1 : 0)
            : UInt8(truncatingIfNeeded: next())
        }
      }
    }
    return data
  }

  private static func zeroFraction(_ data: Data) -> Double {
    let zero = Data(count: 4096)
    var zeros = 0
    for block in stride(from: 0, to: data.count, by: 4096)
    where data[block..<(block + 4096)] == zero {
      zeros += 1
    }
    return Double(zeros) / Double(data.count / 4096)
  }

  private static func deflate(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard
      deflateInit2_(
        &stream, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw CocoaError(.featureUnsupported) }
    defer { deflateEnd(&stream) }
    var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { target in
      data.withUnsafeBytes { source in
        stream.next_in = UnsafeMutablePointer(
          mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(source.count)
        stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(capacity)
        return zlib.deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw CocoaError(.featureUnsupported) }
    return output.prefix(Int(stream.total_out))
  }

  private static func inflate(_ data: Data, size: Int) throws -> Data {
    var stream = z_stream()
    guard
      inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw CocoaError(.featureUnsupported) }
    defer { inflateEnd(&stream) }
    var output = Data(count: size)
    let status = output.withUnsafeMutableBytes { target in
      data.withUnsafeBytes { source in
        stream.next_in = UnsafeMutablePointer(
          mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(source.count)
        stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(size)
        return zlib.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw CocoaError(.featureUnsupported) }
    return output
  }

  private static func encode(_ data: Data, algorithm: compression_algorithm) throws -> Data {
    var output = Data(count: data.count + 65536)
    let capacity = output.count
    let count = output.withUnsafeMutableBytes { target in
      data.withUnsafeBytes { source in
        compression_encode_buffer(
          target.bindMemory(to: UInt8.self).baseAddress!, capacity,
          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, algorithm)
      }
    }
    guard count > 0 else { throw CocoaError(.featureUnsupported) }
    return output.prefix(count)
  }

  private static func decode(_ data: Data, size: Int, algorithm: compression_algorithm) throws
    -> Data
  {
    var output = Data(count: size)
    let count = output.withUnsafeMutableBytes { target in
      data.withUnsafeBytes { source in
        compression_decode_buffer(
          target.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, algorithm)
      }
    }
    guard count == size else { throw CocoaError(.featureUnsupported) }
    return output
  }

  /// One deflated member in a single-disk ZIP.
  private static func zip(raw: Data, deflated: Data) -> Data {
    func little(_ value: Int, _ width: Int) -> Data {
      Data((0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
    let name = Data("root.img".utf8)
    let crc = raw.withUnsafeBytes {
      Int(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)))
    }
    var local = Data([0x50, 0x4b, 0x03, 0x04]) + little(20, 2) + little(0, 2) + little(8, 2)
    local += little(0, 4) + little(crc, 4) + little(deflated.count, 4) + little(raw.count, 4)
    local += little(name.count, 2) + little(0, 2) + name
    var central = Data([0x50, 0x4b, 0x01, 0x02]) + little(20, 2) + little(20, 2) + little(0, 2)
    central += little(8, 2) + little(0, 4) + little(crc, 4) + little(deflated.count, 4)
    central += little(raw.count, 4) + little(name.count, 2) + little(0, 2) + little(0, 2)
    central += little(0, 2) + little(0, 2) + little(0, 4) + little(0, 4) + name
    let directory = local.count + deflated.count
    var end = Data([0x50, 0x4b, 0x05, 0x06]) + little(0, 2) + little(0, 2) + little(1, 2)
    end += little(1, 2) + little(central.count, 4) + little(directory, 4) + little(0, 2)
    return local + deflated + central + end
  }
}
