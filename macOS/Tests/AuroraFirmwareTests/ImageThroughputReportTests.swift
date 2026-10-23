import Compression
import CryptoKit
import Foundation
import XCTest
import zlib

@testable import AuroraFirmware

/// Measures each stage of writing a deflated disk image on the machine
/// running the tests, and the whole write with and without the stages
/// overlapped. It runs only when the native checks are dispatched with a
/// `test-filter` naming it, since it takes a while. The report goes to the
/// test log and, on CI, to `installer-ci/image-throughput.txt` in the macOS
/// evidence.
final class ImageThroughputReportTests: XCTestCase {
  private struct Source: FirmwareRangeReading {
    let bytes: Data
    var sizeBytes: Int { bytes.count }
    func read(offset: Int, count: Int) async throws -> Data {
      bytes.subdata(in: offset..<(offset + count))
    }
  }

  /// Writes each chunk after the last, as the device writer does.
  private final class FileSink: @unchecked Sendable {
    let descriptor: Int32
    private var offset: off_t = 0

    init(_ url: URL) throws {
      descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    deinit { close(descriptor) }

    func write(_ bytes: Data) throws {
      let written = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, offset) }
      guard written == bytes.count else { throw CocoaError(.fileWriteUnknown) }
      offset += off_t(written)
    }
  }

  func testImageThroughputReport() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      environment["NATIVE_TEST_FILTER"]?.contains("ImageThroughputReport") == true,
      "Dispatch the native checks with this test as the filter to measure.")
    let raw = try Self.filesystemLikeImage(bytes: 512 << 20)
    let deflated = try SingleMemberZIP.deflated(raw)
    let archive = try await IPSWArchive.open(
      Source(bytes: SingleMemberZIP.archive(name: "root.img", raw: raw, deflate: true)))
    let member = try XCTUnwrap(archive.members.first)
    var report = [
      "image: \(raw.count) bytes, \(deflated.count) deflated at level 6, "
        + String(format: "%.0f%% zero 4 KiB blocks", Self.zeroFraction(raw) * 100)
    ]
    func rate(_ name: String, _ seconds: Double) {
      report.append(
        String(
          format: "%@: %.0f MB/s, %.3f s", name, Double(raw.count) / seconds / 1e6, seconds))
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "image-throughput-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func sink(_ name: String) throws -> FileSink {
      try FileSink(directory.appendingPathComponent(name))
    }

    // Warm the archive's source and the file system once.
    let warm = try sink("warm")
    _ = try await archive.stream(
      member, maximumBytes: member.sizeBytes, maximumCompressedBytes: member.compressedSize,
      consume: warm.write)

    rate(
      "decode alone, as the archive streams it",
      try await Self.seconds {
        _ = try await archive.stream(
          member, maximumBytes: member.sizeBytes, maximumCompressedBytes: member.compressedSize
        ) { _ in }
      })

    for round in 1...2 {
      let serialSink = try sink("serial-\(round)")
      var serial = ""
      rate(
        "round \(round): decode, check and write one after another",
        try await Self.seconds {
          serial = try await archive.stream(
            member, maximumBytes: member.sizeBytes,
            maximumCompressedBytes: member.compressedSize, consume: serialSink.write)
        })
      let pipelinedSink = try sink("pipelined-\(round)")
      var pipelined = ""
      rate(
        "round \(round): decode, check and write overlapped",
        try await Self.seconds {
          pipelined = try await archive.streamPipelined(
            member, maximumBytes: member.sizeBytes,
            maximumCompressedBytes: member.compressedSize, consume: pipelinedSink.write)
        })
      XCTAssertEqual(pipelined, serial)
      XCTAssertEqual(pipelined, raw.sha256)
    }

    rate(
      "zlib inflate alone, one call",
      try await Self.seconds { _ = try Self.inflate(deflated, size: raw.count) })
    rate(
      "system decoder, same deflate stream, one call",
      try await Self.seconds {
        XCTAssertTrue(try Self.decode(deflated, size: raw.count) == raw)
      })
    rate(
      "zlib inflate alone, 4 MiB in and 1 MiB out at a time",
      try await Self.seconds {
        XCTAssertEqual(try Self.inflateStreaming(deflated), raw.count)
      })
    rate(
      "system decoder alone, 4 MiB in and 1 MiB out at a time",
      try await Self.seconds {
        XCTAssertEqual(try Self.decodeStreaming(deflated), raw.count)
      })
    rate("SHA-256 alone", await Self.seconds { _ = SHA256.hash(data: raw) })
    rate("CRC-32 alone", await Self.seconds { _ = SingleMemberZIP.crc32(raw) })
    let writeOnly = try sink("write-only")
    rate(
      "file writes alone, 1 MiB each",
      try await Self.seconds {
        for start in stride(from: 0, to: raw.count, by: 1 << 20) {
          try writeOnly.write(raw.subdata(in: start..<min(start + (1 << 20), raw.count)))
        }
      })

    let text = "IMAGE THROUGHPUT REPORT\n" + report.joined(separator: "\n") + "\n"
    print(text)
    if let temporary = environment["RUNNER_TEMP"] {
      let evidence = URL(fileURLWithPath: temporary).appendingPathComponent("installer-ci")
      try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: evidence.appendingPathComponent("image-throughput.txt"))
    }
  }

  private static func seconds(_ body: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await body()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  /// About half zero blocks, as an image with free space has, and the rest
  /// compiled code with a few random blocks. The code is this test bundle's
  /// own executable, repeated; deflate only looks back 32 KiB, so the
  /// repetition does not make it compress better.
  private static func filesystemLikeImage(bytes count: Int) throws -> Data {
    let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
    let code = try Data(contentsOf: executable, options: .alwaysMapped)
    try XCTSkipIf(code.count < 1 << 20, "The test executable is too small to sample.")
    var data = Data(count: count)
    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next() -> UInt64 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }
    var cursor = 0
    data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      code.withUnsafeBytes { (code: UnsafeRawBufferPointer) in
        for block in stride(from: 0, to: count, by: 4096) {
          let kind = next() % 100
          if kind < 50 { continue }
          if kind < 92 {
            if cursor + 4096 > code.count { cursor = 0 }
            buffer.baseAddress!.advanced(by: block).copyMemory(
              from: code.baseAddress!.advanced(by: cursor), byteCount: 4096)
            cursor += 4096
          } else {
            for word in stride(from: block, to: block + 4096, by: 8) {
              buffer.storeBytes(of: next(), toByteOffset: word, as: UInt64.self)
            }
          }
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

  private static func inflate(_ data: Data, size: Int) throws -> Data {
    var stream = z_stream()
    guard
      inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw RestoreFailure("Cannot start the decoder.") }
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
    guard status == Z_STREAM_END else { throw RestoreFailure("Decoding failed.") }
    return output
  }

  /// Inflates as the archive does, into one reused 1 MiB buffer, and counts
  /// the bytes.
  private static func inflateStreaming(_ data: Data) throws -> Int {
    var stream = z_stream()
    guard
      inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw RestoreFailure("Cannot start the decoder.") }
    defer { inflateEnd(&stream) }
    let output = UnsafeMutablePointer<Bytef>.allocate(capacity: 1 << 20)
    defer { output.deallocate() }
    var produced = 0
    var offset = 0
    var status = Z_OK
    try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
      let base = source.bindMemory(to: Bytef.self).baseAddress!
      while status != Z_STREAM_END {
        // Output can still be pending once all input is in.
        if stream.avail_in == 0, offset < data.count {
          let count = min(4 << 20, data.count - offset)
          stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: offset))
          stream.avail_in = uInt(count)
          offset += count
        }
        stream.next_out = output
        stream.avail_out = uInt(1 << 20)
        let consumed = stream.total_in
        status = zlib.inflate(&stream, Z_NO_FLUSH)
        let count = (1 << 20) - Int(stream.avail_out)
        guard status == Z_OK || status == Z_STREAM_END,
          count > 0 || stream.total_in > consumed || status == Z_STREAM_END
        else { throw RestoreFailure("Decoding failed.") }
        produced += count
      }
    }
    return produced
  }

  /// The same, through the system compression library's stream interface.
  private static func decodeStreaming(_ data: Data) throws -> Int {
    var stream = compression_stream(
      dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
      src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    guard
      compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else { throw RestoreFailure("Cannot start the decoder.") }
    defer { compression_stream_destroy(&stream) }
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    defer { output.deallocate() }
    var produced = 0
    var offset = 0
    var status = COMPRESSION_STATUS_OK
    try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
      let base = source.bindMemory(to: UInt8.self).baseAddress!
      var idle = 0
      while status != COMPRESSION_STATUS_END {
        // Output can still be pending once all input is in.
        if stream.src_size == 0, offset < data.count {
          let count = min(4 << 20, data.count - offset)
          stream.src_ptr = base.advanced(by: offset)
          stream.src_size = count
          offset += count
        }
        let flags = offset == data.count ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        stream.dst_ptr = output
        stream.dst_size = 1 << 20
        status = compression_stream_process(&stream, flags)
        guard status != COMPRESSION_STATUS_ERROR else { throw RestoreFailure("Decoding failed.") }
        let count = (1 << 20) - stream.dst_size
        idle = count == 0 && stream.src_size == 0 && offset == data.count ? idle + 1 : 0
        guard idle < 2 else { throw RestoreFailure("Truncated stream.") }
        produced += count
      }
    }
    return produced
  }

  /// The same raw deflate stream through the system compression library.
  private static func decode(_ data: Data, size: Int) throws -> Data {
    var output = Data(count: size)
    let count = output.withUnsafeMutableBytes { target in
      data.withUnsafeBytes { source in
        compression_decode_buffer(
          target.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard count == size else { throw RestoreFailure("Decoding failed.") }
    return output
  }
}
