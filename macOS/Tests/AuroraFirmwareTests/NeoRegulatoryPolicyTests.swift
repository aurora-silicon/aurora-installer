// SPDX-License-Identifier: MIT
import Foundation
import XCTest

@testable import AuroraFirmware

final class NeoRegulatoryPolicyTests: XCTestCase {
  func testInventoryRejectsChangedUnpinnedOutputAndMissingPinnedCountry() throws {
    var outputs = ["world.bin": Data("baseline".utf8), "DE.bin": Data("power values".utf8)]
    let pins = ["world.bin": outputs["world.bin"]!.sha256]
    let expected = NeoRegulatoryPolicy.inventoryDigest(outputs)
    try NeoRegulatoryPolicy.verifyOutputs(outputs, pins: pins, inventory: expected)
    let reversed = Dictionary(uniqueKeysWithValues: outputs.sorted { $0.key > $1.key })
    XCTAssertEqual(NeoRegulatoryPolicy.inventoryDigest(reversed), expected)
    outputs["DE.bin"] = Data("changed power values".utf8)
    XCTAssertThrowsError(
      try NeoRegulatoryPolicy.verifyOutputs(outputs, pins: pins, inventory: expected))
    outputs.removeValue(forKey: "world.bin")
    let missingPinInventory = NeoRegulatoryPolicy.inventoryDigest(outputs)
    XCTAssertThrowsError(
      try NeoRegulatoryPolicy.verifyOutputs(outputs, pins: pins, inventory: missingPinInventory))
  }
  private struct Fixture: Decodable {
    let inputs: [String: String]
    let outputs: [String: String]
  }
  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "regulatory-synthetic", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  func testEveryJoinedCountryMatchesTheIndependentReference() throws {
    let fixture = try fixture()
    let inputs = fixture.inputs.mapValues { Data($0.utf8) }
    let result = try NeoRegulatoryPolicy.derive(inputs, authenticated: false)
    XCTAssertEqual(result.mapValues(\.sha256), fixture.outputs)
    XCTAssertEqual(result.count, 5)
    XCTAssertTrue(result.keys.contains("mediatek/mt7932/policy/CA.bin"))
    XCTAssertFalse(result.keys.contains("mediatek/mt7932/policy/MH.bin"))
    for (name, bytes) in result {
      let country =
        name.hasSuffix("world-XZ.bin") ? "XZ" : String(name.split(separator: "/").last!.prefix(2))
      XCTAssertEqual(try NeoFirmwareConversions.policy(bytes, country: country), bytes)
    }
    // A valid synthetic schema never satisfies production authentication.
    XCTAssertThrowsError(try NeoRegulatoryPolicy.derive(inputs))
    XCTAssertThrowsError(try NeoRegulatoryPolicy.derive([:]))
  }
  func testGrammarChangesAndIncompleteBaselineFailBeforeOutput() throws {
    let fixture = try fixture()
    let cases: [(String, (String) -> String)] = [
      (
        "IZUBA_TxPwrLimit_MT79x1.dat", { $0.replacingOccurrences(of: "<Ver:03>", with: "<Ver:04>") }
      ),
      ("IZUBA_TxPwrLimit_MT79x1.dat", { $0.replacingOccurrences(of: "c1, c2", with: "c2, c1") }),
      ("IZUBA_TxPwrLimit_MT79x1.dat", { $0 + "\0" }),
      ("IZUBA_TxPwrLimit_MT79x1.dat", { $0 + "é" }),
      (
        "IZUBA_TxPwrLimit_SDB.dat",
        { $0.replacingOccurrences(of: "subband1,0", with: "subband1,Y") }
      ),
      ("IZUBA_TxPwrLimit_SDB.dat", { $0.replacingOccurrences(of: "</sdb>", with: "") }),
      (
        "IZUBA_TxPwrLimit_SDB.dat", { $0.replacingOccurrences(of: "subband1,", with: "subband+1,") }
      ),
      (
        "IZUBA_TxPwrLimit_2gCommonPath.dat",
        { $0.replacingOccurrences(of: "ch001,", with: "ch+01,") }
      ),
      ("IZUBA_db.dat", { $0.replacingOccurrences(of: ",\r\n", with: "\r\n") }),
      ("IZUBA_TxPwrLimit_2gCommonPath.dat", { $0.replacingOccurrences(of: "[US]", with: "[XX]") }),
    ]
    for (name, mutate) in cases {
      var inputs = fixture.inputs.mapValues { Data($0.utf8) }
      let changed = mutate(fixture.inputs[name]!)
      XCTAssertNotEqual(changed, fixture.inputs[name], name)
      inputs[name] = Data(changed.utf8)
      XCTAssertThrowsError(try NeoRegulatoryPolicy.derive(inputs, authenticated: false), name)
    }
  }
  func testByteStoresAndOctalPrefixParsing() {
    XCTAssertEqual(NeoRegulatoryPolicy.cell("-1"), 255)
    XCTAssertEqual(NeoRegulatoryPolicy.cell("Y"), 127)
    XCTAssertEqual(NeoRegulatoryPolicy.cell("X"), 196)
    XCTAssertEqual(NeoRegulatoryPolicy.cell("x", power: false), 127)
    for (token, value) in [
      ("3/1/2", 2), ("08", 0), ("+1tail", 1), ("-377", 1), ("  40000000001", 1),
    ] {
      XCTAssertEqual(Int(NeoRegulatoryPolicy.octal(token)), value, token)
    }
  }
  func testBondedRowsAreStoresRatherThanChannelRanges() throws {
    let rows = try NeoRegulatoryPolicy.powerRows([
      (1, "ch038", Array(repeating: "9", count: 8)),
      (2, "ch038", Array(repeating: "1", count: 24)),
      (1, "ch036-040", Array(repeating: "2", count: 8)),
      (1, "ch038-042", Array(repeating: "3", count: 8)),
      (1, "ch038-046", Array(repeating: "4", count: 8)),
    ])
    XCTAssertEqual(Array(rows[15][72..<80]), Array(repeating: 1, count: 8))  // channel 38
    XCTAssertEqual(Array(rows[14][36..<44]), Array(repeating: 2, count: 8))  // channel 36
    XCTAssertEqual(Array(rows[16][36..<44]), Array(repeating: 196, count: 8))  // channel 40
    XCTAssertEqual(Array(rows[17][72..<80]), Array(repeating: 3, count: 8))  // channel 42
    XCTAssertEqual(Array(rows[19][80..<88]), Array(repeating: 4, count: 8))  // channel 46
    for label in ["ch+38", "ch038-cdd-cdd", "ch038-+42", "ch038-042-other"] {
      XCTAssertThrowsError(
        try NeoRegulatoryPolicy.powerRows([(1, label, Array(repeating: "1", count: 8))]), label)
    }
  }
  func testBitmapKeepsHighBitsAndParsedGroupOffsets() throws {
    var rows = Array(repeating: Array(repeating: UInt8(0), count: 540), count: 67)
    rows[0][8 * 36] = 196
    var bytes = Data(NeoRegulatoryPolicy.bitmap(rows))
    XCTAssertEqual(try bytes.little(4, 4), 0x3000_0000)
    rows[0][8 * 36] = 127  // Stop pass one before isolating the second-pass bit.
    rows[0][11 * 36 + 12] = 196
    bytes = Data(NeoRegulatoryPolicy.bitmap(rows))
    XCTAssertEqual(try bytes.little(4, 4), 0x8000_2000)
  }
}
