import Foundation

@main struct MachOBootObjectCheck {
  static let base: UInt64 = 0xFFFF_FE00_0700_4000

  struct Segment {
    var name: String
    var offset: UInt64
    var size: UInt64
    var fileOffset: UInt64? = nil
  }

  static func object(
    _ segments: [Segment], entry: UInt64 = 0x10800, filetype: UInt32 = 12
  ) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
      withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    var commands: [UInt8] = []
    for segment in segments {
      var name = Array(segment.name.utf8)
      name += [UInt8](repeating: 0, count: 16 - name.count)
      commands += le(UInt32(0x19)) + le(UInt32(72)) + name
      commands += le(base + segment.offset) + le(segment.size)
      commands += le(segment.fileOffset ?? segment.offset) + le(segment.size)
      commands += le(UInt32(1)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(0))
    }
    var registers = [UInt64](repeating: 0, count: 34)
    registers[32] = base + entry
    commands += le(UInt32(5)) + le(UInt32(16 + 34 * 8)) + le(UInt32(6)) + le(UInt32(0x44))
    for register in registers { commands += le(register) }
    var bytes = le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0xC000_0002))
    bytes += le(filetype) + le(UInt32(segments.count + 1)) + le(UInt32(commands.count))
    bytes += le(UInt32(0)) + le(UInt32(0)) + commands
    let end = segments.map { $0.offset + $0.size }.max() ?? 0
    bytes += [UInt8](repeating: 0, count: Int(end) - bytes.count)
    return Data(bytes)
  }

  static let valid = [
    Segment(name: "__TEXT", offset: 0, size: 0x8000),
    Segment(name: "__PRELINK_TEXT", offset: 0x8000, size: 0x8000),
    Segment(name: "__TEXT_EXEC", offset: 0x10000, size: 0x430000),
    Segment(name: "__PRELINK_INFO", offset: 0x440000, size: 0x4000),
    Segment(name: "__DATA", offset: 0x444000, size: 0x4000),
    Segment(name: "__LINKEDIT", offset: 0x448000, size: 0x4000),
  ]

  static func rejects(_ data: Data, _ why: String) {
    do {
      try MachOBootObject.check(data)
      preconditionFailure("accepted: \(why)")
    } catch {}
  }

  static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
  }

  static func name16(_ name: String) -> [UInt8] {
    Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
  }

  /// One LC_SEGMENT_64 of aura's layout: file offset equals virtual offset.
  static func command(
    _ name: String, _ offset: UInt64, _ size: UInt64, section: (String, UInt64)? = nil
  ) -> [UInt8] {
    var bytes = le(UInt32(0x19)) + le(UInt32(72 + (section == nil ? 0 : 80))) + name16(name)
    bytes += le(base + offset) + le(size) + le(offset) + le(size)
    bytes += le(UInt32(1)) + le(UInt32(1)) + le(UInt32(section == nil ? 0 : 1)) + le(UInt32(0))
    if let section {
      bytes += name16(section.0) + name16(name) + le(base + offset) + le(section.1)
      bytes += le(UInt32(offset)) + [UInt8](repeating: 0, count: 28)
    }
    return bytes
  }

  /// The boot object aura's tools/macho_boot_object.py makes for `raw`.
  static func auraObject(
    raw: Data, extraCommand: [UInt8] = [], symbols: UInt32 = 0, fixup: UInt32 = 0
  ) -> Data {
    let size = UInt64(raw.count)
    let info: UInt64 = 0x10000 + size
    let data = info + 0x4000
    let linkedit = data + 0x4000
    var registers = [UInt64](repeating: 0, count: 34)
    registers[16] = base + 0x10000
    registers[32] = base + 0x10800
    var thread = le(UInt32(5)) + le(UInt32(16 + 34 * 8)) + le(UInt32(6)) + le(UInt32(0x44))
    for register in registers { thread += le(register) }
    let uuid = le(UInt32(0x1B)) + le(UInt32(24)) + [UInt8](repeating: 0x5A, count: 16)
    let build = le(UInt32(0x32)) + le(UInt32(24)) + [UInt8](repeating: 0, count: 16)
    let code = command("__TEXT_EXEC", 0x10000, size)
    let dataSegment = command("__DATA", data, 0x4000)
    let linkeditSegment = command("__LINKEDIT", linkedit, 0x4000)
    let member = Array("com.apple.kernel".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]
    let fileset =
      le(UInt32(0x8000_0035)) + le(UInt32(32 + member.count)) + le(base + 0x8000)
      + le(UInt64(0x8000)) + le(UInt32(32)) + le(UInt32(0)) + member
    let fixups = le(UInt32(0x8000_0034)) + le(UInt32(16)) + le(UInt32(linkedit)) + le(UInt32(56))
    func header(_ type: UInt32, _ commands: [[UInt8]]) -> [UInt8] {
      let payload = commands.flatMap { $0 }
      return le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0xC000_0002))
        + le(type) + le(UInt32(commands.count)) + le(UInt32(payload.count)) + le(UInt32(0))
        + le(UInt32(0)) + payload
    }
    let outer = header(
      12,
      [
        uuid, build, thread, fixups, command("__TEXT", 0, 0x8000),
        command("__PRELINK_TEXT", 0x8000, 0x8000, section: ("__text", 0x8000)), code,
        command("__PRELINK_INFO", info, 0x4000, section: ("__info", 0x20)), dataSegment,
        linkeditSegment, fileset,
      ] + (extraCommand.isEmpty ? [] : [extraCommand]))
    let primary = header(
      2,
      [
        command("__TEXT", 0x8000, 0x8000), code, dataSegment, linkeditSegment,
        le(UInt32(0x2)) + le(UInt32(24)) + le(symbols) + [UInt8](repeating: 0, count: 12),
        le(UInt32(0xB)) + le(UInt32(80)) + [UInt8](repeating: 0, count: 72), uuid, build, thread,
      ])
    var result = Data(count: Int(linkedit) + 0x4000)
    result.replaceSubrange(0..<outer.count, with: outer)
    result.replaceSubrange(0x8000..<(0x8000 + primary.count), with: primary)
    result.replaceSubrange(0x10000..<(0x10000 + raw.count), with: raw)
    let info0 = Int(info)
    result.replaceSubrange(info0..<(info0 + 4), with: [0xDE, 0xAD, 0xBE, 0xEF])
    // A valid fixup table naming no fixups: seven header words, then the starts.
    var table: [UInt8] = []
    for word: UInt32 in [0, 28, 56, 56, 0, 1, 0, 6, 0, 0, fixup, 0, 0, 0] { table += le(word) }
    result.replaceSubrange(Int(linkedit)..<(Int(linkedit) + table.count), with: table)
    return result
  }

  static func rawImage(footprint: UInt64 = 0x18000) -> Data {
    var raw = Data((0..<0x18000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 3) })
    let header =
      Array("AURALOAD".utf8) + le(UInt32(1)) + le(UInt32(1)) + le(footprint) + le(UInt64(0))
    raw.replaceSubrange(0x808..<(0x808 + header.count), with: header)
    return raw
  }

  static func segmentFields(_ data: Data, header: Int, name: String) -> (
    UInt64, UInt64, UInt64, UInt64
  )? {
    func u32(_ at: Int) -> UInt32 {
      data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    func u64(_ at: Int) -> UInt64 {
      data.subdata(in: at..<(at + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }
    var offset = header + 32
    for _ in 0..<Int(u32(header + 16)) {
      if u32(offset) == 0x19, data.subdata(in: (offset + 8)..<(offset + 24)) == Data(name16(name)) {
        return (u64(offset + 24), u64(offset + 32), u64(offset + 40), u64(offset + 48))
      }
      offset += Int(u32(offset + 4))
    }
    return nil
  }

  static func refusesExpansion(
    _ data: Data, window: UInt64 = 0x100000, slot: UInt64 = 0x20000, _ why: String
  ) {
    do {
      _ = try MachOBootObject.expandExecuteWindow(data, window: window, slot: slot)
      preconditionFailure("expanded: \(why)")
    } catch {}
  }

  static func checkExpansion() throws {
    let raw = rawImage()
    let original = auraObject(raw: raw)
    try MachOBootObject.check(original)
    let window: UInt64 = 0x100000
    let slot: UInt64 = 0x20000
    let expanded = try MachOBootObject.expandExecuteWindow(original, window: window, slot: slot)
    let codeSize = slot + ExecuteWindow.alignment - 0x4000 + window
    let growth = codeSize - 0x18000
    precondition(ExecuteWindow.codeSize(window: window, slot: slot) == codeSize)
    precondition(expanded.padding == growth)
    precondition(expanded.readOnlySize == 0x10000 + codeSize)
    precondition(expanded.size == UInt64(original.count) + growth)

    // The whole file, with its padding, is what kmutil and iBoot see.
    let file = expanded.head + Data(count: Int(expanded.padding)) + expanded.tail
    let (segments, entry) = try MachOBootObject.layout(file)
    try MachOBootObject.check(file)
    precondition(entry == base + 0x10800)
    let headLayout = try MachOBootObject.layout(expanded.head, fileSize: expanded.size)
    precondition(headLayout.entry == entry)
    // Code, and everything below it but the load commands, keep their bytes.
    precondition(file.subdata(in: 0x10000..<0x28000) == raw)
    precondition(file.suffix(0xC000) == original.suffix(0xC000))
    precondition(file.subdata(in: 0x28000..<(0x28000 + Int(growth))).allSatisfy { $0 == 0 })
    for (name, offset, size) in [
      ("__PRELINK_INFO", UInt64(0x28000), UInt64(0x4000)), ("__DATA", 0x2c000, 0x4000),
      ("__LINKEDIT", 0x30000, 0x4000),
    ] {
      let moved = segments[name]!
      precondition(moved.vmaddr == base + offset + growth && moved.fileoff == offset + growth)
      precondition(moved.vmsize == size && moved.filesize == size)
    }
    // The fileset member's copy of each moved segment agrees, as kmutil requires.
    for name in ["__TEXT_EXEC", "__DATA", "__LINKEDIT"] {
      let outer = segmentFields(file, header: 0, name: name)!
      let inner = segmentFields(file, header: 0x8000, name: name)!
      precondition(outer == inner, name)
    }
    precondition(segmentFields(file, header: 0, name: "__TEXT_EXEC")!.1 == codeSize)
    precondition(segmentFields(file, header: 0, name: "__TEXT_EXEC")!.3 == codeSize)
    precondition(segmentFields(file, header: 0x8000, name: "__TEXT")!.0 == base + 0x8000)
    // __info's section and the fixup table move with their segments.
    let bytes = [UInt8](file)
    func word(_ at: Int) -> UInt32 {
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
    var offset = 32
    var sawInfo = false
    var sawFixups = false
    for _ in 0..<Int(word(16)) {
      if word(offset) == 0x19,
        Data(bytes[(offset + 8)..<(offset + 24)]) == Data(name16("__PRELINK_INFO"))
      {
        let section = offset + 72
        precondition(word(section + 48) == UInt32(0x28000 + growth))
        let at = Int(word(section + 48))
        precondition(Array(bytes[at..<(at + 4)]) == [0xDE, 0xAD, 0xBE, 0xEF])
        sawInfo = true
      } else if word(offset) == 0x8000_0034 {
        precondition(word(offset + 8) == UInt32(0x30000 + growth))
        precondition(word(Int(word(offset + 8)) + 28) == 6)
        sawFixups = true
      }
      offset += Int(word(offset + 4))
    }
    precondition(sawInfo && sawFixups)

    // An aligned window fits past aura wherever iBoot loads the object.
    let full = ExecuteWindow.codeSize()
    for load in stride(from: UInt64(0x1_0000_4000), to: 0x1_0020_8000, by: 0x4000) {
      let free = load + 0x10000 + ExecuteWindow.auraSlot
      let start = (free + ExecuteWindow.alignment - 1) & ~(ExecuteWindow.alignment - 1)
      precondition(start + ExecuteWindow.size <= load + 0x10000 + full)
    }

    refusesExpansion(
      auraObject(raw: rawImage(footprint: slot + 1)), "aura needs more than its slot")
    refusesExpansion(auraObject(raw: Data(count: 0x18000)), "no aura load header")
    refusesExpansion(auraObject(raw: raw, fixup: 8), "a real chained fixup")
    refusesExpansion(auraObject(raw: raw, symbols: 0x40), "a symbol table")
    refusesExpansion(
      auraObject(raw: raw, extraCommand: le(UInt32(0x1D)) + le(UInt32(16)) + le(UInt64(0))),
      "LC_CODE_SIGNATURE, which it cannot move")
    refusesExpansion(original, window: 0x100, "a window of part of a page")
    refusesExpansion(file, "an object that is already expanded")
    refusesExpansion(object(valid), "not aura's object")
    // A crafted object is refused, never a trap on the arithmetic.
    func patched(_ name: String, field: Int, value: UInt64) -> Data {
      var data = original
      var offset = 0x8000 + 32
      while data.subdata(in: (offset + 8)..<(offset + 24)) != Data(name16(name)) {
        offset += Int(
          data.subdata(in: (offset + 4)..<(offset + 8))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      }
      data.replaceSubrange((offset + field)..<(offset + field + 8), with: le(value))
      return data
    }
    refusesExpansion(
      patched("__DATA", field: 24, value: UInt64.max - 0x100), "a virtual address that overflows")
    refusesExpansion(
      patched("__DATA", field: 40, value: UInt64.max - 0x100), "a file offset that overflows")
    refusesExpansion(
      original, window: UInt64.max - 0x3FFF, "a window that overflows the segment size")
    refusesExpansion(
      original, window: 0x4000, slot: UInt64.max - 0x3FFF, "a slot that overflows the segment size")
    var repeating: [UInt8] = le(UInt32(0x8000_0035))
    repeating += le(UInt32(32 + 24))
    repeating += le(base)
    repeating += le(UInt64(0))
    repeating += le(UInt32(32))
    repeating += le(UInt32(0))
    repeating += Array("com.apple.kernel".utf8)
    repeating += [0, 0, 0, 0, 0, 0, 0, 0]
    refusesExpansion(auraObject(raw: raw, extraCommand: repeating), "a member naming itself")

    // The default window is what reaches disk: a hole, not the whole window.
    let defaults = try MachOBootObject.expandExecuteWindow(original)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aura-execute-window-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stage1")
    try defaults.write(to: path)
    try defaults.write(to: path)  // A resumed setup replaces the earlier file.
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    precondition(names == ["stage1"])
    var info = stat()
    precondition(stat(path.path, &info) == 0)
    precondition(UInt64(info.st_size) == defaults.size && info.st_mode & 0o777 == 0o600)
    precondition(defaults.size > ExecuteWindow.size && UInt64(info.st_blocks) * 512 < 16 << 20)
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    let readHead = try handle.read(upToCount: defaults.head.count)
    precondition(readHead == defaults.head)
    let middle = UInt64(defaults.head.count) + defaults.padding / 2
    try handle.seek(toOffset: middle)
    let readHole = try handle.read(upToCount: 0x4000)
    precondition(readHole == Data(count: 0x4000))
    try handle.seek(toOffset: defaults.size - UInt64(defaults.tail.count))
    let readTail = try handle.read(upToCount: defaults.tail.count)
    precondition(readTail == defaults.tail)
    do {
      try defaults.write(to: directory.appendingPathComponent("missing/stage1"))
      preconditionFailure("wrote into a missing directory")
    } catch {}
  }

  /// Vectors from aura's tools/fill_stage1_config.py.
  static func checkConfiguration() throws {
    let uuid = "3ce364b1-1de6-4418-a00d-5b2d95884ad7"
    func block(_ path: String, crc: UInt32, magic: String = "AURORA-S1-CFG01\0") -> Data {
      let encoded = Array((";" + path).utf8)
      var bytes = Array(magic.utf8) + le(UInt32(1)) + le(UInt32(5000)) + Array(uuid.utf8)
      bytes += [UInt8](repeating: 0, count: 4) + encoded
      bytes += [UInt8](repeating: 0, count: 192 - encoded.count) + le(crc)
      return Data(bytes)
    }
    let code = Data(repeating: 0x5A, count: 0x40)
    let standard = code + block("m1n1/boot.bin", crc: 0x3C0C_2E4E) + code
    let confined = code + block("m1n1/boot-ctxr.bin", crc: 0x158D_6EE6) + code
    let read = try Stage1Configuration.read(standard)
    precondition(read.espUUID == uuid && read.stage2Path == "m1n1/boot.bin")
    let readConfined = try Stage1Configuration.read(confined)
    precondition(readConfined.stage2Path == "m1n1/boot-ctxr.bin")
    let moved = try Stage1Configuration.retargeted(
      standard, stage2Path: AuraStage1Format.confinedStage2Path)
    precondition(moved == confined, "a retargeted block must match aura's own fill")
    let back = try Stage1Configuration.retargeted(
      moved, stage2Path: AuraStage1Format.standardStage2Path)
    precondition(back == standard)
    func refused(_ image: Data, path: String = "m1n1/boot-ctxr.bin", _ why: String) {
      do {
        _ = try Stage1Configuration.retargeted(image, stage2Path: path)
        preconditionFailure("retargeted: \(why)")
      } catch {}
    }
    refused(code, "no block")
    refused(standard + standard, "two blocks")
    refused(code + block("m1n1/boot.bin", crc: 0), "a wrong checksum")
    var empty = code + block("m1n1/boot.bin", crc: 0x3C0C_2E4E)
    empty.removeLast(1)
    refused(empty, "a truncated block")
    for path in ["", "m1n1;boot.bin", "m1n1\\boot.bin", "é", String(repeating: "a", count: 191)] {
      refused(standard, path: path, "the path \(path)")
    }
  }

  static func checkSpace() throws {
    let expanded = try MachOBootObject.expandExecuteWindow(auraObject(raw: rawImage()))
    // The default window: aura's slot, its alignment slack, the window and the object around them.
    precondition(ExecuteWindow.size == 128 << 20 && expanded.size > 146 << 20)
    precondition(expanded.size < 147 << 20)
    try expanded.requireSpace(freeBytes: expanded.size)
    do {
      try expanded.requireSpace(freeBytes: expanded.size - 1)
      preconditionFailure("a sparse object is counted at its whole decompressed size")
    } catch {
      precondition(error.localizedDescription.contains("147 MiB"), error.localizedDescription)
    }
  }

  static func main() throws {
    try MachOBootObject.check(object(valid))
    try checkExpansion()
    try checkConfiguration()
    try checkSpace()

    var boot = valid
    boot.insert(Segment(name: "__TEXT_BOOT_EXEC", offset: 0x440000, size: 0x4000), at: 3)
    boot[4].offset = 0x444000
    boot[5].offset = 0x448000
    boot[6].offset = 0x44c000
    rejects(object(boot), "a nonempty __TEXT_BOOT_EXEC starts SPTM")
    var empty = valid
    empty.insert(Segment(name: "__TEXT_BOOT_EXEC", offset: 0x440000, size: 0), at: 3)
    try MachOBootObject.check(object(empty))

    rejects(object(valid, filetype: 2), "not a fileset")
    rejects(object(valid.filter { $0.name != "__PRELINK_INFO" }), "kmutil requires __PRELINK_INFO")
    rejects(object(valid, entry: 0x8000), "entry outside __TEXT_EXEC")
    var moved = valid
    moved[2].fileOffset = 0x14000
    rejects(object(moved), "file offset differs from virtual offset")
    rejects(object(valid).prefix(0x20000), "segments past the end of the file")
    rejects(Data(count: 0x10000), "raw image")

    // Output of `kmutil inspect --show-mach-boot-properties` on macOS 26.6.2 (25G83).
    let inspection = """
      Mach-O boot properties derived for boot kernel collection:
      {
          kclo : 18446741874803752960
          kcep : 18446741874803820544
          kcrf : 0
          kcrz : 4456448
          kcsf : 0
          kcsz : 0
          kcxf : 0
          kcxz : 0
          kcbf : 0
          kcbz : 0
          kcwf : 4456448
          kcwz : 32768
          kclf : 4489216
          kclz : 16384
      }
      """
    precondition(MachOBootObject.bootExecSize(fromInspection: inspection) == 0)
    precondition(
      MachOBootObject.bootExecSize(
        fromInspection: inspection.replacingOccurrences(
          of: "kcbz : 0", with: "kcbz : 32768")) == 32768)
    precondition(MachOBootObject.bootExecSize(fromInspection: "no properties") == nil)
    let used = try MachOBootObject.checkInspection(inspection, readOnlySize: 4_456_448)
    precondition(used == "kcrz 4456448")
    func inspectionRefused(_ output: String, _ why: String) {
      do {
        _ = try MachOBootObject.checkInspection(output, readOnlySize: 4_456_448)
        preconditionFailure("accepted inspection: \(why)")
      } catch {}
    }
    inspectionRefused("no properties", "nothing reported")
    inspectionRefused(
      inspection.replacingOccurrences(of: "kcbz : 0", with: "kcbz : 32768"), "SPTM would start")
    inspectionRefused(
      inspection.replacingOccurrences(of: "kcrz : 4456448", with: "kcrz : 4472832"),
      "a different read-only region")
    // kcrz decides even when kcwf agrees. Without it, only an exact kcwf passes.
    let noRegion = inspection.replacingOccurrences(of: "    kcrz : 4456448\n", with: "")
    let fallback = try MachOBootObject.checkInspection(noRegion, readOnlySize: 4_456_448)
    precondition(fallback == "kcwf 4456448, no kcrz")
    inspectionRefused(
      noRegion.replacingOccurrences(of: "kcwf : 4456448", with: "kcwf : 4472832"),
      "no kcrz and a different kcwf")
    inspectionRefused(
      noRegion.replacingOccurrences(of: "    kcwf : 4456448\n", with: ""), "neither property")

    // The installer fills the Stage 1 that the boot object carries in place.
    let raw = Data((0..<0x18000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
    var carrier = object(valid)
    carrier.replaceSubrange(0x10000..<(0x10000 + raw.count), with: raw)
    var filled = raw
    filled.replaceSubrange(0x9000..<0x9010, with: Data(repeating: 0xAB, count: 16))
    let result = try MachOBootObject.fill(carrier, raw: raw, filled: filled)
    precondition(result.count == carrier.count)
    precondition(result.subdata(in: 0x10000..<(0x10000 + raw.count)) == filled)
    precondition(result.prefix(0x10000) == carrier.prefix(0x10000))
    precondition(
      result.suffix(from: 0x10000 + raw.count) == carrier.suffix(from: 0x10000 + raw.count))
    func refusesFill(_ object: Data, raw: Data, filled: Data, _ why: String) {
      do {
        _ = try MachOBootObject.fill(object, raw: raw, filled: filled)
        preconditionFailure("filled: \(why)")
      } catch {}
    }
    var other = raw
    other[0x100] ^= 0xFF
    refusesFill(carrier, raw: other, filled: filled, "another Stage 1")
    refusesFill(carrier, raw: raw, filled: filled.prefix(raw.count - 1), "a different length")
    var trailing = carrier
    trailing[0x10000 + raw.count + 8] = 1
    refusesFill(trailing, raw: raw, filled: filled, "data after the Stage 1")
    refusesFill(object(valid, entry: 0x10000), raw: raw, filled: filled, "not its entry point")
    refusesFill(carrier, raw: Data(count: 0x430001), filled: Data(count: 0x430001), "too large")

    // M4 and later use the Mach-O Stage 1; every M1 to M3 chip keeps raw.
    for chip: UInt64 in [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050, 0x6051, 0x6052, 0x8150] {
      precondition(AuraStage1Format.usesExecuteWindow(chipID: chip), String(chip, radix: 16))
    }
    for chip: UInt64 in [
      0x8103, 0x6000, 0x6001, 0x6002, 0x8112, 0x6020, 0x6021, 0x6022, 0x8122, 0x6030, 0x6031,
      0x6032, 0x6034, 0, 0x8000, 0x7000, 0x9000,
    ] {
      precondition(!AuraStage1Format.usesExecuteWindow(chipID: chip), String(chip, radix: 16))
    }
    print(
      "PASS Mach-O boot object: no __TEXT_BOOT_EXEC, kmutil's required segments, linear file backing, entry in __TEXT_EXEC; kcbz and kcrz from kmutil inspect; in-place Stage 1 fill; Stage 2 path retargeted as aura fills it; execute-window padding keeps code, stays sparse and counts its whole size for free space; M4-and-later chip predicate"
    )
  }
}
