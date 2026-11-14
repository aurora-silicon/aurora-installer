// SPDX-License-Identifier: MIT
import Foundation

/// The T6041 ProRes engine's power-up rows, read from this Mac's own kernel.
///
/// The Linux driver (`apple,t6041-prores`) programs three blocks of
/// read-modify-write rows every time the engine powers up: SCODEC-system,
/// ProRes core and the SCODEC AXI-to-fabric wrapper. They live in macOS's
/// AppleProResHW kext, so the installer rebuilds them from the restore
/// kernel cache it already reads for this Mac, stores them in the vendor
/// firmware package as `apple/prores-t6041-init.bin` and never ships them.
///
/// The tables are found through the kext's own symbols, with no address,
/// offset, hash or value compiled in:
///
/// 1. In the `com.apple.driver.AppleProResHW` fileset entry (or a thin kext
///    image), each block family has `tunableh_<family>_figs_<n>.figs` tables
///    and `tunableh_<family>_figs_<n>_apply_to` selectors. The selector for
///    this engine is the one that materialises the SoC number 0x6041 (MOVZ)
///    and takes the address of a table of its family (ADRP + ADD).
/// 2. A table is a run of 32-bit pointers, relative to the kernel
///    collection, to `fig` entries whose symbol names carry the register
///    offset, width, mask, value and getter. The collection base is inferred
///    by matching the whole run against those symbols.
/// 3. Each block must decode to exactly one table of exactly the count the
///    driver expects, ending where the count ends, with 32-bit entries, a
///    null getter, aligned and unique offsets inside the block's window,
///    nonzero masks and values inside their masks.
///
/// A kernel without the kext or without a T6041 selector yields nothing.
/// One with a selector but missing, damaged or duplicate tables is an error,
/// with no fallback table. Errors never carry offsets, masks or values.
public enum ProResInitFirmware {
  /// The vendor firmware path the driver requests.
  public static let name = "apple/prores-t6041-init.bin"
  /// The M4 Pro and M4 Max Macs: their engine is the one these rows set up.
  /// Kernel caches for other Macs carry the T6041 tables too, so the
  /// installer collects them for these machines only.
  public static let machines: Set<String> = ["j614s", "j616s", "j773s", "j614c", "j616c", "j575c"]
  static let filesetEntry = "com.apple.driver.AppleProResHW"
  static let soc: UInt32 = 0x6041
  static let maximumFunctionBytes = 0x4000

  struct Block {
    let identifier: UInt32
    let label: String
    let family: String
    let count: Int
    let offsetLimit: UInt64
  }

  /// The APRI v1 blocks, in the order the driver applies them.
  static let blocks = [
    Block(
      identifier: 1, label: "SCODEC-system", family: "scodec_sys", count: 82, offsetLimit: 0x4000),
    Block(identifier: 2, label: "ProRes core", family: "prores", count: 80, offsetLimit: 0x4000),
    Block(
      identifier: 3, label: "SCODEC wrapper", family: "af_scodecaxi2af", count: 62,
      offsetLimit: 0x100_0000),
  ]

  public enum Failure: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case candidates(block: String, found: Int)

    public var description: String {
      switch self {
      case .malformed(let what): "malformed AppleProResHW image: \(what)"
      case .candidates(let block, let found):
        "\(block): expected one T6041 table, found \(found)"
      }
    }
  }

  struct Row: Hashable {
    let offset: UInt32
    let mask: UInt32
    let value: UInt32
  }

  /// The APRI container for `kernel` (an unwrapped kernel collection or a
  /// thin AppleProResHW image), or nil when it has no T6041 ProRes engine.
  public static func extract(from kernel: Data) throws -> Data? {
    let bytes = [UInt8](kernel)
    guard let image = try appleProResHW(bytes) else { return nil }
    let figs = image.figs()
    var selected = [[Row]]()
    var selectors = 0
    for block in blocks {
      let (found, tables) = try candidates(image, block, figs)
      selectors += found
      selected.append(contentsOf: tables.prefix(1))
      if found > 0 && tables.count != 1 {
        throw Failure.candidates(block: block.label, found: tables.count)
      }
    }
    if selectors == 0 { return nil }
    guard selected.count == blocks.count else {
      let missing = blocks.count - selected.count
      throw Failure.malformed("\(missing) T6041 block(s) without a selector")
    }
    return container(selected)
  }

  static func container(_ tables: [[Row]]) -> Data {
    var out = Data("APRI".utf8)
    func put(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
    put(1)
    put(soc)
    put(UInt32(blocks.count))
    for (block, rows) in zip(blocks, tables) {
      put(block.identifier)
      put(UInt32(rows.count))
      for row in rows {
        put(row.offset)
        put(row.mask)
        put(row.value)
      }
    }
    return out
  }

  // MARK: - Mach-O

  struct Section {
    let index: Int
    let address: UInt64
    let size: UInt64
    let offset: Int
  }

  struct Symbol {
    let name: String
    let value: UInt64
    let section: Int
  }

  struct Image {
    let bytes: [UInt8]
    var filetype: UInt32 = 0
    var sections = [Section]()
    var symbols = [Symbol]()
    var filesetEntries = [(name: String, offset: Int)]()

    init(_ bytes: [UInt8], header: Int = 0, bias: Int = 0) throws {
      self.bytes = bytes
      guard try u32(bytes, header) == 0xFEED_FACF else {
        throw Failure.malformed("not a little-endian 64-bit Mach-O")
      }
      filetype = try u32(bytes, header + 12)
      let ncmds = try u32(bytes, header + 16)
      let commandsEnd = header + 32 + Int(try u32(bytes, header + 20))
      guard commandsEnd <= bytes.count else { throw Failure.malformed("truncated load commands") }
      var command = header + 32
      var symtab: (Int, Int, Int, Int)?
      for _ in 0..<ncmds {
        guard command + 8 <= commandsEnd else { throw Failure.malformed("truncated load command") }
        let cmd = try u32(bytes, command)
        let size = Int(try u32(bytes, command + 4))
        guard size >= 8, command + size <= commandsEnd else {
          throw Failure.malformed("invalid load command size")
        }
        switch cmd {
        case 0x19:  // LC_SEGMENT_64
          guard size >= 72 else { throw Failure.malformed("short segment command") }
          let count = Int(try u32(bytes, command + 64))
          guard 72 + count * 80 <= size else { throw Failure.malformed("short section table") }
          for number in 0..<count {
            let entry = command + 72 + number * 80
            sections.append(
              Section(
                index: sections.count + 1, address: try u64(bytes, entry + 32),
                size: try u64(bytes, entry + 40), offset: bias + Int(try u32(bytes, entry + 48))))
          }
        case 0x2:  // LC_SYMTAB
          guard size >= 24 else { throw Failure.malformed("short symbol table command") }
          symtab = (
            Int(try u32(bytes, command + 8)), Int(try u32(bytes, command + 12)),
            Int(try u32(bytes, command + 16)), Int(try u32(bytes, command + 20))
          )
        case 0x8000_0035:  // LC_FILESET_ENTRY
          guard size >= 32 else { throw Failure.malformed("short fileset entry") }
          let offset = try u64(bytes, command + 16)
          guard offset < UInt64(bytes.count) else {
            throw Failure.malformed("fileset entry outside input")
          }
          let name = try string(
            bytes, command + Int(try u32(bytes, command + 24)), end: command + size)
          filesetEntries.append((name, Int(offset)))
        default: break
        }
        command += size
      }
      if let (symoff, nsyms, stroff, strsize) = symtab {
        let symbolsStart = bias + symoff
        let stringsStart = bias + stroff
        let stringsEnd = stringsStart + strsize
        guard symbolsStart >= 0, nsyms <= (bytes.count - symbolsStart) / 16 else {
          throw Failure.malformed("symbol table outside the input")
        }
        guard stringsStart >= 0, stringsEnd <= bytes.count else {
          throw Failure.malformed("string table outside the input")
        }
        for index in 0..<nsyms {
          let entry = symbolsStart + index * 16
          let strx = Int(try u32(bytes, entry))
          // Skip debugger (stab) entries and unnamed symbols.
          if strx == 0 || strx >= strsize || bytes[entry + 4] & 0xE0 != 0 { continue }
          symbols.append(
            Symbol(
              name: try string(bytes, stringsStart + strx, end: stringsEnd),
              value: try u64(bytes, entry + 8), section: Int(bytes[entry + 5])))
        }
      }
    }

    /// The file offset of `size` bytes at `address`, inside one section.
    func fileOffset(_ address: UInt64, _ size: Int) -> Int? {
      for section in sections
      where section.address <= address && address - section.address <= section.size
        && UInt64(size) <= section.size - (address - section.address)
      {
        let offset = section.offset + Int(address - section.address)
        return offset >= 0 && offset <= bytes.count - size ? offset : nil
      }
      return nil
    }

    /// Where the function at `symbol` ends: the next symbol in its section.
    func end(of symbol: Symbol) -> UInt64? {
      let later = symbols.lazy.filter { $0.section == symbol.section && $0.value > symbol.value }
        .map(\.value).min()
      if let later { return later }
      return sections.first { $0.index == symbol.section }.map { $0.address + $0.size }
    }

    /// The `fig` entries by address: register offset, mask, value, getter.
    func figs() -> [UInt64: (offset: UInt64, mask: UInt64, value: UInt64, getter: Substring)] {
      var result = [UInt64: (offset: UInt64, mask: UInt64, value: UInt64, getter: Substring)]()
      var ambiguous = Set<UInt64>()
      for symbol in symbols {
        guard let fig = ProResInitFirmware.fig(symbol.name) else { continue }
        if let existing = result[symbol.value],
          existing.offset != fig.offset || existing.mask != fig.mask
            || existing.value != fig.value || existing.getter != fig.getter
        {
          ambiguous.insert(symbol.value)
        } else {
          result[symbol.value] = fig
        }
      }
      for address in ambiguous { result[address] = nil }
      return result
    }
  }

  /// `[_]fig_<offset hex>_<width>_<mask hex>_<value hex>_<getter>`.
  static func fig(_ name: String) -> (
    offset: UInt64, mask: UInt64, value: UInt64, getter: Substring
  )? {
    var rest = Substring(name)
    if rest.hasPrefix("_") { rest = rest.dropFirst() }
    guard rest.hasPrefix("fig_") else { return nil }
    let fields = rest.dropFirst(4).split(
      separator: "_", maxSplits: 4, omittingEmptySubsequences: false)
    guard fields.count == 5, fields[1].allSatisfy(\.isASCII), UInt64(fields[1]) != nil,
      let offset = UInt64(fields[0], radix: 16), let mask = UInt64(fields[2], radix: 16),
      let value = UInt64(fields[3], radix: 16), !fields[4].isEmpty,
      fields[0].allSatisfy(\.isHexDigit), fields[2].allSatisfy(\.isHexDigit),
      fields[3].allSatisfy(\.isHexDigit),
      fields[4].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else { return nil }
    return (offset, mask, value, fields[4])
  }

  /// `[_]tunableh_<family>_figs_<n><suffix>`.
  static func matches(_ name: String, family: String, suffix: String) -> Bool {
    var rest = Substring(name)
    if rest.hasPrefix("_") { rest = rest.dropFirst() }
    let prefix = "tunableh_" + family + "_figs_"
    guard rest.hasPrefix(prefix), rest.hasSuffix(suffix) else { return false }
    let number = rest.dropFirst(prefix.count).dropLast(suffix.count)
    return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
  }

  static func appleProResHW(_ bytes: [UInt8]) throws -> Image? {
    let root = try Image(bytes)
    let entries = root.filesetEntries.filter { $0.name == filesetEntry }.map(\.offset)
    if root.filetype != 0xC && entries.isEmpty {
      // A thin image: only AppleProResHW itself has the ProRes selectors.
      return root.symbols.contains { matches($0.name, family: "prores", suffix: "_apply_to") }
        ? root : nil
    }
    guard !entries.isEmpty else { return nil }
    guard entries.count == 1 else {
      throw Failure.malformed("\(entries.count) AppleProResHW entries")
    }
    // Fileset entries keep either collection-wide or entry-relative offsets.
    let choices = [0, entries[0]].compactMap { bias -> Image? in
      guard let image = try? Image(bytes, header: entries[0], bias: bias),
        image.symbols.contains(where: { matches($0.name, family: "prores", suffix: ".figs") })
      else { return nil }
      return image
    }
    guard choices.count == 1 else { throw Failure.malformed("unresolved AppleProResHW entry") }
    return choices[0]
  }

  // MARK: - Selectors and tables

  /// Whether `code` holds a MOVZ of `immediate` (32- or 64-bit, any shift).
  static func movz(_ code: ArraySlice<UInt8>, _ immediate: UInt32) -> Bool {
    stride(from: code.startIndex, to: code.endIndex - 3, by: 4).contains { position in
      let instruction = word(code, position)
      guard instruction & 0x7F80_0000 == 0x5280_0000 else { return false }
      let shift = (instruction >> 21) & 3
      return UInt64((instruction >> 5) & 0xFFFF) << (shift * 16) == UInt64(immediate)
    }
  }

  /// The addresses that ADRP + ADD (immediate) pairs on one register form.
  static func references(_ code: ArraySlice<UInt8>, at address: UInt64) -> Set<UInt64> {
    var result = Set<UInt64>()
    for position in stride(from: code.startIndex, to: code.endIndex - 7, by: 4) {
      let first = word(code, position)
      let second = word(code, position + 4)
      guard first & 0x9F00_0000 == 0x9000_0000, second & 0x7F00_0000 == 0x1100_0000,
        (second >> 5) & 0x1F == first & 0x1F
      else { continue }
      let high: UInt32 = (first >> 5) & 0x7FFFF
      let low: UInt32 = (first >> 29) & 3
      let raw = Int64(high << 2 | low)
      let pages = (raw ^ 0x10_0000) - 0x10_0000
      let pc = address &+ UInt64(position - code.startIndex)
      var immediate = UInt64((second >> 10) & 0xFFF)
      if second & (1 << 22) != 0 { immediate <<= 12 }
      result.insert((pc & ~0xFFF) &+ UInt64(bitPattern: pages << 12) &+ immediate)
    }
    return result
  }

  static func decode(
    _ image: Image, table: Symbol, _ block: Block,
    _ figs: [UInt64: (offset: UInt64, mask: UInt64, value: UInt64, getter: Substring)]
  ) -> [Row]? {
    guard let start = image.fileOffset(table.value, (block.count + 1) * 8) else { return nil }
    // Collection-relative pointers: the low 32 bits of each 64-bit slot.
    let pointers = (0...block.count).map { UInt64(word(image.bytes[...], start + $0 * 8)) }
    var decoded = Set<[Row]>()
    for address in figs.keys {
      let base = address &- pointers[0]
      guard figs[base &+ pointers[block.count]] == nil else { continue }
      var rows = [Row]()
      var offsets = Set<UInt64>()
      for pointer in pointers.prefix(block.count) {
        guard let fig = figs[base &+ pointer], fig.getter == "null", fig.offset & 3 == 0,
          fig.offset < block.offsetLimit, fig.mask != 0, fig.mask <= 0xFFFF_FFFF,
          fig.value & ~fig.mask == 0, offsets.insert(fig.offset).inserted
        else { break }
        rows.append(
          Row(offset: UInt32(fig.offset), mask: UInt32(fig.mask), value: UInt32(fig.value)))
      }
      if rows.count == block.count { decoded.insert(rows) }
    }
    return decoded.count == 1 ? decoded.first : nil
  }

  /// How many T6041 selectors the family has, and the distinct tables they
  /// select that decode cleanly.
  static func candidates(
    _ image: Image, _ block: Block,
    _ figs: [UInt64: (offset: UInt64, mask: UInt64, value: UInt64, getter: Substring)]
  ) throws -> (selectors: Int, tables: [[Row]]) {
    var tables = [UInt64: Symbol]()
    for symbol in image.symbols where matches(symbol.name, family: block.family, suffix: ".figs") {
      tables[symbol.value] = symbol
    }
    var selectors = 0
    var found = [UInt64: [Row]]()
    for function in image.symbols
    where matches(function.name, family: block.family, suffix: "_apply_to") {
      guard let end = image.end(of: function), end > function.value,
        end - function.value <= UInt64(maximumFunctionBytes),
        let start = image.fileOffset(function.value, Int(end - function.value))
      else { continue }
      let code = image.bytes[start..<(start + Int(end - function.value))]
      guard movz(code, soc) else { continue }
      selectors += 1
      for address in references(code, at: function.value) {
        guard let table = tables[address], found[address] == nil,
          let rows = decode(image, table: table, block, figs)
        else { continue }
        found[address] = rows
      }
    }
    return (selectors, Array(found.values))
  }
}

private func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
  guard offset >= 0, offset <= bytes.count - 4 else {
    throw ProResInitFirmware.Failure.malformed("truncated structure")
  }
  return word(bytes[...], offset)
}

private func u64(_ bytes: [UInt8], _ offset: Int) throws -> UInt64 {
  UInt64(try u32(bytes, offset)) | UInt64(try u32(bytes, offset + 4)) << 32
}

private func word(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
  UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    | UInt32(bytes[offset + 3]) << 24
}

private func string(_ bytes: [UInt8], _ offset: Int, end: Int) throws -> String {
  guard offset >= 0, offset < end, end <= bytes.count,
    let stop = bytes[offset..<end].firstIndex(of: 0),
    let text = String(validating: bytes[offset..<stop], as: UTF8.self)
  else { throw ProResInitFirmware.Failure.malformed("invalid string") }
  return text
}
