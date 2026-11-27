import Foundation

/// Reads one section of a Mach-O file: a 64-bit thin file, or the arm64
/// slice of a universal one. The helper carries its launchd job in
/// `__TEXT,__launchd_plist`, covered by its signature.
enum MachOSection {
  private static let thinMagic: UInt32 = 0xfeed_facf
  private static let fatMagic: UInt32 = 0xcafe_babe
  private static let fat64Magic: UInt32 = 0xcafe_babf
  private static let arm64: UInt32 = 0x0100_000c
  private static let segmentCommand: UInt32 = 0x19

  static func contents(segment: String, section: String, of file: Data) -> Data? {
    guard let magic = file.integer(UInt32.self, at: 0, bigEndian: true) else {
      return nil
    }
    switch magic {
    case fatMagic, fat64Magic:
      let wide = magic == fat64Magic
      let entrySize = wide ? 32 : 20
      guard let count = file.integer(UInt32.self, at: 4, bigEndian: true), count <= 64 else {
        return nil
      }
      for index in 0..<Int(count) {
        let entry = 8 + index * entrySize
        guard let cpu = file.integer(UInt32.self, at: entry, bigEndian: true), cpu == arm64
        else { continue }
        let offset =
          wide
          ? file.integer(UInt64.self, at: entry + 8, bigEndian: true)
          : file.integer(UInt32.self, at: entry + 8, bigEndian: true).map(UInt64.init)
        let size =
          wide
          ? file.integer(UInt64.self, at: entry + 16, bigEndian: true)
          : file.integer(UInt32.self, at: entry + 12, bigEndian: true).map(UInt64.init)
        guard let offset, let size, let slice = file.range(offset, size) else {
          return nil
        }
        return thin(segment: segment, section: section, of: file.subdata(in: slice))
      }
      return nil
    default:
      return thin(segment: segment, section: section, of: file)
    }
  }

  private static func thin(segment: String, section: String, of file: Data) -> Data? {
    guard file.integer(UInt32.self, at: 0, bigEndian: false) == thinMagic,
      let commands = file.integer(UInt32.self, at: 16, bigEndian: false), commands <= 4_096
    else {
      return nil
    }
    var command = 32
    for _ in 0..<commands {
      guard let kind = file.integer(UInt32.self, at: command, bigEndian: false),
        let size = file.integer(UInt32.self, at: command + 4, bigEndian: false), size >= 8
      else {
        return nil
      }
      if kind == segmentCommand, file.name(at: command + 8) == segment,
        let sections = file.integer(UInt32.self, at: command + 64, bigEndian: false),
        72 + Int(sections) * 80 <= Int(size)
      {
        for index in 0..<Int(sections) {
          let entry = command + 72 + index * 80
          guard file.name(at: entry) == section else { continue }
          guard let length = file.integer(UInt64.self, at: entry + 40, bigEndian: false),
            let offset = file.integer(UInt32.self, at: entry + 48, bigEndian: false),
            let range = file.range(UInt64(offset), length)
          else {
            return nil
          }
          return file.subdata(in: range)
        }
      }
      command += Int(size)
    }
    return nil
  }
}

extension Data {
  fileprivate func integer<Value: FixedWidthInteger>(
    _: Value.Type, at offset: Int, bigEndian: Bool
  ) -> Value? {
    guard offset >= 0, offset <= count - MemoryLayout<Value>.size else {
      return nil
    }
    let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
    return bigEndian ? Value(bigEndian: value) : Value(littleEndian: value)
  }

  /// A fixed 16-byte segment or section name.
  fileprivate func name(at offset: Int) -> String? {
    guard offset >= 0, offset <= count - 16 else {
      return nil
    }
    let bytes = self[(startIndex + offset)..<(startIndex + offset + 16)].prefix { $0 != 0 }
    return String(bytes: bytes, encoding: .utf8)
  }

  fileprivate func range(_ offset: UInt64, _ length: UInt64) -> Range<Int>? {
    guard offset <= UInt64(count), length <= UInt64(count) - offset else {
      return nil
    }
    return (startIndex + Int(offset))..<(startIndex + Int(offset + length))
  }
}
