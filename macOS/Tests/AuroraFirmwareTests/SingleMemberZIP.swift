import Foundation
import zlib

@testable import AuroraFirmware

/// Builds a single-disk ZIP of one member for streaming tests.
enum SingleMemberZIP {
  static func archive(name: String, raw: Data, deflate: Bool) throws -> Data {
    let body = deflate ? try deflated(raw) : raw
    let crc = crc32(raw)
    let method = deflate ? 8 : 0
    let nameBytes = Data(name.utf8)
    var local = Data([0x50, 0x4b, 0x03, 0x04]) + littleBytes(20, count: 2)
    local += littleBytes(0, count: 2) + littleBytes(method, count: 2) + littleBytes(0, count: 4)
    local += littleBytes(crc, count: 4) + littleBytes(body.count, count: 4)
    local += littleBytes(raw.count, count: 4) + littleBytes(nameBytes.count, count: 2)
    local += littleBytes(0, count: 2) + nameBytes
    var central = Data([0x50, 0x4b, 0x01, 0x02]) + littleBytes(20, count: 2)
    central += littleBytes(20, count: 2) + littleBytes(0, count: 2)
    central += littleBytes(method, count: 2) + littleBytes(0, count: 4)
    central += littleBytes(crc, count: 4) + littleBytes(body.count, count: 4)
    central += littleBytes(raw.count, count: 4) + littleBytes(nameBytes.count, count: 2)
    central += littleBytes(0, count: 2) + littleBytes(0, count: 2) + littleBytes(0, count: 2)
    central += littleBytes(0, count: 2) + littleBytes(0, count: 4) + littleBytes(0, count: 4)
    central += nameBytes
    let directory = local.count + body.count
    var end = Data([0x50, 0x4b, 0x05, 0x06]) + littleBytes(0, count: 2)
    end += littleBytes(0, count: 2) + littleBytes(1, count: 2) + littleBytes(1, count: 2)
    end += littleBytes(central.count, count: 4) + littleBytes(directory, count: 4)
    end += littleBytes(0, count: 2)
    return local + body + central + end
  }

  static func crc32(_ data: Data) -> Int {
    data.withUnsafeBytes {
      Int(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)))
    }
  }

  /// A raw deflate stream, as a ZIP member holds it.
  static func deflated(_ data: Data, level: Int32 = 6) throws -> Data {
    var stream = z_stream()
    guard
      deflateInit2_(
        &stream, level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw RestoreFailure("Cannot start the fixture encoder.") }
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
    guard status == Z_STREAM_END else { throw RestoreFailure("Fixture encoding failed.") }
    return output.prefix(Int(stream.total_out))
  }

  /// Bytes whose every 8-byte word holds its own offset, so a chunk
  /// delivered out of order or twice changes the result.
  static func numbered(bytes count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      for offset in stride(from: 0, to: count - 7, by: 8) {
        buffer.storeBytes(of: UInt64(offset).littleEndian, toByteOffset: offset, as: UInt64.self)
      }
    }
    return data
  }
}

/// Collects what a pipeline stage hands it.
final class CollectedChunks: @unchecked Sendable {
  private let lock = NSLock()
  private var collected = Data()
  private var calls = 0

  var data: Data { lock.withLock { collected } }
  var count: Int { lock.withLock { calls } }

  /// Returns how many chunks have arrived, this one included.
  @discardableResult
  func append(_ chunk: Data) -> Int {
    lock.withLock {
      collected.append(chunk)
      calls += 1
      return calls
    }
  }
}
