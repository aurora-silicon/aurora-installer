// SPDX-License-Identifier: MIT
// Ported from Chris Kearney's MIT MT7932 policy extractor.
// See PROVENANCE.md for the reference implementation and licence.
import Foundation

/// Derives country policies in process from the authenticated model-wide tables.
public enum NeoRegulatoryPolicy {
  public static let inputSHA256: [String: String] = [
    "IZUBA_TxPwrLimit_MT79x1.dat":
      "03ee51df5231d131c1976f1d2ea7f81a1396988e63a132a318a9893e8ef5ec38",
    "IZUBA_TxPwrLimit_SAR.dat": "d8dc9dfff2ad2d1ddf301d892e60c93f476603992f71de9e742194a395ca850d",
    "IZUBA_TxPwrLimit_2gCommonPath.dat":
      "43185e334cb074b9c89b71aa6440d5d22cc45e9d8dc1fdc66c8a4933f2376b6c",
    "IZUBA_db.dat": "a61e0b70cbc9a381fc41ff9afa8f036cbd032cadad66209134d4a5adfa18c8b2",
    "IZUBA_TxPwrLimit_SDB.dat": "042906f4b23f05d82f211549b22f195a57d3437b137009fda0a0e40935abbfd0",
  ]
  private static let versions: [String: String] = [
    "IZUBA_TxPwrLimit_MT79x1.dat": "{Ver:Izuba_WLAN_Final_dedicated_v8 Date:2025-12-18 06:17:25}",
    "IZUBA_TxPwrLimit_SAR.dat":
      "{Ver:J700_Izuba_WLAN_EVT_SAR_Cap_Input_v3.00 Date:2025-10-30 03:06:21}",
    "IZUBA_TxPwrLimit_2gCommonPath.dat":
      "{Ver:Izuba_WLAN_Final_PT_common_path_v1 Date:2025-10-30 02:30:10}",
    "IZUBA_db.dat":
      "{Ver:2026 Spring_WiFi Channel Matrix_2.4GHz_5GHz_6GHz_Snrs_V2.0 Date:2025-12-11 11:03:09}",
    "IZUBA_TxPwrLimit_SDB.dat": "{Ver:Izuba_SDB_WLAN_P2_PT_v1 Date:2025-08-09 05:19:31}",
  ]
  private static let formats: [String: String] = [
    "IZUBA_TxPwrLimit_MT79x1.dat": "<Ver:03>", "IZUBA_TxPwrLimit_SAR.dat": "<Ver:01>",
  ]
  private static let outputSHA256: [String: String] = [
    "mediatek/mt7932/policy/world-XZ.bin":
      "cbc887013ca6cc31ea1a326cba485a2c89c70ad6d3f85bbf4bbda65f60ebb97b",
    "mediatek/mt7932/policy/US.bin":
      "9e519590d4a66972cfd7909132f3567c7b47a5252f89d345c1e7083a7d5bb9fe",
    "mediatek/mt7932/policy/CA.bin":
      "cf6f05261985ae48efa4c2802d645c26e6fb13d7eed3a5a64888ef372497f0da",
  ]
  // SHA-256 of sorted ASCII path<TAB>blob-sha256<LF> records for all 244 policies.
  static let outputInventorySHA256 =
    "37419c03c0ba222d60eb78fdbdf9fed9ef1d005ef76a8bae0255d4a978defd5d"
  private static let groups: [String] = [
    "cck", "ofdm", "ht20", "ht40", "vht20", "vht40", "vht80", "vht160", "ru26", "ru52", "ru106",
    "ru242", "ru484", "ru996", "ru996X2",
  ]
  private static let columns: [String: [String]] = [
    "cck": ["c1", "c2", "c5", "c11"],
    "ofdm": ["o6", "o9", "o12", "o18", "o24", "o36", "o48", "o54"],
    "ht20": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "c_m0", "c_m1", "c_m2",
      "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5",
      "m_m6", "m_m7",
    ],
    "ht40": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "c_m0", "c_m1", "c_m2",
      "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5",
      "m_m6", "m_m7",
    ],
    "vht20": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "c_m0",
      "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9", "m_m0", "m_m1",
      "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8", "m_m9",
    ],
    "vht40": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "c_m0",
      "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9", "m_m0", "m_m1",
      "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8", "m_m9",
    ],
    "vht80": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "c_m0",
      "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9", "m_m0", "m_m1",
      "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8", "m_m9",
    ],
    "vht160": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "c_m0",
      "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9", "m_m0", "m_m1",
      "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8", "m_m9",
    ],
    "ru26": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru52": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru106": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru242": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru484": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru996": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
    "ru996X2": [
      "s_m0", "s_m1", "s_m2", "s_m3", "s_m4", "s_m5", "s_m6", "s_m7", "s_m8", "s_m9", "s_m10",
      "s_m11", "c_m0", "c_m1", "c_m2", "c_m3", "c_m4", "c_m5", "c_m6", "c_m7", "c_m8", "c_m9",
      "c_m10", "c_m11", "m_m0", "m_m1", "m_m2", "m_m3", "m_m4", "m_m5", "m_m6", "m_m7", "m_m8",
      "m_m9", "m_m10", "m_m11",
    ],
  ]
  private static let sarColumns: [String] = ["siso_wf0", "siso_wf1", "mimo_wf0", "mimo_wf1"]
  private static let sdbColumns: [String] = [
    "cck_siso_wf0", "cck_siso_wf1", "ofdm_siso_wf0", "ofdm_siso_wf1", "ofdma_siso_wf0",
    "ofdma_siso_wf1", "cck_mimo_wf0", "cck_mimo_wf1", "ofdm_mimo_wf0", "ofdm_mimo_wf1",
    "ofdma_mimo_wf0", "ofdma_mimo_wf1",
  ]
  private static let channels2: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  private static let channels5: [Int] = [
    36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 100, 102, 104, 106, 108, 110, 112,
    114, 116, 118, 120, 122, 124, 126, 128, 132, 134, 136, 138, 140, 142, 144, 149, 151, 153, 155,
    157, 159, 161, 163, 165, 167, 169, 171, 173, 175, 177, 181,
  ]
  private static let descriptors: [[Int]] = [
    [0, 0, 4], [4, 1, 8], [13, 1, 8], [37, 1, 8], [60, 2, 10], [90, 2, 10], [120, 2, 10],
    [150, 2, 10], [180, 2, 12], [216, 2, 12], [252, 2, 12], [288, 2, 12], [324, 2, 12],
    [360, 2, 12], [396, 2, 12],
  ]
  private static let centerRows: [[Int]] = [
    [1, 0, 0, 0], [2, 0, 0, 0], [3, 0, 0, 0], [4, 0, 0, 0], [5, 0, 0, 0], [6, 0, 0, 0],
    [7, 0, 0, 0], [8, 0, 0, 0], [9, 0, 0, 0], [10, 0, 0, 0], [11, 0, 0, 0], [12, 0, 0, 0],
    [13, 0, 0, 0], [14, 0, 0, 0], [36, 38, 42, 50], [40, 38, 42, 50], [44, 46, 42, 50],
    [48, 46, 42, 50], [52, 54, 58, 50], [56, 54, 58, 50], [60, 62, 58, 50], [64, 62, 58, 50],
    [100, 102, 106, 114], [104, 102, 106, 114], [108, 110, 106, 114], [112, 110, 106, 114],
    [116, 118, 122, 114], [120, 118, 122, 114], [124, 126, 122, 114], [128, 126, 122, 114],
    [132, 134, 138, 0], [136, 134, 138, 0], [140, 142, 138, 0], [144, 142, 138, 0],
    [149, 151, 155, 163], [153, 151, 155, 163], [157, 159, 155, 163], [161, 159, 155, 163],
    [165, 167, 171, 163], [169, 167, 171, 163], [173, 175, 171, 163], [177, 175, 171, 163],
    [181, 0, 0, 0],
  ]
  private static let rejectedCountries: Set<String> = [
    "00", "MH", "X0", "X2", "X3", "A1", "A3", "A6", "AQ", "CU", "IR", "KP",
  ]

  private struct Row {
    let label: String
    let cells: [String]
  }
  private struct Group {
    let name: String
    var rows: [Row]
  }
  private typealias Sections = [String: [Group]]
  private static func check(_ value: Bool) throws {
    try require(value, "Invalid regulatory table schema.")
  }
  private static func fields(_ text: String) -> [String] {
    text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }
  private static func integer(_ text: String) -> Bool {
    let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
    return !body.isEmpty && body.utf8.allSatisfy { (48...57).contains($0) }
  }
  private static func lines(_ data: Data, name: String) throws -> [String] {
    try check(data.count <= 32 << 20 && !data.contains(0))
    guard let text = String(data: data, encoding: .ascii) else {
      throw RestoreFailure("Regulatory input must be ASCII.")
    }
    var result = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    try check(result.first == versions[name])
    result.removeFirst()
    let format = result.first?.hasPrefix("<Ver:") == true ? result.removeFirst() : nil
    try check(format == formats[name])
    return result
  }
  private static func sections(
    _ data: Data, name: String, expected: [String: [String]]?, allowY: Bool
  ) throws -> Sections {
    var result = Sections()
    var section: String?
    var active: String?
    var width = 0
    for line in try lines(data, name: name) {
      if line.hasPrefix("[") && line.hasSuffix("]") {
        let key = String(line.dropFirst().dropLast())
        try check(active == nil && !key.isEmpty && !key.contains(",") && result[key] == nil)
        section = key
        result[key] = []
        continue
      }
      if line.hasPrefix("</") && line.hasSuffix(">") {
        try check(active != nil && String(line.dropFirst(2).dropLast()) == active)
        active = nil
        continue
      }
      if line.hasPrefix("<") && line.hasSuffix(">") {
        guard let section else { throw RestoreFailure("Missing regulatory section.") }
        let row = fields(String(line.dropFirst().dropLast()))
        try check(active == nil && row.allSatisfy { !$0.isEmpty })
        let key = row[0]
        let names = Array(row.dropFirst())
        try check(!(result[section] ?? []).contains { $0.name == key })
        if let expected {
          try check(expected[key] == names)
        } else {
          try check(key == "common_path_backoff" && names.count == 1)
        }
        active = key
        width = names.count
        result[section]!.append(Group(name: key, rows: []))
        continue
      }
      guard let section, active != nil else { throw RestoreFailure("Unscoped regulatory row.") }
      let row = fields(line)
      try check(row.count == width + 1 && !row[0].isEmpty)
      try check(row.dropFirst().allSatisfy { (allowY && $0 == "Y") || integer($0) })
      let index = result[section]!.count - 1
      result[section]![index].rows.append(Row(label: row[0], cells: Array(row.dropFirst())))
    }
    try check(active == nil && !result.isEmpty)
    let required = Set(expected?.keys.map { $0 } ?? ["common_path_backoff"])
    for value in result.values { try check(Set(value.map(\.name)) == required) }
    return result
  }
  private static func database(_ data: Data) throws -> [Group] {
    var result = [Group]()
    var active: Int?
    var width = 0
    for line in try lines(data, name: "IZUBA_db.dat") {
      if line.hasPrefix("</") && line.hasSuffix(">") {
        let closer = String(line.dropFirst(2).dropLast())
        guard let current = active else { throw RestoreFailure("Unexpected regulatory group end.") }
        try check(closer == "end" || closer == result[current].name)
        active = nil
        continue
      }
      if line.hasPrefix("<") && line.hasSuffix(">") {
        let row = fields(String(line.dropFirst().dropLast()))
        try check(
          active == nil && ["2gCC", "6gCC"].contains(row[0]) && row.allSatisfy { !$0.isEmpty })
        try check(!result.contains { $0.name == row[0] })
        width = row[0] == "2gCC" ? 76 : 116
        try check(row.count == width + 1)
        active = result.count
        result.append(Group(name: row[0], rows: []))
        continue
      }
      guard let active else { throw RestoreFailure("Unscoped regulatory database row.") }
      let row = fields(line)
      try check(
        row.count == width + 2 && row.last == "" && row.dropLast().allSatisfy { !$0.isEmpty })
      try check(!result[active].rows.contains { $0.label == row[0] })
      result[active].rows.append(Row(label: row[0], cells: Array(row.dropFirst().dropLast())))
    }
    try check(active == nil && Set(result.map(\.name)) == ["2gCC", "6gCC"])
    return result
  }
  private static func subband(_ label: String, count: Int) throws -> Int {
    guard label.hasPrefix("subband"), !label.dropFirst(7).isEmpty,
      label.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) }),
      let number = Int(label.dropFirst(7)),
      (1...count).contains(number)
    else {
      throw RestoreFailure("Invalid regulatory subband.")
    }
    return number - 1
  }
  private static func simultaneous(_ data: Data) throws -> [[String]] {
    let input = try lines(data, name: "IZUBA_TxPwrLimit_SDB.dat")
    try check(input.first?.hasPrefix("<") == true && input.first?.hasSuffix(">") == true)
    try check(fields(String(input[0].dropFirst().dropLast())) == ["sdb"] + sdbColumns)
    var result = Array(repeating: Array(repeating: "x", count: 12), count: 17)
    var closed = false
    for line in input.dropFirst() {
      try check(!closed)
      if line == "</sdb>" {
        closed = true
        continue
      }
      let row = fields(line)
      try check(
        row.count == 13 && row.dropFirst().allSatisfy { ["X", "x"].contains($0) || integer($0) })
      result[try subband(row[0], count: 17)] = Array(row.dropFirst())
    }
    try check(closed)
    return result
  }

  // Numeric cells are byte stores; long signed decimal strings wrap modulo 256.
  static func cell(_ text: String, power: Bool = true) -> UInt8 {
    if text == "Y" { return power ? 127 : 0 }
    if ["X", "x"].contains(text) { return power ? 196 : 127 }
    var value: UInt8 = 0
    for c in text.utf8 where (48...57).contains(c) { value = value &* 10 &+ (c - 48) }
    return text.hasPrefix("-") ? 0 &- value : value
  }
  static func octal(_ token: String) -> UInt8 {
    let piece = String(token.components(separatedBy: "/").last ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    var digits = Array(piece.utf8)
    let negative = digits.first == 45
    if digits.first == 43 || negative { digits.removeFirst() }
    var value: UInt32 = 0
    for byte in digits {
      if !(48...55).contains(byte) { break }
      value = value &* 8 &+ UInt32(byte - 48)
    }
    return UInt8(truncatingIfNeeded: negative ? 0 &- value : value)
  }
  static func bandwidth(_ channel: Int) -> Int {
    if channel == 0 { return 255 }
    if channel < 15 { return 0 }
    let base = channel < 149 ? 36 : 149
    if channel < base { return 255 }
    let delta = channel - base
    if delta & 3 == 0 { return 0 }
    if delta & 7 == 2 { return 1 }
    if delta & 15 == 6 { return 2 }
    if delta & 31 == 14 { return 3 }
    return 255
  }
  private static func centerWidth(_ channel: Int) -> Int {
    for row in centerRows {
      for i in 1...3 where row[i] == channel { return i }
    }
    return 255
  }
  private static func center(_ width: Int, _ channel: Int) -> Int {
    let base = channel < 149 ? 36 : 149
    if channel < base { return 0 }
    let delta = channel - base
    if width == 1 { return (delta & 7 == 0 ? channel + 2 : channel - 2) & 255 }
    return (base + (delta & (width == 2 ? ~15 : ~31)) + (width == 2 ? 6 : 14)) & 255
  }
  // Each row holds fifteen padded 36-byte groups, in template channel order.
  static func powerRows(_ records: [(Int, String, [String])]) throws -> [[UInt8]] {
    let channels = channels2 + channels5
    var rows = Array(repeating: Array(repeating: UInt8(196), count: 540), count: channels.count)
    for (group, label, cells) in records {
      let parts = label.components(separatedBy: "-")
      try check(
        parts.count <= 3 && parts[0].hasPrefix("ch") && parts[0].count == 5
          && parts[0].dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }))
      guard let start = Int(parts[0].dropFirst(2)) else {
        throw RestoreFailure("Invalid regulatory channel.")
      }
      let bonded = parts.count > 1
      let cdd = parts.last == "cdd"
      try check(parts.count != 3 || (cdd && parts[1] != "cdd"))
      let end: Int
      if parts.count > 1 && parts[1] != "cdd" {
        try check(parts[1].count == 3 && parts[1].utf8.allSatisfy({ (48...57).contains($0) }))
        guard let value = Int(parts[1]) else { throw RestoreFailure("Invalid bonded channel.") }
        end = value
      } else {
        end = start
      }
      let bwStart = centerWidth(start)
      let bwEnd = centerWidth(end)
      var dest = group
      var offset = 0
      var channel = start
      if bonded && bwStart != 255 {
        channel = end
        if [4, 5, 6].contains(group) {
          dest = bwStart + 4
        } else if [11, 12, 13].contains(group) {
          dest = bwStart + 11
        } else if group == 1 {
          if bwStart == bwEnd {
            dest = 2
            offset = 8
          } else if bwStart == 2 && bwEnd == 1 {
            dest = cdd ? 3 : 2
            offset = cdd ? 0 : 16
          } else if bwStart == 3 && bwEnd == 1 {
            dest = 3
            offset = cdd ? 16 : 8
          } else if bwStart == 3 && bwEnd == 2 {
            dest = cdd ? 3 : 2
            offset = cdd ? 0 : 16
          } else {
            dest = 2
            offset = (bwStart - 1) * 8
          }
        }
      }
      guard let index = channels.firstIndex(of: channel) else { continue }
      try check(
        (0..<groups.count).contains(dest) && offset >= 0
          && offset + cells.count <= columns[groups[dest]]!.count)
      rows[index].replaceSubrange(
        dest * 36 + offset..<dest * 36 + offset + cells.count, with: cells.map { cell($0) })
      if !bonded && group == 1 && bwStart != 255 {
        try check(cells.count == 8)
        rows[index].replaceSubrange(72..<80, with: cells.map { cell($0) })
      }
    }
    return rows
  }
  private static func write(_ bytes: [UInt8], _ offset: Int, _ value: inout [UInt8]) {
    value.replaceSubrange(offset..<offset + bytes.count, with: bytes)
  }
  private static func little(_ number: Int, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
  }
  private static func padded(_ rows: [[UInt8]]) -> [UInt8] {
    var pad = Array(repeating: UInt8(0), count: 32)
    for (channel, row) in zip(channels2 + channels5, rows) {
      let bw = bandwidth(channel)
      if bw <= 3
        && (4...4 + bw).allSatisfy({
          Int(Int8(bitPattern: row[$0 * 36])) - Int(Int8(bitPattern: row[$0 * 36 + 10])) >= 10
        })
      {
        pad[channel >> 3] |= UInt8(1 << (channel & 7))
      }
    }
    return pad
  }
  private static let passRates = [1, 2, 3, 4, 11, 12, 13, 14]
  static func bitmap(_ rows: [[UInt8]]) -> [UInt8] {
    let channels = channels2 + channels5
    var words = Array(repeating: UInt32(0), count: 90)
    func find(_ channel: Int) -> [UInt8]? {
      channels.firstIndex(of: channel).flatMap { $0 < rows.count ? rows[$0] : nil }
    }
    for (index, row) in rows.prefix(67).enumerated() {
      let channel = channels[index]
      let bw = bandwidth(channel)
      if bw > 3 { continue }
      let slot = channel <= 14 ? channel : (channel >> 1) - 1
      var word = words[slot]
      passOne: for rate in 8..<bw + 12 {
        for group in 0..<3 {
          for column in 0..<12 {
            let byte = row[rate * 36 + group * 12 + column]
            if byte == 127 { break passOne }
            if byte == 196 {
              if rate == 8 {
                word |= 0x3000_0000
              } else if rate == bw + 10 && rate > 10 {
                word |= 0x5000_0000
              } else if (9...14).contains(rate) {
                word |= 0x1000_0000
              }
              break
            }
          }
        }
      }
      subchannels: for subIndex in 0..<(1 << bw) {
        let subChannel = (channel - [0, 2, 6, 14][bw] + 4 * subIndex) & 255
        guard let sub = find(subChannel) else { continue }
        var c40 = Array(repeating: UInt8(0), count: 540)
        var c80 = c40
        if bw >= 2 {
          guard let found = find(center(1, subChannel)) else { break }
          c40 = found
        }
        if bw == 3 {
          guard let found = find(center(2, subChannel)) else { break }
          c80 = found
        }
        var image = Array(repeating: UInt8(0), count: 540)
        func paint(
          _ rate: Int, _ offset: Int, _ source: [UInt8], _ src: Int, _ srcOffset: Int, _ count: Int
        ) {
          write(
            Array(source[src * 36 + srcOffset..<src * 36 + srcOffset + count]), rate * 36 + offset,
            &image)
        }
        func substitute(_ rate: Int, _ offset: Int, _ source: [UInt8], _ src: Int, _ srcOffset: Int)
        {
          if image[rate * 36 + offset] == 127 { paint(rate, offset, source, src, srcOffset, 8) }
        }
        if bw == 0 {
          paint(1, 0, row, 1, 0, 8)
          paint(1, 8, row, 4, 10, 8)
          paint(11, 0, row, 11, 0, 36)
        } else {
          paint(1, 0, sub, 2, 8 * (bw - 1), 8)
          paint(1, 8, sub, bw + 4, 10, 8)
          if bw == 1 {
            paint(2, 0, row, 2, 0, 16)
            substitute(2, 0, row, 5, 0)
            substitute(2, 8, row, 5, 10)
            paint(11, 0, row, 11, 0, 36)
            paint(12, 0, row, 12, 0, 36)
          } else {
            paint(11, 0, sub, bw + 11, 0, 36)
            if bw == 2 {
              paint(2, 0, c40, 2, 16, 8)
              paint(2, 8, c40, 3, 0, 8)
            } else {
              paint(2, 0, c40, 3, 8, 8)
              paint(2, 8, c40, 3, 16, 8)
              paint(12, 0, c40, 14, 0, 36)
              paint(3, 0, c80, 2, 16, 8)
              paint(3, 8, c80, 3, 0, 8)
              substitute(3, 0, c80, 7, 0)
              substitute(3, 8, c80, 7, 10)
            }
            substitute(2, 0, c40, bw + 4, 0)
            substitute(2, 8, c40, bw + 4, 10)
            paint(bw + 1, 0, row, 2, 0, 16)
            substitute(bw + 1, 0, row, bw + 4, 0)
            substitute(bw + 1, 8, row, bw + 4, 10)
            paint(bw + 10, 0, row, bw + 10, 0, 36)
            paint(bw + 11, 0, row, bw + 11, 0, 36)
          }
        }
        for (rate, size) in zip(passRates, [8, 8, 8, 8, 12, 12, 12, 12]) {
          for group in 0..<3 {
            for column in 0..<size {
              let byte = image[rate * 36 + group * size + column]
              if byte == 127 { break subchannels }
              if byte == 196 {
                if rate <= 4 && group < 2 {
                  word |= 1 << (rate * 3 + group - 3)
                } else if rate >= 11 {
                  word |= 1 << (rate * 3 + group - 21)
                }
                break
              }
            }
          }
        }
      }
      for rate in Array(passRates.prefix(bw + 1)) + Array(passRates[4..<5 + bw]) {
        let shift = rate <= 4 ? rate * 3 - 2 : rate * 3 - 20
        if (word >> shift) & 1 != 0 { word |= 0x8000_0000 }
      }
      words[slot] = word
    }
    return words.flatMap { little(Int($0), 4) }
  }

  private static func record(_ size: Int, count: Int, band: Int, last: Int, kind: Int) -> [UInt8] {
    var bytes = Array(repeating: UInt8(0), count: size)
    bytes[1] = 2
    write(little(size, 2), 2, &bytes)
    bytes[4] = UInt8(count)
    bytes[5] = UInt8(band)
    bytes[6] = UInt8(last)
    bytes[7] = UInt8(kind)
    return bytes
  }
  private static func modes(_ country: String, dsa: UInt8) -> [[UInt8]] {
    var texts =
      dsa == 1
      ? ["SarEnableConfig 0", "coex tasar_set 0 1"] : ["SarEnableConfig 1", "coex tasar_set 0 0"]
    if dsa == 1 {
      let sets = [
        "US,CA,MX,SV,CO,PR,CR,EC,AR,VI,GT,BR,UM",
        "AT,BE,BG,CY,CZ,DK,EE,FR,FI,DE,GR,HU,IS,IT,IE,LV,LI,LT,LU,MT,NL,NO,PL,PT,RO,SK,SI,ES,SE,CH,GB,ZA,TR,AE,SA,HR,RS,XK",
        "JP", "KR", "AU,HK,NZ,SG,MY,VN,BN,TH,KH,LA,MM,CN",
        "TW,PK,NP,BD,CL,PA,VE,UY,LK,MV,AF,MN,BT,MO,PH,PE,DO,GU,FJ,NC,PG,WS,VU", "IN",
      ]
      if let index = sets.firstIndex(where: { $0.components(separatedBy: ",").contains(country) }) {
        let arg = country == "CA" ? 1 : index == 1 ? 2 : index == 3 ? 3 : 0
        texts.append("coex tasar_set 13 \(arg)")
      }
    }
    return texts.map { text in
      var bytes = Array(repeating: UInt8(0), count: 328)
      write(little(text.utf8.count, 2), 4, &bytes)
      write(Array(text.utf8), 8, &bytes)
      return bytes
    }
  }
  private static func build(
    _ country: String, power: [Group], sar: [Group], common: [Group], db: [Group], sdb: [[String]]
  ) throws -> Data {
    let records = power.flatMap { group in
      group.rows.map { (groups.firstIndex(of: group.name)!, $0.label, $0.cells) }
    }
    let rows = try powerRows(records)
    var tables = [record(532, count: 4, band: 2, last: 0, kind: 5)]
    write(bitmap(rows), 44, &tables[0])
    let pad = padded(rows)
    for (band, channels, offset) in [(1, channels2, 0), (2, channels5, channels2.count)] {
      for start in stride(from: 0, to: channels.count, by: 8) {
        var count = min(8, channels.count - start)
        if country != "XZ" && band == 1 && start == 8 { count = 5 }
        var command = record(
          44 + count * 122, count: count, band: band, last: start + 8 >= channels.count ? 1 : 0,
          kind: 0)
        command[0] = 3
        command[1] = 10
        write(Array(country.utf8), 8, &command)
        write(pad, 12, &command)
        for slot in 0..<count {
          let row = rows[offset + start + slot]
          let dense = groups.enumerated().flatMap { i, group in
            Array(row[i * 36..<i * 36 + columns[group]!.count])
          }
          var expanded = [UInt8]()
          for descriptor in descriptors {
            let src = descriptor[0]
            let kind = descriptor[1]
            let stride = descriptor[2]
            if kind == 0 {
              expanded.append(dense[src])
            } else {
              let steps = kind == 1 && src == 4 ? 1 : 3
              let deltas = kind == 1 ? [0, 4, 6] : [0, 3, 5]
              for step in 0..<steps { expanded += deltas.map { dense[src + step * stride + $0] } }
            }
          }
          try check(expanded.count == 121)
          command[44 + slot * 122] = UInt8(channels[start + slot])
          write(expanded, 45 + slot * 122, &command)
        }
        tables.append(command)
      }
    }
    var sarCommand = record(144, count: 20, band: 1, last: 1, kind: 1)
    write(Array(country.utf8), 8, &sarCommand)
    var sarRows = Array(repeating: Array(repeating: "x", count: 4), count: 20)
    for row in sar[0].rows { sarRows[try subband(row.label, count: 20)] = row.cells }
    for (index, cells) in sarRows.enumerated() {
      sarCommand[44 + index * 5] = UInt8(index)
      write(cells.map { cell($0, power: false) }, 45 + index * 5, &sarCommand)
    }
    tables.append(sarCommand)
    var commonCommand = record(58, count: 13, band: 1, last: 1, kind: 4)
    for row in common[0].rows {
      guard row.label.count == 5, row.label.hasPrefix("ch"),
        row.label.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }),
        let channel = Int(row.label.dropFirst(2)), (1...13).contains(channel)
      else {
        throw RestoreFailure("Invalid common-path regulatory channel.")
      }
      commonCommand[43 + channel] = cell(row.cells[0], power: false)
    }
    tables.append(commonCommand)
    var sdbCommand = record(265, count: 17, band: 1, last: 1, kind: 2)
    for (index, cells) in sdb.enumerated() {
      sdbCommand[44 + index * 13] = UInt8(index)
      write(cells.map { cell($0, power: false) }, 45 + index * 13, &sdbCommand)
    }
    tables.append(sdbCommand)
    var dsa: UInt8 = 0
    for group in db {
      for row in group.rows where row.label == country { dsa = octal(row.cells[75]) }
    }
    let modeRecords = modes(country, dsa: dsa)
    var result =
      Array("J7RP".utf8) + little(1, 2) + Array(country.utf8) + [
        UInt8(modeRecords.count), 13, 0, 0, 0, 0, 0, 0,
      ]
    result += modeRecords.flatMap { $0 }
    result += tables.flatMap { $0 }
    write(little(result.count, 4), 12, &result)
    return try NeoFirmwareConversions.policy(Data(result), country: country)
  }

  public static func derive(_ inputs: [String: Data]) throws -> [String: Data] {
    try derive(inputs, authenticated: true)
  }
  static func inventoryDigest(_ outputs: [String: Data]) -> String {
    let records = outputs.keys.sorted().map { "\($0)\t\(outputs[$0]!.sha256)\n" }.joined()
    return Data(records.utf8).sha256
  }
  static func verifyOutputs(
    _ outputs: [String: Data], pins: [String: String], inventory: String
  ) throws {
    for (name, expected) in pins {
      try check(outputs[name]?.sha256 == expected)
    }
    try check(inventoryDigest(outputs) == inventory)
  }
  // Internal entry point permits synthetic grammar fixtures; production always pins inputs.
  static func derive(_ inputs: [String: Data], authenticated: Bool) throws -> [String: Data] {
    for (name, sha) in inputSHA256 {
      guard let data = inputs[name] else {
        throw RestoreFailure("Missing regulatory input: \(name)")
      }
      try check(!authenticated || data.sha256 == sha)
    }
    let power = try sections(
      inputs["IZUBA_TxPwrLimit_MT79x1.dat"]!, name: "IZUBA_TxPwrLimit_MT79x1.dat",
      expected: columns, allowY: true)
    let sar = try sections(
      inputs["IZUBA_TxPwrLimit_SAR.dat"]!, name: "IZUBA_TxPwrLimit_SAR.dat",
      expected: ["tab": sarColumns], allowY: false)
    let common = try sections(
      inputs["IZUBA_TxPwrLimit_2gCommonPath.dat"]!, name: "IZUBA_TxPwrLimit_2gCommonPath.dat",
      expected: nil, allowY: false)
    let db = try database(inputs["IZUBA_db.dat"]!)
    let sdb = try simultaneous(inputs["IZUBA_TxPwrLimit_SDB.dat"]!)
    let databaseCountries = Set(db.first { $0.name == "2gCC" }!.rows.map(\.label))
    let candidates = Set(power.keys).intersection(sar.keys).intersection(common.keys).intersection(
      databaseCountries)
    let countries = candidates.filter { country in
      !rejectedCountries.contains(country) && country.utf8.count == 2
        && country.utf8.allSatisfy { (65...90).contains($0) }
    }.sorted()
    try check(countries.contains("XZ") && countries.contains("US"))
    var result = [String: Data]()
    for country in countries {
      try Task.checkCancellation()
      let name = "mediatek/mt7932/policy/" + (country == "XZ" ? "world-XZ" : country) + ".bin"
      let bytes = try build(
        country, power: power[country]!, sar: sar[country]!, common: common[country]!, db: db,
        sdb: sdb)
      result[name] = bytes
    }
    if authenticated {
      try verifyOutputs(result, pins: outputSHA256, inventory: outputInventorySHA256)
    }
    return result
  }
}
