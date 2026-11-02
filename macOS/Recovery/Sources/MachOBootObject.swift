import Foundation

/// Checks a Mach-O Stage 1 before kmutil enrolls it. kmutil records the size
/// of __TEXT_BOOT_EXEC as the boot policy's kcbz, and iBoot starts SPTM only
/// when kcbz is nonzero, so the object must not have that segment. Aura's
/// boot objects (aura tools/macho_boot_object.py) also keep every segment
/// fully file-backed at its virtual offset, which is how iBoot places them.
enum MachOBootObject {
  struct Invalid: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { "The Mach-O startup software is invalid: \(reason)." }
  }

  static let required = ["__TEXT", "__TEXT_EXEC", "__PRELINK_INFO", "__LINKEDIT"]

  static func check(_ data: Data) throws {
    let bytes = [UInt8](data)
    func u32(_ offset: Int) throws -> UInt32 {
      guard offset >= 0, offset + 4 <= bytes.count else { throw Invalid(reason: "truncated") }
      return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
      UInt64(try u32(offset)) | UInt64(try u32(offset + 4)) << 32
    }
    guard try u32(0) == 0xFEED_FACF, try u32(4) == 0x0100_000C else {
      throw Invalid(reason: "not a 64-bit Arm Mach-O image")
    }
    guard try u32(12) == 12 else { throw Invalid(reason: "not a fileset boot object") }
    let count = Int(try u32(16))
    let size = Int(try u32(20))
    guard 32 + size <= bytes.count else { throw Invalid(reason: "load commands are truncated") }
    var segments: [String: (vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64)] =
      [:]
    var entry: UInt64?
    var offset = 32
    for _ in 0..<count {
      let command = try u32(offset)
      let length = Int(try u32(offset + 4))
      guard length >= 8, length % 8 == 0, offset + length <= 32 + size else {
        throw Invalid(reason: "malformed load command")
      }
      if command == 0x19 {  // LC_SEGMENT_64
        guard length >= 72 else { throw Invalid(reason: "malformed segment") }
        let name = String(
          decoding: bytes[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
        guard segments[name] == nil else { throw Invalid(reason: "duplicate segment \(name)") }
        segments[name] = (
          try u64(offset + 24), try u64(offset + 32), try u64(offset + 40), try u64(offset + 48)
        )
      } else if command == 0x5 {  // LC_UNIXTHREAD
        guard length >= 16 + 34 * 8, try u32(offset + 8) == 6 else {
          throw Invalid(reason: "malformed entry thread")
        }
        entry = try u64(offset + 16 + 32 * 8)
      }
      offset += length
    }
    guard offset == 32 + size else { throw Invalid(reason: "load command sizes disagree") }
    if let boot = segments["__TEXT_BOOT_EXEC"], boot.vmsize != 0 || boot.filesize != 0 {
      throw Invalid(reason: "it has __TEXT_BOOT_EXEC, so iBoot would start SPTM")
    }
    for name in required where segments[name] == nil {
      throw Invalid(reason: "it has no \(name) segment")
    }
    let base = segments["__TEXT"]!.vmaddr
    guard segments["__TEXT"]!.fileoff == 0 else {
      throw Invalid(reason: "__TEXT is not at offset 0")
    }
    for (name, segment) in segments where segment.vmsize != 0 {
      guard segment.vmaddr >= base, segment.fileoff == segment.vmaddr - base,
        segment.filesize == segment.vmsize,
        segment.fileoff <= UInt64(bytes.count),
        segment.filesize <= UInt64(bytes.count) - segment.fileoff
      else { throw Invalid(reason: "\(name) is not file-backed at its virtual offset") }
    }
    let code = segments["__TEXT_EXEC"]!
    guard let entry, entry >= code.vmaddr, entry - code.vmaddr < code.vmsize else {
      throw Invalid(reason: "its entry point is outside __TEXT_EXEC")
    }
  }

  /// kmutil's own derivation, printed by `kmutil inspect --show-mach-boot-properties`.
  static func bootExecSize(fromInspection output: String) -> UInt64? {
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2, parts[0] == "kcbz" { return UInt64(parts[1]) }
    }
    return nil
  }
}
