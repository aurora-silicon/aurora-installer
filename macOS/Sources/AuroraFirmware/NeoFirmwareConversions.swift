// SPDX-License-Identifier: MIT
import Foundation

/// Bounded conversions for the public firmware interfaces used by J700.
/// Input collection and source authentication belong to the privileged caller.
public enum NeoFirmwareConversions {
  public struct CameraEntry: Equatable, Sendable {
    public let magic: Int
    public let name: String
    public let size: Int
    public let fileSize: Int

    init(magic: Int, name: String, size: Int, fileSize: Int? = nil) {
      self.magic = magic
      self.name = name
      self.size = size
      self.fileSize = fileSize ?? size
    }
  }

  public static let cameraRegistry: [CameraEntry] = [
    CameraEntry(magic: 0x1820_0103, name: "1820_01XX", size: 0x442c),
    CameraEntry(magic: 0x1822_0201, name: "1822_02XX", size: 0x442c),
    CameraEntry(magic: 0x8720_0103, name: "8720_01XX", size: 0x36ac),
    CameraEntry(magic: 0x8723_0101, name: "8723_01XX", size: 0x361c),
    CameraEntry(magic: 0x1921_0106, name: "1921_01XX", size: 0xad40),
    CameraEntry(magic: 0x1922_0201, name: "1922_02XX", size: 0xad40),
    CameraEntry(magic: 0x1925_0306, name: "1925_03XX", size: 0xcbc0, fileSize: 0xcba6),
    CameraEntry(magic: 0x2224_0106, name: "2224_01XX", size: 0x6ff4),
  ]
  public static let requiredCameraNames: Set<String> = [
    "apple/isp_1921_01XX.dat", "apple/isp_1922_02XX.dat", "apple/isp_1925_03XX.dat",
  ]
  public static let alsName = "apple/j700-aop-als-cal.bin"
  public static let trackpadName = "apple/tpmtfw-j700.bin"
  public static let wifiPatch = "IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin"
  public static let wifiRAM = "IZUBA_W7932_2.bin"
  public static let bluetoothNames = [
    "MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin",
    "MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin",
  ]
  public static let ptxName = "MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx"
  public static var requiredRadioNames: Set<String> {
    Set(
      [
        "mediatek/mt7932/" + wifiPatch, "mediatek/mt7932/" + wifiRAM,
        "mediatek/mt7932/ppr.bin", "mediatek/mt7932/oca2.bin", "mediatek/mt7932/wcal.bin",
        "mediatek/mt7932/config-original.bin", "mediatek/" + ptxName,
        "mediatek/j700-mt7932-btcal.bin", "mediatek/j700-mt7932-bdaddr.bin",
      ]
        + bluetoothNames.map { "mediatek/" + $0 })
  }

  public static func camera(_ data: Data, requireNeoSet: Bool = true) throws -> [String: Data] {
    try require(
      data.startIndex == 0 && !data.isEmpty && data.count <= 16 << 20,
      "Camera input exceeds its budget.")
    let registry = Dictionary(uniqueKeysWithValues: cameraRegistry.map { ($0.magic, $0) })
    var files = [String: Data]()
    for offset in stride(from: 0, to: max(0, data.count - 31), by: 4096) {
      try Task.checkCancellation()
      let h = try (0..<8).map { try data.big32(offset + 4 * $0) }
      guard h[2] == 0 && h[3] == 0 && h[6] == 0,
        h[4] != 0 && h[4] & 0xff00_0000 == h[4],
        h[5] != 0 && h[5] & 0xffff_0000 == h[5], h[7] == 0x03c0_0000,
        let entry = registry[h[0]]
      else { continue }
      var bytes = try data.part(offset, entry.fileSize)
      bytes.append(Data(repeating: 0, count: ((entry.size + 63) & ~63) - entry.fileSize))
      let name = "apple/isp_" + entry.name + ".dat"
      try require(files[name] == nil || files[name] == bytes, "Conflicting camera setfiles.")
      files[name] = bytes
    }
    try require(
      !requireNeoSet || requiredCameraNames.isSubset(of: Set(files.keys)),
      "Required camera setfiles are missing.")
    return files
  }

  public static func alsCalibration(_ lsci: Data) throws -> Data {
    try require(
      lsci.startIndex == 0 && lsci.count == 156 && lsci.prefix(2) == Data([5, 4]),
      "Unsupported LSCI record.")
    try require(try lsci.little(4, 2) == 156, "LSCI length field changed.")
    var values = try (0..<5).map { index -> Double in
      Double(Int32(bitPattern: UInt32(try lsci.little(28 + index * 4, 4)))) / 65536.0
    }
    values.append(1.0)
    for offsets in [[58, 62, 66], [60, 64, 68]] {
      values.append(1.0)
      for offset in offsets {
        let gain = Int16(bitPattern: UInt16(try lsci.little(offset, 2)))
        try require(gain > 0, "LSCI has a non-positive gain ratio.")
        values.append(Double(gain) / 255.0)
      }
    }
    var result = littleBytes(0x0746_b8d6_6515_2e31, count: 8) + littleBytes(56, count: 8)
    for value in values { result.append(littleBytes(Int(Float(value).bitPattern), count: 4)) }
    result.append(Data(repeating: 0, count: 8))
    try require(result.count == 80, "Invalid ALS output size.")
    return result
  }

  public static func bluetoothAddress(_ data: Data) throws -> Data {
    try require(
      data.count == 6 && data != Data(repeating: 0, count: 6)
        && data != Data(repeating: 255, count: 6), "No usable local Bluetooth address.")
    return data
  }

  public static func configuration(_ data: Data) throws -> Data {
    try require(data.count <= 1 << 20, "Radio configuration exceeds its budget.")
    guard let text = String(data: data, encoding: .ascii) else {
      throw RestoreFailure("Radio configuration must be ASCII.")
    }
    var records = Data()
    var keys = Set<String>()
    for line in text.components(separatedBy: .newlines) {
      let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let split = line.firstIndex(of: " ")
      let key = split.map { String(line[..<$0]) } ?? line
      let value =
        split.map {
          String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
      let k = Data(key.utf8)
      let v = Data(value.utf8)
      try require(
        !k.isEmpty && k.count < 32 && v.count < 32 && !k.contains(0) && !v.contains(0)
          && !keys.contains(key), "Invalid or repeated radio setting.")
      keys.insert(key)
      records.append(contentsOf: [3, UInt8(k.count), UInt8(v.count), 0])
      records.append(k)
      records.append(Data(repeating: 0, count: 32 - k.count))
      records.append(v)
      records.append(Data(repeating: 0, count: 32 - v.count))
      try require(keys.count <= 65, "Too many radio settings.")
    }
    try require(
      [64, 65].contains(keys.count) && keys.contains("Sta5gBw") && keys.contains("DisRoaming"),
      "Required radio settings are missing.")
    return Data("J7CF".utf8) + littleBytes(keys.count, count: 4) + records
  }

  private struct Element {
    let tag: UInt8
    let start: Int
    let end: Int
  }
  private static func element(_ data: Data, at: Int, end: Int) throws -> Element {
    try require(at >= 0 && at <= end - 2 && end <= data.count, "Truncated factory element.")
    let tag = data[at]
    var cursor = at + 1
    if tag & 0x1f == 0x1f {
      let begin = cursor
      while cursor < end && data[cursor] & 0x80 != 0 {
        cursor += 1
        try require(cursor - begin <= 8, "Factory tag exceeds its budget.")
      }
      try require(cursor < end, "Truncated factory tag.")
      cursor += 1
    }
    try require(cursor < end, "Factory element has no length.")
    var length = Int(data[cursor])
    cursor += 1
    if length & 0x80 != 0 {
      let count = length & 0x7f
      try require(
        (1...4).contains(count) && cursor <= end - count, "Invalid factory element length.")
      length = try data.part(cursor, count).reduce(0) { ($0 << 8) | Int($1) }
      cursor += count
    }
    try require(length <= end - cursor, "Factory element escapes its container.")
    return Element(tag: tag, start: cursor, end: cursor + length)
  }

  public static func factoryFields(_ data: Data) throws -> [String: Data] {
    try require(
      data.startIndex == 0 && !data.isEmpty && data.count <= 32 << 20,
      "Factory input exceeds its budget.")
    var budget = 65536
    func children(_ start: Int, _ end: Int) throws -> [Element] {
      var at = start
      var result = [Element]()
      while at < end {
        budget -= 1
        try require(budget >= 0, "Too many factory elements.")
        let item = try element(data, at: at, end: end)
        result.append(item)
        at = item.end
      }
      return result
    }
    func bytes(_ e: Element) throws -> Data { try data.part(e.start, e.end - e.start) }
    let top = try element(data, at: 0, end: data.count)
    try require(top.tag == 0x30 && top.end == data.count, "Invalid factory envelope.")
    let outer = try children(top.start, top.end)
    try require(outer.count >= 2, "Incomplete factory envelope.")
    try require(try bytes(outer[0]) == Data("IMG4".utf8), "Invalid factory envelope type.")
    let payload = try children(outer[1].start, outer[1].end)
    try require(payload.count >= 4, "Incomplete factory payload.")
    try require(
      try bytes(payload[0]) == Data("IM4P".utf8) && bytes(payload[1]) == Data("BWC2".utf8)
        && payload[3].tag == 4, "Invalid factory payload type.")
    var pending = [(payload[3].start, payload[3].end, 0)]
    var fields = [Data: Data]()
    while let (start, end, depth) = pending.popLast() {
      try Task.checkCancellation()
      try require(depth <= 32, "Factory nesting exceeds its budget.")
      for item in try children(start, end) where item.tag & 0x20 != 0 {
        let inner = try children(item.start, item.end)
        if item.tag == 0x30 && inner.count == 3 && inner[0].tag == 2
          && inner[0].end - inner[0].start == 4 && inner[1].tag == 0x16 && inner[2].tag == 4
        {
          let name = Data(try bytes(inner[0]).reversed())
          try require(fields[name] == nil, "Duplicate factory field.")
          fields[name] = try bytes(inner[2])
        } else {
          pending.append((item.start, item.end, depth + 1))
        }
      }
    }
    var result = [String: Data]()
    for (name, value) in fields {
      if let text = String(data: name, encoding: .ascii) { result[text] = value }
    }
    return result
  }

  public static func validateOCA2(_ data: Data) throws {
    try require(
      data.startIndex == 0 && data.count >= 16 && data.count <= 16 << 20
        && data.prefix(4) == Data("BLOB".utf8), "Invalid OCA2 envelope.")
    let end = try data.big32(4)
    let header = try data.part(8, 2).reduce(0) { ($0 << 8) | Int($1) }
    let count = try data.part(10, 2).reduce(0) { ($0 << 8) | Int($1) }
    try require(
      header == 12 && count > 0 && end == 16 + 20 * count && end <= data.count,
      "Invalid OCA2 table.")
    var kinds = Set<Int>()
    var spans = [(Int, Int, Int, Int)]()
    for index in 0..<count {
      let at = 16 + index * 20
      let kind = try data.part(at, 2).reduce(0) { ($0 << 8) | Int($1) }
      let version = try data.part(at + 2, 2).reduce(0) { ($0 << 8) | Int($1) }
      let offset = try data.big32(at + 4)
      let length = try data.big32(at + 8)
      let checksum = try data.big32(at + 12)
      try require(
        version == 12 && offset >= end && offset <= data.count && length >= 12
          && length <= data.count - offset && kinds.insert(kind).inserted,
        "Invalid or repeated OCA2 span.")
      spans.append((offset, length, checksum, at))
    }
    spans.sort { $0.0 < $1.0 }
    var previous = end
    for (offset, length, checksum, entry) in spans {
      try require(offset >= previous, "Overlapping OCA2 spans.")
      previous = offset + length
      try require(
        try data.part(offset, 4) == data.part(entry, 4) && data.big32(offset + 4) == length,
        "OCA2 record disagrees with its entry.")
      let sum = try data.part(offset, length).reduce(UInt32(0)) { $0 &+ UInt32($1) }
      try require(Int(sum) == checksum, "OCA2 record checksum changed.")
    }
  }

  public static func validateBluetooth(_ data: Data) throws {
    try require(
      data.count > 32 && data.count <= 16 << 20
        && data.suffix(16).prefix(8) == Data([0x41, 0x4c, 0x50, 0x53, 0x8a, 0x10, 0x8a, 0x10]),
      "Invalid Bluetooth firmware trailer.")
  }

  public static func validatePTX(_ data: Data) throws {
    try require(
      data.startIndex == 0 && data.count == 198 && data.prefix(4) == Data("BLOB".utf8),
      "Invalid PTX envelope.")
    try require(
      try data.little(4, 4) == 96 && data.little(8, 2) == 1 && data.little(10, 2) == 4
        && data.little(12, 4) == 0, "Invalid PTX header.")
    var offset = 96
    for (index, entry) in [(0x101, 14), (0x201, 44), (0x301, 44), (0x401, 0)].enumerated() {
      let at = 16 + index * 20
      try require(
        try data.little(at, 4) == entry.0 && data.little(at + 4, 4) == offset
          && data.little(at + 8, 4) == entry.1 && data.little(at + 16, 4) == 0,
        "Invalid PTX record.")
      try require(
        try data.part(offset, entry.1).reduce(0) { $0 + Int($1) } == data.little(at + 12, 4),
        "PTX checksum changed.")
      offset += entry.1
    }
    try require(offset == data.count, "Trailing PTX data.")
  }

  public struct RadioInputs: Sendable {
    public let patch: Data, ram: Data, ppr: Data, config: Data, bluetooth: [Data], ptx: Data
    public let factory: Data, address: Data
    public init(
      patch: Data, ram: Data, ppr: Data, config: Data, bluetooth: [Data], ptx: Data, factory: Data,
      address: Data
    ) {
      self.patch = patch
      self.ram = ram
      self.ppr = ppr
      self.config = config
      self.bluetooth = bluetooth
      self.ptx = ptx
      self.factory = factory
      self.address = address
    }
  }

  public static func radio(_ input: RadioInputs) throws -> [String: Data] {
    try require(
      !input.patch.isEmpty && !input.ram.isEmpty && input.patch.count <= 16 << 20
        && input.ram.count <= 16 << 20, "Missing or oversized radio firmware.")
    try require(
      input.ppr.count == 412 && input.ppr.prefix(4) == Data("BLOB".utf8), "Invalid PPR envelope.")
    let fields = try factoryFields(input.factory)
    guard let oca = fields["OCA2"], let wcal = fields["WCAL"], let bcal = fields["BCAL"] else {
      throw RestoreFailure("Required factory calibration is missing.")
    }
    try validateOCA2(oca)
    try require(
      !wcal.isEmpty && wcal.count <= 1024 && wcal.prefix(4) == Data("BLOB".utf8),
      "Invalid WCAL field.")
    try require(!bcal.isEmpty && bcal.count <= 65535, "Invalid Bluetooth calibration.")
    try require(input.bluetooth.count == 2, "Required Bluetooth firmware is missing.")
    for data in input.bluetooth { try validateBluetooth(data) }
    try validatePTX(input.ptx)
    var files = [
      "mediatek/mt7932/" + wifiPatch: input.patch, "mediatek/mt7932/" + wifiRAM: input.ram,
      "mediatek/mt7932/ppr.bin": input.ppr, "mediatek/mt7932/oca2.bin": oca,
      "mediatek/mt7932/wcal.bin": wcal,
      "mediatek/mt7932/config-original.bin": try configuration(input.config),
      "mediatek/" + ptxName: input.ptx, "mediatek/j700-mt7932-btcal.bin": bcal,
      "mediatek/j700-mt7932-bdaddr.bin": try bluetoothAddress(input.address),
    ]
    for (name, data) in zip(bluetoothNames, input.bluetooth) { files["mediatek/" + name] = data }
    return files
  }

  /// Validate a supplied policy. This does not derive limits or qualify a new
  /// policy for firmware use; the signed input contract remains the authority.
  public static func policy(_ data: Data, country: String) throws -> Data {
    let alpha = Data(country.utf8)
    try require(
      data.startIndex == 0 && alpha.count == 2 && alpha.allSatisfy { (65...90).contains($0) }
        && (16...65536).contains(data.count) && data.prefix(4) == Data("J7RP".utf8),
      "Invalid radio policy envelope.")
    let version = try data.little(4, 2)
    try require(
      [1, 2, 4].contains(version) && (version != 1 || data.count <= 16384),
      "Unsupported radio policy version or size.")
    try require(
      try data.part(6, 2) == alpha
        && (2...3).contains(Int(data[8])) && data.part(9, 3) == Data([13, 0, 0])
        && data.little(12, 4) == data.count, "Invalid radio policy header.")
    var at = 16
    for _ in 0..<Int(data[8]) {
      try require(at <= data.count - 328, "Truncated radio policy mode.")
      try require(
        try data.little(at, 4) == 0 && (1...320).contains(data.little(at + 4, 4)),
        "Invalid radio policy mode.")
      at += 328
    }
    var tables = [Data]()
    for index in 0..<13 {
      try require(at <= data.count - 44, "Truncated radio policy table.")
      let size = try data.little(at + 2, 2)
      try require(
        size >= 44 && size <= min(1020, data.count - at), "Invalid radio policy table length.")
      let table = try data.part(at, size)
      if (1...9).contains(index) {
        var count = [2, 9].contains(index) ? 5 : 8
        if index == 2 && country == "XZ" { count = 6 }
        try require(
          table.prefix(2) == Data([3, 10]) && table[4] == count
            && table[5] == (index <= 2 ? 1 : 2) && table[6] == ([2, 9].contains(index) ? 1 : 0)
            && table[7] == 0 && (try table.part(8, 4)) == alpha + Data([0, 0])
            && size == 44 + count * 122, "Invalid radio country power table.")
        if country == "XZ" {
          if index <= 2 {
            for row in 0..<count {
              try require(
                Int(table[44 + row * 122]) == (index - 1) * 8 + row + 1,
                "Invalid world-policy channel order.")
            }
          }
          if index > 1 {
            try require(
              try table.part(12, 32) == tables[1].part(12, 32),
              "Inconsistent world-policy identity.")
          }
        }
      } else {
        let k = index == 0 ? 0 : index - 9
        try require(
          size == [532, 144, 58, 265][k] && table.prefix(2) == Data([0, 2])
            && table[7] == [5, 1, 4, 2][k], "Invalid original radio policy record.")
        if index == 10 {
          try require(
            try table.part(8, 4) == alpha + Data([0, 0]), "Invalid radio policy country.")
        }
      }
      tables.append(table)
      at += size
    }
    if version == 2 { at = try policy6GHz(data, at: at, alpha: alpha) }
    if version == 4 { at = try policy6GHzClasses(data, at: at, alpha: alpha) }
    try require(at == data.count, "Trailing radio policy data.")
    return data
  }
  // J7RP v4: bound class records, never firmware envelopes or SP data.
  private static func policy6GHzClasses(_ data: Data, at start: Int, alpha: Data) throws -> Int {
    let directory = try data.part(start, 16)
    try require(
      directory.prefix(4) == Data("6GCL".utf8) && directory[4] == 1
        && (1...2).contains(directory[5]) && directory[6] == 1 && directory[7] == 0
        && (try directory.little(8, 4)) == data.count - start
        && directory[12..<16].allSatisfy { $0 == 0 }, "Invalid bound class directory.")
    let channels =
      [2]
      + (1...233).filter {
        $0 != 231 && $0 & 1 == 1 && NeoRegulatoryPolicy.width6($0) != 255
      }
    var at = start + 16
    var previous: UInt8 = 0
    for _ in 0..<Int(directory[5]) {
      let section = try data.part(at, 13476)
      let id = section[0]
      try require(
        [1, 2].contains(id) && id > previous && section[1] == (id == 2 ? 1 : 0)
          && section[2] == 1 && section[3] == 110 && (try section.little(4, 4)) == 13476
          && section[15] & 0xf8 == 0 && section[8..<16].contains(where: { $0 != 0 })
          && section[16..<18] == alpha && section[18..<24].allSatisfy { $0 == 0 },
        "Invalid bound class section.")
      for (index, channel) in channels.enumerated() {
        let record = try section.part(56 + index * 122, 122)
        try require(record[0] == channel, "Invalid class channel order.")
        if channel & 3 == 1
          && section[8 + ((channel - 1) / 4) / 8]
            & UInt8(1 << (((channel - 1) / 4) % 8)) != 0
        {
          try require(
            record.dropFirst().contains { $0 != 196 && $0 != 127 },
            "Class primary has no power data.")
        }
      }
      previous = id
      at += 13476
    }
    try require(previous == 2, "Missing LPI class.")
    return at
  }
  // Swift validation of the CP2 v2 parser contract, independently written from its spec.
  private static func policy6GHz(_ data: Data, at start: Int, alpha: Data) throws -> Int {
    let header = try data.part(start, 24)
    try require(
      header.prefix(4) == Data("6GRP".utf8)
        && header[4] == 1 && header[5] == 14 && (1...32).contains(header[6])
        && header[7] == 0 && header[15] & 0xf8 == 0
        && header[8..<16].contains(where: { $0 != 0 })
        && header[16..<18] == alpha && header[18] == 1
        && header[19..<24].allSatisfy { $0 == 0 }, "Invalid 6 GHz policy header.")
    var at = start + 24
    var selectors = Set<UInt8>()
    for _ in 0..<Int(header[6]) {
      let wrapper = try data.part(at, 4)
      let size = try wrapper.little(2, 2)
      try require(
        [0x5d, 0x95].contains(wrapper[0]) && wrapper[1] == 0
          && (44...1020).contains(size), "Invalid 6 GHz policy record.")
      let body = try data.part(at + 4, size)
      let count = Int(body[4])
      try require(
        (1...8).contains(count) && body[5] == 3 && body[6] <= 1 && body[7] == 0,
        "Invalid 6 GHz page identity.")
      if wrapper[0] == 0x5d {
        try require(
          try body.prefix(2) == Data([3, 0x2a]) && body.little(2, 2) == size
            && body.part(8, 4) == alpha + Data([0, 0]) && size == 44 + 122 * count,
          "Invalid 6 GHz native page.")
        let selector = body[44]
        if [2, 15].contains(selector) {
          try require(
            count == 8 && size == 1020 && selectors.insert(selector).inserted,
            "Invalid or duplicate 6 GHz association page.")
        }
      } else {
        try require(
          body.prefix(4) == Data(repeating: 0, count: 4)
            && body[8..<44].allSatisfy { $0 == 0 } && size == 44 + 33 * count,
          "Invalid 6 GHz legacy page.")
        for index in 0..<count {
          try require(
            body[(45 + index * 33)..<(77 + index * 33)].allSatisfy { $0 == 127 },
            "Invalid 6 GHz legacy sentinel.")
        }
      }
      at += 4 + size
    }
    try require(selectors == [2, 15], "Missing 6 GHz association pages.")
    return at
  }

}
