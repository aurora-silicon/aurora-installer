import Foundation

/// Which Stage 1 boot object a Mac enrolls. Every Mac enrolls aura's Mach-O
/// boot object (aura build/aura-boot.macho); none enrolls the raw image.
public enum AuraStage1Format {
  /// M4-generation and later chips keep aura and the kernel's code inside an
  /// execute window: T8132 (M4), T6040/T6041 (M4 Pro/Max), T8140 (A18 Pro),
  /// T8142 and T605x (M5) and whatever follows them. Their object is padded for
  /// that window, enrolled with `--compress`, and loads the confined Stage 2.
  /// Apple numbers each generation upward, so M1 to M3 (T8103, T8112, T8122,
  /// T600x, T602x, T603x) stay below both bounds: they enroll the object
  /// unpadded and load the standard Stage 2. An unpadded object needs aura
  /// 1.0.0b10-g2296392f or later (aura#134), whose Stage 1 stops its payload scan
  /// at the object's __PRELINK_INFO.
  public static func usesExecuteWindow(chipID: UInt64) -> Bool {
    (0x8130...0x8FFF).contains(chipID) || (0x6040...0x6FFF).contains(chipID)
  }

  /// The ESP file an unpadded Stage 1 loads.
  public static let standardStage2Path = "m1n1/boot.bin"
  /// The ESP file a padded Stage 1 loads. Package updates on execute-window
  /// chips write this one.
  public static let confinedStage2Path = "m1n1/boot-ctxr.bin"

  public static func stage2Path(executeWindow: Bool) -> String {
    executeWindow ? confinedStage2Path : standardStage2Path
  }
}

/// The configuration block in aura's Stage 1 (aura src/stage1_config.c): magic,
/// then version, proxy window, a NUL-padded ESP PARTUUID and a NUL-padded Stage 2
/// path, then the CRC-32 of those fields. It reads the same in a raw image and in
/// the boot object that carries one.
public enum Stage1Configuration {
  public struct Invalid: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? {
      "The startup software's configuration is invalid: \(reason)."
    }
  }

  static let magic = Data("AURORA-S1-CFG01\0".utf8)
  static let uuidRange = 8..<48
  static let pathRange = 48..<240

  /// The ESP and Stage 2 a filled Stage 1 chainloads.
  public static func read(_ image: Data) throws -> (espUUID: String, stage2Path: String) {
    let (_, body) = try block(in: Data(image))
    let uuid = body[uuidRange].prefix { $0 != 0 }
    let path = body[pathRange].prefix { $0 != 0 }
    guard uuid.count == 36,
      body[(uuidRange.lowerBound + 36)..<uuidRange.upperBound].allSatisfy({ $0 == 0 }),
      UUID(uuidString: String(decoding: uuid, as: UTF8.self)) != nil,
      path.first == UInt8(ascii: ";"),
      body[(pathRange.lowerBound + path.count)..<pathRange.upperBound].allSatisfy({ $0 == 0 })
    else { throw Invalid(reason: "it names no startup partition and path") }
    return (
      String(decoding: uuid, as: UTF8.self), String(decoding: path.dropFirst(), as: UTF8.self)
    )
  }

  /// Returns `image` chainloading `stage2Path`, with every other byte unchanged.
  public static func retargeted(_ image: Data, stage2Path: String) throws -> Data {
    let image = Data(image)
    _ = try read(image)
    let encoded = Array((";" + stage2Path).utf8)
    guard encoded.count < pathRange.count, stage2Path.utf8.count > 0,
      stage2Path.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != 0x3B && $0 != 0x5C })
    else { throw Invalid(reason: "its Stage 2 path cannot be stored") }
    let (offset, fields) = try block(in: image)
    var body = fields
    body.replaceSubrange(
      pathRange, with: encoded + [UInt8](repeating: 0, count: pathRange.count - encoded.count))
    var result = image
    result.replaceSubrange(
      offset..<(offset + body.count + 4),
      with: body + withUnsafeBytes(of: crc32(body).littleEndian, Array.init))
    return result
  }

  /// The block's offset past its magic, and its fields without the CRC.
  private static func block(in image: Data) throws -> (Int, [UInt8]) {
    guard let first = image.range(of: magic),
      image.range(of: magic, in: first.upperBound..<image.endIndex) == nil,
      first.upperBound + pathRange.upperBound + 4 <= image.endIndex
    else { throw Invalid(reason: "it has no single configuration block") }
    let bytes = [UInt8](image[first.upperBound..<(first.upperBound + pathRange.upperBound + 4)])
    let body = Array(bytes.prefix(pathRange.upperBound))
    func word(_ at: Int) -> UInt32 {
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
    guard word(0) == 1, word(pathRange.upperBound) == crc32(body) else {
      throw Invalid(reason: "its version or checksum is wrong")
    }
    return (first.upperBound, body)
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
    }
    return ~crc
  }
}

/// Checks a Mach-O Stage 1 before kmutil enrolls it. kmutil records the size
/// of __TEXT_BOOT_EXEC as the boot policy's kcbz, and iBoot starts SPTM only
/// when kcbz is nonzero, so the object must not have that segment. Aura's
/// boot objects (aura tools/macho_boot_object.py) also keep every segment
/// fully file-backed at its virtual offset, which is how iBoot places them.
public enum MachOBootObject {
  public struct Invalid: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? {
      "The Mach-O startup software is invalid: \(reason)."
    }
  }

  struct Segment {
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
  }

  static let required = ["__TEXT", "__TEXT_EXEC", "__PRELINK_INFO", "__LINKEDIT"]
  /// The raw image's entry point, which the boot object enters at.
  static let rawEntryOffset: UInt64 = 0x800

  public static func check(_ data: Data) throws {
    _ = try layout(data)
  }

  /// `fileSize` is the size of the whole file when `data` is only its start,
  /// as for an expanded object whose padding is never held in memory.
  static func layout(
    _ data: Data, fileSize: UInt64? = nil
  ) throws -> (segments: [String: Segment], entry: UInt64) {
    let bytes = [UInt8](data)
    let total = fileSize ?? UInt64(bytes.count)
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
    var segments: [String: Segment] = [:]
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
        segments[name] = Segment(
          vmaddr: try u64(offset + 24), vmsize: try u64(offset + 32),
          fileoff: try u64(offset + 40), filesize: try u64(offset + 48))
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
        segment.fileoff <= total,
        segment.filesize <= total - segment.fileoff
      else { throw Invalid(reason: "\(name) is not file-backed at its virtual offset") }
    }
    let code = segments["__TEXT_EXEC"]!
    guard let entry, entry >= code.vmaddr, entry - code.vmaddr < code.vmsize else {
      throw Invalid(reason: "its entry point is outside __TEXT_EXEC")
    }
    return (segments, entry)
  }

  /// Returns `object` with the Stage 1 configuration that `filled` carries.
  /// `object` must be aura's boot object for `raw`: the raw image unchanged at
  /// the start of __TEXT_EXEC, then only zero padding, entered at the raw
  /// image's own entry point. `filled` is `raw` with its configuration block
  /// filled, so the result is that boot object made from `filled`.
  public static func fill(_ object: Data, raw: Data, filled: Data) throws -> Data {
    let object = Data(object)
    let (segments, entry) = try layout(object)
    let code = segments["__TEXT_EXEC"]!
    guard !raw.isEmpty, filled.count == raw.count, UInt64(raw.count) <= code.filesize else {
      throw Invalid(reason: "it does not carry this Stage 1")
    }
    guard entry == code.vmaddr + rawEntryOffset else {
      throw Invalid(reason: "it does not enter this Stage 1 at its entry point")
    }
    let start = Int(code.fileoff)
    let end = start + raw.count
    guard object.subdata(in: start..<end) == raw,
      object.subdata(in: end..<(start + Int(code.filesize))).allSatisfy({ $0 == 0 })
    else { throw Invalid(reason: "it does not carry this Stage 1") }
    var result = object
    result.replaceSubrange(start..<end, with: filled)
    return result
  }

  /// The kcrz kmutil should derive for an unpadded object: load address to the
  /// end of __TEXT_EXEC, as for a padded one.
  public static func readOnlySize(_ object: Data) throws -> UInt64 {
    let code = try layout(object).segments["__TEXT_EXEC"]!
    let (end, overflow) = code.fileoff.addingReportingOverflow(code.vmsize)
    guard !overflow else { throw Invalid(reason: "__TEXT_EXEC is too large") }
    return end
  }

  /// kmutil's own derivation, printed by `kmutil inspect --show-mach-boot-properties`.
  public static func bootExecSize(fromInspection output: String) -> UInt64? {
    bootProperty("kcbz", fromInspection: output)
  }

  /// Checks what kmutil derives from a padded object before it is enrolled, and
  /// returns what it relied on. kcrz is what iBoot sizes the window from. Without
  /// kcrz only an exact kcwf, the first writable offset, is accepted, and anything
  /// else refuses, so an unverified object never reaches the boot policy.
  public static func checkInspection(_ output: String, readOnlySize expected: UInt64) throws
    -> String
  {
    guard let boot = bootExecSize(fromInspection: output) else {
      throw Invalid(reason: "kmutil did not report its layout")
    }
    guard boot == 0 else {
      throw Invalid(reason: "kmutil would start SPTM for it (kcbz \(boot))")
    }
    if let region = bootProperty("kcrz", fromInspection: output) {
      guard region == expected else {
        throw Invalid(
          reason: "kmutil derives a read-only region of \(region) bytes, not \(expected)")
      }
      return "kcrz \(region)"
    }
    guard let writable = bootProperty("kcwf", fromInspection: output), writable == expected else {
      throw Invalid(reason: "kmutil did not report a read-only region of \(expected) bytes")
    }
    return "kcwf \(writable), no kcrz"
  }

  static func bootProperty(_ name: String, fromInspection output: String) -> UInt64? {
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2, parts[0] == name { return UInt64(parts[1]) }
    }
    return nil
  }
}

/// How large a code-execute window to ask of iBoot.
///
/// On T8140 and later, iBoot confines each secondary core's EL2 execution to a
/// locked window, CTXR_D. It runs from the device tree through the static trust
/// cache and into the boot object, ending where the object's read-only region
/// ends, which is kmutil's kcrz. Nothing at runtime can move that end, so the
/// only way to grow the window is to enroll an object with a larger kcrz.
public enum ExecuteWindow {
  /// The region CONFIG_ARM64_CTXR_EXECMEM confines kernel code to.
  public static let size: UInt64 = 128 << 20
  /// An arm64 kernel image and that region start on this boundary. iBoot picks
  /// the load address, so the padding has to hold the region at any alignment.
  public static let alignment: UInt64 = 2 << 20
  /// Room kept at the start of __TEXT_EXEC for aura: Stage 1 where iBoot placed
  /// it, then Stage 2 copied over it, each with its .bss and stacks. A confined
  /// Stage 2 file larger than this cannot load.
  public static let auraSlot: UInt64 = 16 << 20
  static let page: UInt64 = 0x4000

  /// The size __TEXT_EXEC needs to hold aura and a `window`-byte aligned region.
  public static func codeSize(window: UInt64 = size, slot: UInt64 = auraSlot) -> UInt64 {
    slot + (alignment - page) + window
  }
}

/// A Mach-O Stage 1 with __TEXT_EXEC padded by file-backed zeros. kmutil derives
/// kcrz from file offsets, so a segment grown only in vmsize leaves it unchanged
/// and the padding has to be in the file. `write(to:)` leaves it as a hole, and
/// `kmutil configure-boot --compress` keeps it from reaching Preboot.
public struct ExpandedMachOBootObject {
  public struct WriteFailure: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? {
      "The expanded startup software could not be saved: \(reason)."
    }
  }

  /// The object through the end of the original __TEXT_EXEC, its load commands
  /// rewritten and its code unchanged.
  public let head: Data
  /// Every segment after __TEXT_EXEC, unchanged.
  public let tail: Data
  /// The zero bytes between `head` and `tail`.
  public let padding: UInt64
  /// The kcrz kmutil should derive: load address to the end of __TEXT_EXEC.
  public let readOnlySize: UInt64

  public var size: UInt64 { UInt64(head.count) + padding + UInt64(tail.count) }

  /// The file is sparse, but kmutil reads and compresses all of it and where it
  /// works isn't documented, so its enrollment counts the whole decompressed size.
  public func requireSpace(freeBytes: UInt64) throws {
    guard freeBytes >= size else {
      throw WriteFailure(
        reason:
          "this volume has \(freeBytes >> 20) MiB free and it needs \((size + (1 << 20) - 1) >> 20) MiB"
      )
    }
  }

  /// Atomically writes the object as a sparse file, which costs about what the
  /// original object does on APFS. Only `head` and `tail` are read back: a new
  /// file's hole reads as zeros, so the padding is never held in memory.
  public func write(to path: URL) throws {
    let directory = path.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      "." + path.lastPathComponent + "." + UUID().uuidString)
    let fd = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WriteFailure(reason: "cannot create the file") }
    var published = false
    defer {
      close(fd)
      if !published { unlink(temporary.path) }
    }
    let tailOffset = off_t(UInt64(head.count) + padding)
    // The final size first, so the padding is a hole whatever the tail holds.
    guard ftruncate(fd, off_t(size)) == 0 else {
      throw WriteFailure(reason: "cannot size the file")
    }
    try Self.writeAll(head, to: fd, at: 0)
    try Self.writeAll(tail, to: fd, at: tailOffset)
    var info = stat()
    guard fstat(fd, &info) == 0, UInt64(info.st_size) == size else {
      throw WriteFailure(reason: "its size is wrong")
    }
    guard try Self.read(fd, count: head.count, at: 0) == head,
      try Self.read(fd, count: tail.count, at: tailOffset) == tail
    else { throw WriteFailure(reason: "it did not verify") }
    guard fsync(fd) == 0 else { throw WriteFailure(reason: "cannot flush the file") }
    guard rename(temporary.path, path.path) == 0 else {
      throw WriteFailure(reason: "cannot move the file into place")
    }
    published = true
    let parent = open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw WriteFailure(reason: "cannot open its directory") }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw WriteFailure(reason: "cannot flush its directory") }
  }

  private static func writeAll(_ bytes: Data, to fd: Int32, at offset: off_t) throws {
    try bytes.withUnsafeBytes { buffer in
      var done = 0
      while done < buffer.count {
        let count = pwrite(
          fd, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
        guard count > 0 else { throw WriteFailure(reason: "cannot write the file") }
        done += count
      }
    }
  }

  private static func read(_ fd: Int32, count: Int, at offset: off_t) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { buffer in
      var done = 0
      while done < buffer.count {
        let got = pread(fd, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
        guard got > 0 else { throw WriteFailure(reason: "cannot read the file back") }
        done += got
      }
    }
    return result
  }
}

extension MachOBootObject {
  /// Pads `object`'s __TEXT_EXEC so that iBoot arms a larger execute window:
  /// aura's code keeps its bytes and addresses, the segment becomes
  /// `ExecuteWindow.codeSize(window:slot:)` bytes, and the segments after it move
  /// up by the same amount in both file and memory, so every segment stays fully
  /// file-backed at its virtual offset, which is how iBoot places them.
  ///
  /// Only load commands this code can move are accepted, so anything it does not
  /// recognize is refused rather than left pointing at the wrong bytes.
  public static func expandExecuteWindow(
    _ object: Data, window: UInt64 = ExecuteWindow.size, slot: UInt64 = ExecuteWindow.auraSlot
  ) throws -> ExpandedMachOBootObject {
    let page = ExecuteWindow.page
    guard window > 0, window % page == 0, slot % page == 0 else {
      throw Invalid(reason: "its execute window is not a whole number of pages")
    }
    guard window <= 1 << 40, slot <= 1 << 40 else {
      throw Invalid(reason: "its execute window is too large")
    }
    func sum(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
      let (result, overflow) = first.addingReportingOverflow(second)
      guard !overflow else { throw Invalid(reason: "an address or offset is out of range") }
      return result
    }
    let (segments, entry) = try layout(object)
    let code = segments["__TEXT_EXEC"]!
    guard entry == code.vmaddr + rawEntryOffset else {
      throw Invalid(reason: "it does not enter aura at its entry point")
    }
    var bytes = [UInt8](object)
    func u32(_ offset: Int) throws -> UInt32 {
      guard offset >= 0, offset + 4 <= bytes.count else { throw Invalid(reason: "truncated") }
      return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
      UInt64(try u32(offset)) | UInt64(try u32(offset + 4)) << 32
    }
    func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
      withUnsafeBytes(of: value.littleEndian) {
        bytes.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0)
      }
    }

    // aura's load header (start.S) gives the memory the image needs, past its file.
    let start = Int(code.fileoff)
    guard start + 0x820 <= bytes.count,
      bytes[(start + loadHeaderOffset)..<(start + loadHeaderOffset + 8)]
        .elementsEqual("AURALOAD".utf8)
    else { throw Invalid(reason: "__TEXT_EXEC does not start with aura") }
    guard try u64(start + loadHeaderOffset + 16) <= slot, code.vmsize <= slot else {
      throw Invalid(reason: "aura does not fit the room kept for it")
    }

    let codeSize = ExecuteWindow.codeSize(window: window, slot: slot)
    let growth = codeSize - code.vmsize
    let codeEnd = try sum(code.vmaddr, code.vmsize)
    let fileEnd = try sum(code.fileoff, code.filesize)
    guard fileEnd % page == 0, code.vmaddr % page == 0 else {
      throw Invalid(reason: "__TEXT_EXEC is not page-aligned")
    }
    func moved32(_ offset: UInt32) throws -> UInt32 {
      guard let result = UInt32(exactly: try sum(UInt64(offset), growth)) else {
        throw Invalid(reason: "its execute window is too large")
      }
      return result
    }

    // The fileset's own commands, then those of each member's header.
    var headers = [0]
    var index = 0
    while index < headers.count {
      guard Set(headers).count == headers.count else {
        throw Invalid(reason: "a fileset member repeats")
      }
      let header = headers[index]
      index += 1
      guard try u32(header) == 0xFEED_FACF else {
        throw Invalid(reason: "a fileset member has no Mach-O header")
      }
      var offset = header + 32
      for _ in 0..<Int(try u32(header + 16)) {
        let command = try u32(offset)
        let length = Int(try u32(offset + 4))
        guard length >= 8, offset + length <= bytes.count else {
          throw Invalid(reason: "malformed load command")
        }
        switch command {
        case 0x19:  // LC_SEGMENT_64
          guard length >= 72 else { throw Invalid(reason: "malformed segment") }
          let vmaddr = try u64(offset + 24)
          let vmsize = try u64(offset + 32)
          let name = String(
            decoding: bytes[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
          if name == "__TEXT_EXEC" {
            guard vmaddr == code.vmaddr, vmsize == code.vmsize else {
              throw Invalid(reason: "two headers disagree about __TEXT_EXEC")
            }
            put(codeSize, at: offset + 32)
            put(codeSize, at: offset + 48)
          } else if vmaddr >= codeEnd {
            put(try sum(vmaddr, growth), at: offset + 24)
            put(try sum(try u64(offset + 40), growth), at: offset + 40)
            let sections = Int(try u32(offset + 64))
            guard length == 72 + 80 * sections else {
              throw Invalid(reason: "malformed segment")
            }
            for section in 0..<sections {
              let entry = offset + 72 + 80 * section
              put(try sum(try u64(entry + 32), growth), at: entry + 32)
              let fileOffset = try u32(entry + 48)
              if fileOffset != 0 { put(try moved32(fileOffset), at: entry + 48) }
            }
          } else if try sum(vmaddr, vmsize) > code.vmaddr {
            throw Invalid(reason: "\(name) overlaps __TEXT_EXEC")
          }
        case 0x8000_0034:  // LC_DYLD_CHAINED_FIXUPS
          // Aura relocates itself, so its table must name no fixup to move.
          let data = Int(try u32(offset + 8))
          let starts = data + Int(try u32(data + 4))
          for segment in 0..<Int(try u32(starts)) where try u32(starts + 4 + 4 * segment) != 0 {
            throw Invalid(reason: "it has chained fixups")
          }
          if UInt64(data) >= fileEnd { put(try moved32(UInt32(data)), at: offset + 8) }
        case 0x8000_0035:  // LC_FILESET_ENTRY
          guard try u64(offset + 8) < code.vmaddr, try u64(offset + 16) < code.fileoff else {
            throw Invalid(reason: "a fileset member is not before __TEXT_EXEC")
          }
          headers.append(Int(try u64(offset + 16)))
        case 0x2, 0xB:  // LC_SYMTAB, LC_DYSYMTAB
          guard bytes[(offset + 8)..<(offset + length)].allSatisfy({ $0 == 0 }) else {
            throw Invalid(reason: "it has a symbol table")
          }
        case 0x5, 0x1B, 0x32:  // LC_UNIXTHREAD, LC_UUID, LC_BUILD_VERSION
          break
        default:
          throw Invalid(reason: "it has a load command that cannot be moved")
        }
        offset += length
      }
    }

    let expanded = ExpandedMachOBootObject(
      head: Data(bytes[0..<Int(fileEnd)]), tail: Data(bytes[Int(fileEnd)...]), padding: growth,
      readOnlySize: try sum(code.fileoff, codeSize))
    _ = try layout(expanded.head, fileSize: expanded.size)
    return expanded
  }

  public static let loadHeaderOffset = 0x808
}
