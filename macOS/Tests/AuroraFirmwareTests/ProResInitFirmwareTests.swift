import Foundation
import XCTest

@testable import AuroraFirmware

/// Synthetic AppleProResHW-shaped images, built from scratch: made-up rows,
/// made-up addresses and a few hand-assembled instructions. Nothing here
/// comes from macOS.
final class ProResInitFirmwareTests: XCTestCase {
  struct Table {
    var family: String
    var number: Int
    var rows: [(offset: UInt32, mask: UInt32, value: UInt32)]
    var underscore = true
  }

  struct Selector {
    var family: String
    var number: Int
    var soc: UInt32 = 0x6041
    var table: Int  // index into the image's tables
  }

  static let base: UInt64 = 0xFFFF_FE00_0700_0000
  static let textAddress = base + 0x4000
  static let constAddress = base + 0x8000

  static func rows(_ count: Int, seed: UInt32) -> [(offset: UInt32, mask: UInt32, value: UInt32)] {
    (0..<UInt32(count)).map {
      ($0 * 4 + 0x100, 0xFF << ($0 % 4 * 8), ((seed + $0) % 0xFF) << ($0 % 4 * 8))
    }
  }

  static func standard(seed: UInt32 = 1) -> [Table] {
    [
      Table(family: "scodec_sys", number: 3, rows: rows(82, seed: seed)),
      Table(family: "prores", number: 5, rows: rows(80, seed: seed + 7), underscore: false),
      Table(family: "af_scodecaxi2af", number: 9, rows: rows(62, seed: seed + 13)),
    ]
  }

  static let standardSelectors = [
    Selector(family: "scodec_sys", number: 3, table: 0),
    Selector(family: "prores", number: 5, table: 1),
    Selector(family: "af_scodecaxi2af", number: 9, table: 2),
  ]

  private static func put32(_ data: inout Data, _ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private static func put64(_ data: inout Data, _ value: UInt64) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private static func name16(_ text: String) -> Data {
    Data(text.utf8) + Data(count: 16 - text.utf8.count)
  }

  /// A thin kext image whose file offsets start at `origin`.
  static func image(
    _ tables: [Table], _ selectors: [Selector], origin: Int = 0, fileType: UInt32 = 0xB
  ) -> Data {
    // __text: one selector function per entry: MOVZ, ADRP + ADD, RET.
    var text = Data()
    var symbols = [(name: String, section: UInt8, value: UInt64)]()
    var tableAddresses = [UInt64]()
    var constData = Data()
    for table in tables {
      tableAddresses.append(constAddress + UInt64(constData.count))
      constData.append(Data(count: (table.rows.count + 1) * 8))
    }
    var figs = [(address: UInt64, row: (offset: UInt32, mask: UInt32, value: UInt32))]()
    var slots = Data()
    var gaps: UInt64 = 1
    for table in tables {
      var tableSlots = Data()
      for row in table.rows {
        // Pseudo-random gaps, so no shifted window of fig entries decodes.
        gaps = gaps &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        constData.append(Data(count: 8 * Int(gaps >> 61)))
        let address = constAddress + UInt64(constData.count)
        constData.append(Data(count: 8))
        figs.append((address, row))
        put64(&tableSlots, address - base)
      }
      put64(&tableSlots, 0)  // the end: no fig entry at the collection base
      slots.append(tableSlots)
    }
    constData.replaceSubrange(0..<slots.count, with: slots)
    for (index, table) in tables.enumerated() {
      symbols.append(
        (
          (table.underscore ? "_" : "") + "tunableh_\(table.family)_figs_\(table.number).figs", 2,
          tableAddresses[index]
        ))
    }
    for fig in figs {
      let name = String(
        format: "_fig_%x_32_%x_%x_null", fig.row.offset, fig.row.mask, fig.row.value)
      symbols.append((name, 2, fig.address))
    }
    for selector in selectors {
      let pc = textAddress + UInt64(text.count)
      symbols.append(("_tunableh_\(selector.family)_figs_\(selector.number)_apply_to", 1, pc))
      let target = tableAddresses[selector.table]
      let pages = Int64(bitPattern: (target & ~0xFFF) &- ((pc + 4) & ~0xFFF)) >> 12
      let adrp = 0x9000_0008 | UInt32(pages & 3) << 29 | UInt32((pages >> 2) & 0x7FFFF) << 5
      put32(&text, 0x5280_0000 | (selector.soc & 0xFFFF) << 5)
      put32(&text, adrp)
      put32(&text, 0x9100_0108 | UInt32(target & 0xFFF) << 10)
      put32(&text, 0xD65F_03C0)
    }
    if text.isEmpty { put32(&text, 0xD65F_03C0) }

    // Strings and nlist entries.
    var strings = Data([0])
    var nlist = Data()
    for symbol in symbols {
      put32(&nlist, UInt32(strings.count))
      nlist.append(contentsOf: [0x0E, symbol.section, 0, 0])
      put64(&nlist, symbol.value)
      strings.append(Data(symbol.name.utf8) + Data([0]))
    }
    let textOffset = origin + 0x1000
    let constOffset = origin + 0x2000
    let symbolOffset = constOffset + ((constData.count + 0xFFF) & ~0xFFF)
    let stringOffset = symbolOffset + nlist.count

    func segment(_ name: String, _ section: String, _ address: UInt64, _ bytes: Data, _ offset: Int)
      -> Data
    {
      var command = Data()
      put32(&command, 0x19)
      put32(&command, 72 + 80)
      command.append(name16(name))
      put64(&command, address)
      put64(&command, UInt64(bytes.count))
      put64(&command, UInt64(offset))
      put64(&command, UInt64(bytes.count))
      put32(&command, 5)
      put32(&command, 5)
      put32(&command, 1)
      put32(&command, 0)
      command.append(name16(section))
      command.append(name16(name))
      put64(&command, address)
      put64(&command, UInt64(bytes.count))
      put32(&command, UInt32(offset))
      command.append(Data(count: 28))
      return command
    }
    var commands =
      segment("__TEXT_EXEC", "__text", textAddress, text, textOffset)
      + segment("__DATA_CONST", "__const", constAddress, constData, constOffset)
    put32(&commands, 2)
    put32(&commands, 24)
    put32(&commands, UInt32(symbolOffset))
    put32(&commands, UInt32(symbols.count))
    put32(&commands, UInt32(stringOffset))
    put32(&commands, UInt32(strings.count))

    var out = Data()
    for value: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, fileType, 3, UInt32(commands.count), 0, 0] {
      put32(&out, value)
    }
    out.append(commands)
    out.append(Data(count: 0x1000 - out.count))
    out.append(text)
    out.append(Data(count: 0x1000 - text.count))
    out.append(constData)
    out.append(Data(count: symbolOffset - origin - out.count))
    out.append(nlist)
    out.append(strings)
    return out
  }

  /// A kernel collection holding `entry` as `name`, at file offset 0x4000.
  static func collection(_ entry: Data, name: String = "com.apple.driver.AppleProResHW") -> Data {
    var command = Data()
    let identifier = Data(name.utf8) + Data([0])
    let size = (32 + identifier.count + 7) & ~7
    put32(&command, 0x8000_0035)
    put32(&command, UInt32(size))
    put64(&command, base)
    put64(&command, 0x4000)
    put32(&command, 32)
    put32(&command, 0)
    command.append(identifier)
    command.append(Data(count: size - command.count))
    var out = Data()
    for value: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, 0xC, 1, UInt32(command.count), 0, 0] {
      put32(&out, value)
    }
    out.append(command)
    out.append(Data(count: 0x4000 - out.count))
    out.append(entry)
    return out
  }

  static func expected(_ tables: [Table]) -> Data {
    var out = Data("APRI".utf8)
    for value: UInt32 in [1, 0x6041, 3] { put32(&out, value) }
    for (index, table) in tables.enumerated() {
      put32(&out, UInt32(index + 1))
      put32(&out, UInt32(table.rows.count))
      for row in table.rows {
        put32(&out, row.offset)
        put32(&out, row.mask)
        put32(&out, row.value)
      }
    }
    return out
  }

  func testThinImage() throws {
    let tables = Self.standard()
    let rows = try ProResInitFirmware.extract(from: Self.image(tables, Self.standardSelectors))
    XCTAssertEqual(rows, Self.expected(tables))
    XCTAssertEqual(rows?.count, 2728)
  }

  func testKernelCollectionEntry() throws {
    let tables = Self.standard(seed: 40)
    let entry = Self.image(tables, Self.standardSelectors, origin: 0x4000)
    let rows = try ProResInitFirmware.extract(from: Self.collection(entry.dropFirst(0)))
    XCTAssertEqual(rows, Self.expected(tables))
  }

  func testCollectionWithoutTheKext() throws {
    let entry = Self.image(Self.standard(), Self.standardSelectors, origin: 0x4000)
    XCTAssertNil(
      try ProResInitFirmware.extract(from: Self.collection(entry, name: "com.apple.driver.Other")))
  }

  func testNoT6041Selector() throws {
    let selectors = Self.standardSelectors.map {
      var other = $0
      other.soc = 0x8140
      return other
    }
    XCTAssertNil(try ProResInitFirmware.extract(from: Self.image(Self.standard(), selectors)))
  }

  func testOtherSelectorsAreIgnored() throws {
    // A second table per family, selected only for another SoC.
    let tables =
      Self.standard()
      + Self.standard(seed: 90).map {
        var other = $0
        other.number += 20
        return other
      }
    let selectors =
      Self.standardSelectors
      + (0..<3).map {
        Selector(family: tables[$0 + 3].family, number: 30, soc: 0x8112, table: $0 + 3)
      }
    let rows = try ProResInitFirmware.extract(from: Self.image(tables, selectors))
    XCTAssertEqual(rows, Self.expected(Array(tables.prefix(3))))
  }

  func testDamagedTable() {
    var tables = Self.standard()
    tables[1].rows[10].value = ~tables[1].rows[10].mask  // outside its mask
    XCTAssertThrowsError(
      try ProResInitFirmware.extract(from: Self.image(tables, Self.standardSelectors))
    ) {
      XCTAssertEqual(
        $0 as? ProResInitFirmware.Failure, .candidates(block: "ProRes core", found: 0))
    }
  }

  func testWrongCount() {
    var tables = Self.standard()
    tables[2].rows.removeLast()
    XCTAssertThrowsError(
      try ProResInitFirmware.extract(from: Self.image(tables, Self.standardSelectors))
    ) {
      XCTAssertEqual(
        $0 as? ProResInitFirmware.Failure, .candidates(block: "SCODEC wrapper", found: 0))
    }
  }

  func testDuplicateOffset() {
    var tables = Self.standard()
    tables[0].rows[5].offset = tables[0].rows[4].offset
    XCTAssertThrowsError(
      try ProResInitFirmware.extract(from: Self.image(tables, Self.standardSelectors)))
  }

  func testTwoT6041Tables() {
    var tables = Self.standard()
    tables.append(Table(family: "prores", number: 6, rows: Self.rows(80, seed: 77)))
    let selectors = Self.standardSelectors + [Selector(family: "prores", number: 6, table: 3)]
    XCTAssertThrowsError(try ProResInitFirmware.extract(from: Self.image(tables, selectors))) {
      XCTAssertEqual(
        $0 as? ProResInitFirmware.Failure, .candidates(block: "ProRes core", found: 2))
    }
  }

  func testMissingFamily() {
    let selectors = Array(Self.standardSelectors.prefix(2))
    XCTAssertThrowsError(
      try ProResInitFirmware.extract(from: Self.image(Self.standard(), selectors)))
  }

  func testTruncatedInput() {
    let image = Self.image(Self.standard(), Self.standardSelectors)
    XCTAssertThrowsError(try ProResInitFirmware.extract(from: image.prefix(0x1800)))
    XCTAssertThrowsError(try ProResInitFirmware.extract(from: Data([1, 2, 3])))
  }

  func testFailuresCarryNoRowData() {
    var tables = Self.standard()
    tables[0].rows[0].value = 0x1234_5678
    do {
      _ = try ProResInitFirmware.extract(from: Self.image(tables, Self.standardSelectors))
      XCTFail("damaged table accepted")
    } catch {
      XCTAssertFalse(String(describing: error).contains("12345678"))
    }
  }

  func testMachines() {
    XCTAssertTrue(ProResInitFirmware.machines.contains("j616s"))
    XCTAssertFalse(ProResInitFirmware.machines.contains("j413"))
  }
}
