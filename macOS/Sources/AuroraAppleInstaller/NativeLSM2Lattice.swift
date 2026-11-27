// SPDX-License-Identifier: MIT

#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// The lsm2 masker's bucket lattice, read from the AudioDSP component of
  /// the pinned restore image the speaker tuning comes from.
  ///
  /// The lsm2 speaker protection unit reduces a 640-point spectrum to 100
  /// buckets. The bucket edges are a table inside macOS's AudioDSP
  /// component, not something a formula reproduces, so the installer reads
  /// it from that image's component (`SpeakerTuningRestoreImages`), never
  /// from the running macOS, and never ships it.
  ///
  /// The table is found by its structure alone, with no offset, hash or
  /// symbol: in every Mach-O slice of the component, at naturally aligned
  /// addresses of the `__TEXT,__const` section, 100 little-endian 64-bit
  /// exclusive bucket ends that start with the 64 single-bin buckets (ends 1
  /// to 64), increase strictly, stay within 1 to 321 (the one-sided
  /// 640-point spectrum) and end at 321. Exactly one such table must exist in
  /// each slice and every slice must hold the same bytes. Anything else is an
  /// error: there is no fallback table. The Python collector
  /// (`asahi_firmware/lsm2_lattice.py`) applies the same rule.
  enum NativeLSM2Lattice {
    /// The component, relative to the root of the image's System volume
    /// (and of the extracted tree).
    static let componentPath = SpeakerTuningSource.componentPath
    /// About 17 MB on macOS 26 and 27.
    static let maximumComponentBytes = 256 << 20
    static let entries = 100
    static let singletons = 64
    static let finalEnd: UInt64 = 640 / 2 + 1
    static let size = entries * 8
    /// The bundle field: `entries` little-endian u64 exclusive bucket ends.
    static let version = 1
    static let format = "u64le-exclusive-ends"
    static let bundleName = "lsm2-mask-lattice.bin"

    enum Failure: Error, Equatable, CustomStringConvertible {
      case malformed(String)
      case candidates(slice: Int, found: Int)
      case slicesDisagree

      var description: String {
        switch self {
        case .malformed(let what): "malformed AudioDSP component: \(what)"
        case .candidates(let slice, let found):
          "slice \(slice): expected one lsm2 masker lattice in __TEXT,__const, found \(found)"
        case .slicesDisagree: "the AudioDSP slices hold different lsm2 masker lattices"
        }
      }
    }

    /// Whether `table` is a lattice, by the rule above.
    static func valid(_ table: Data) -> Bool {
      guard table.count == size else { return false }
      let ends = (0..<entries).map { word(table, $0 * 8) }
      for index in 0..<singletons where ends[index] != UInt64(index + 1) { return false }
      for index in 1..<entries where ends[index] <= ends[index - 1] { return false }
      return ends.allSatisfy { $0 >= 1 && $0 <= finalEnd } && ends[entries - 1] == finalEnd
    }

    /// The lattice of a component image, or `Failure`.
    static func extract(_ data: Data) throws -> Data {
      let bytes = [UInt8](data)
      var tables = [Data]()
      for (index, slice) in try slices(bytes).enumerated() {
        let view = Array(bytes[slice.offset..<(slice.offset + slice.size)])
        let found = try candidates(view)
        guard found.count == 1 else {
          throw Failure.candidates(slice: index, found: found.count)
        }
        tables.append(Data(view[found[0]..<(found[0] + size)]))
      }
      guard tables.allSatisfy({ $0 == tables[0] }) else { throw Failure.slicesDisagree }
      return tables[0]
    }

    // MARK: Mach-O

    struct Slice: Equatable {
      let offset: Int
      let size: Int
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt64 {
      data.withUnsafeBytes { raw in
        (0..<8).reduce(UInt64(0)) {
          $0 | UInt64(raw[raw.startIndex + offset + $1]) << (8 * UInt64($1))
        }
      }
    }

    private static func read(_ bytes: [UInt8], _ offset: Int, _ count: Int, big: Bool) throws
      -> UInt64
    {
      guard offset >= 0, count <= bytes.count, offset <= bytes.count - count else {
        throw Failure.malformed("a field lies outside the file")
      }
      var value: UInt64 = 0
      for index in 0..<count {
        let byte = UInt64(bytes[offset + (big ? index : count - 1 - index)])
        value = value << 8 | byte
      }
      return value
    }

    private static func within(_ total: Int, _ offset: UInt64, _ size: UInt64, _ what: String)
      throws
    {
      guard offset <= UInt64(total), size <= UInt64(total) - offset else {
        throw Failure.malformed("\(what) lies outside the file")
      }
    }

    /// Each architecture slice; one for a thin file.
    static func slices(_ bytes: [UInt8]) throws -> [Slice] {
      guard bytes.count >= 8 else { throw Failure.malformed("too short") }
      let magic = try read(bytes, 0, 4, big: true)
      let fat: (big: Bool, wide: Bool)? =
        switch magic {
        case 0xCAFE_BABE: (true, false)
        case 0xBEBA_FECA: (false, false)
        case 0xCAFE_BABF: (true, true)
        case 0xBFBA_FECA: (false, true)
        default: nil
        }
      guard let fat else { return [Slice(offset: 0, size: bytes.count)] }
      let count = Int(try read(bytes, 4, 4, big: fat.big))
      guard count > 0, count <= 64 else { throw Failure.malformed("slice count \(count)") }
      let step = fat.wide ? 32 : 20
      try within(bytes.count, 8, UInt64(count * step), "the slice table")
      var out = [Slice]()
      for index in 0..<count {
        let base = 8 + index * step
        let offset = try read(bytes, base + 8, fat.wide ? 8 : 4, big: fat.big)
        let size = try read(bytes, base + (fat.wide ? 16 : 12), fat.wide ? 8 : 4, big: fat.big)
        try within(bytes.count, offset, size, "slice \(index)")
        let slice = Slice(offset: Int(offset), size: Int(size))
        guard
          !out.contains(where: {
            slice.offset < $0.offset + $0.size && $0.offset < slice.offset + slice.size
          })
        else { throw Failure.malformed("overlapping slices") }
        out.append(slice)
      }
      return out
    }

    /// File offset, size and address of the one `__TEXT,__const` section of
    /// a 64-bit Mach-O slice.
    static func constSection(_ view: [UInt8]) throws -> (offset: Int, size: Int, address: UInt64) {
      guard view.count >= 32 else { throw Failure.malformed("short Mach-O header") }
      let magic = try read(view, 0, 4, big: true)
      let big: Bool
      switch magic {
      case 0xCFFA_EDFE: big = false
      case 0xFEED_FACF: big = true
      default: throw Failure.malformed("a slice is not a 64-bit Mach-O image")
      }
      let commands = Int(try read(view, 16, 4, big: big))
      let commandBytes = try read(view, 20, 4, big: big)
      guard commands <= 65_536 else { throw Failure.malformed("load command count") }
      try within(view.count, 32, commandBytes, "the load commands")
      var position = 32
      let end = 32 + Int(commandBytes)
      var found = [(offset: Int, size: Int, address: UInt64)]()
      func name(_ at: Int) -> [UInt8] { Array(view[at..<(at + 16)].prefix { $0 != 0 }) }
      for _ in 0..<commands {
        guard position + 8 <= end else { throw Failure.malformed("a load command") }
        let command = try read(view, position, 4, big: big)
        let size = Int(try read(view, position + 4, 4, big: big))
        guard size >= 8, size <= end - position else {
          throw Failure.malformed("a load command has an invalid size")
        }
        if command == 0x19 {
          guard size >= 72 else { throw Failure.malformed("a short segment command") }
          let sections = Int(try read(view, position + 64, 4, big: big))
          guard 72 + sections * 80 <= size else {
            throw Failure.malformed("sections overrun their segment command")
          }
          for index in 0..<sections {
            let base = position + 72 + index * 80
            guard name(base) == Array("__const".utf8), name(base + 16) == Array("__TEXT".utf8)
            else { continue }
            let address = try read(view, base + 32, 8, big: big)
            let length = try read(view, base + 40, 8, big: big)
            let offset = try read(view, base + 48, 4, big: big)
            let flags = try read(view, base + 64, 4, big: big)
            guard ![0x1, 0xC, 0x12].contains(flags & 0xFF) else {
              throw Failure.malformed("__TEXT,__const has no file contents")
            }
            try within(view.count, offset, length, "__TEXT,__const")
            found.append((Int(offset), Int(length), address))
          }
        }
        position += size
      }
      guard position == end else {
        throw Failure.malformed("the load commands do not fill their declared size")
      }
      guard found.count == 1 else {
        throw Failure.malformed("expected one __TEXT,__const section, found \(found.count)")
      }
      return found[0]
    }

    /// Offsets in a slice of every valid lattice at a naturally aligned
    /// address of its `__TEXT,__const`.
    static func candidates(_ view: [UInt8]) throws -> [Int] {
      let section = try constSection(view)
      let stop = section.offset + section.size
      var out = [Int]()
      guard section.size >= size else { return out }
      // Start at the first naturally aligned address of the section.
      var at = section.offset + Int((8 - section.address % 8) % 8)
      while at + size <= stop {
        // The first end is 1 and the second 2: a cheap filter before the rule.
        if view[at] == 1, view[at + 8] == 2,
          valid(Data(view[at..<(at + size)]))
        {
          out.append(at)
        }
        at += 8
      }
      return out
    }
  }
#endif
