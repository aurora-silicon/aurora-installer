import Foundation
import RecoveryCompression

/// The resource fork of a file stored with decmpfs type 12, as the main
/// installer's NativeStubStreamWriter writes it and as Apple's own stubs keep
/// arm64eBaseSystem.dmg: the file's bytes in 64 KiB blocks, each compressed
/// with LZFSE, after a table of little-endian UInt32 offsets from the fork's
/// start, one per block and a last one at the fork's end. The data fork stays
/// empty; `attribute` is the `com.apple.decmpfs` header ("fpmc", type 12, the
/// plain length) that, with UF_COMPRESSED, makes APFS read the file through
/// it. Only one block of input is held at a time; `write` puts bytes at an
/// offset of the fork.
final class RestoreImageResourceFork {
  static let blockBytes = 65536

  let expected: Int
  private let write: (Data, Int) throws -> Void
  private var input = [UInt8]()
  private var offsets = [UInt32]()
  private var position: Int
  private var received = 0

  init(bytes: Int, write: @escaping (Data, Int) throws -> Void) throws {
    guard bytes >= 0, bytes <= RestoreImageDirectory.maximumMember else {
      throw RestoreImageStubFiles.Failure.invalidPlan
    }
    expected = bytes
    self.write = write
    position = ((bytes + Self.blockBytes - 1) / Self.blockBytes + 1) * 4
  }

  func append(_ data: Data) throws {
    guard data.count <= expected - received else { throw RestoreImageStubFiles.Failure.changedFile }
    var cursor = data.startIndex
    while cursor < data.endIndex {
      let count = min(Self.blockBytes - input.count, data.endIndex - cursor)
      input += data[cursor..<(cursor + count)]
      cursor += count
      if input.count == Self.blockBytes { try block() }
    }
    received += data.count
  }

  /// Writes the last block and the offset table, once every byte is in.
  func finish() throws {
    guard received == expected else { throw RestoreImageStubFiles.Failure.changedFile }
    if !input.isEmpty { try block() }
    guard position <= Int(UInt32.max) else { throw RestoreImageStubFiles.Failure.writeFailed }
    offsets.append(UInt32(position))
    var table = Data()
    for value in offsets {
      table += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }
    try write(table, 0)
  }

  /// The `com.apple.decmpfs` value for a type-12 file of `bytes` bytes.
  static func attribute(bytes: Int) -> Data {
    Data([0x66, 0x70, 0x6d, 0x63, 12, 0, 0, 0])
      + (0..<8).map { UInt8(truncatingIfNeeded: UInt64(bytes) >> (8 * UInt64($0))) }
  }

  private func block() throws {
    var output = [UInt8](repeating: 0, count: 2 * Self.blockBytes)
    let count = input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer { target in
        aurora_lzfse_encode(target.baseAddress!, target.count, source.baseAddress!, source.count)
      }
    }
    guard count > 0, position <= Int(UInt32.max) - count else {
      throw RestoreImageStubFiles.Failure.writeFailed
    }
    offsets.append(UInt32(position))
    try write(Data(output.prefix(count)), position)
    position += count
    input.removeAll(keepingCapacity: true)
  }
}
