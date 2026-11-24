// SPDX-License-Identifier: MIT
import Foundation

/// Shared Broadcom radio firmware conversions. Inputs are admitted, relative
/// files from the stub's Recovery image or its restore image's System volume,
/// never arbitrary host filesystem paths.
public enum BroadcomFirmware {
  private final class Node {
    var bytes: Data?
    var children: [String: Node] = [:]
    func equals(_ other: Node) -> Bool {
      bytes == other.bytes && children.keys.sorted() == other.children.keys.sorted()
        && children.allSatisfy { key, child in child.equals(other.children[key]!) }
    }
  }

  /// Aliases name another input, as the Recovery image's symbolic links do.
  /// Each one reads its target's bytes, so only real files count toward the
  /// memory budget.
  private static func validate(_ inputs: [String: Data], links: [String: String]) throws {
    try require(
      inputs.count <= 10000 && links.count <= 10000, "Too many radio firmware inputs.")
    var total = 0
    for (name, data) in inputs {
      try require(
        safeRelative(name) && name.utf8.count <= 4096 && data.count <= maxFileBytes,
        "Invalid radio firmware input.")
      total += data.count
      try require(total <= 256 << 20, "Radio inputs exceed their memory budget.")
    }
    for (name, target) in links {
      try require(
        safeRelative(name) && name.utf8.count <= 4096 && inputs[name] == nil
          && inputs[target] != nil, "Invalid radio firmware alias.")
    }
  }

  public static func wifi(
    _ inputs: [String: Data], links: [String: String] = [:]
  ) throws -> [String: Data] {
    try validate(inputs, links: links)
    let extensions = [
      "trx": "bin", "txt": "txt", "clmb": "clm_blob",
      "txcb": "txcap_blob", "sig": "sig",
    ]
    let dimensions = ["C", "s", "P", "M", "V", "m", "A"]
    let root = Node()
    for path in (Array(inputs.keys) + Array(links.keys)).sorted() {
      try Task.checkCancellation()
      let pieces = path.split(separator: "/").map(String.init)
      guard let filename = pieces.last, !filename.contains("_gen"),
        !pieces.dropLast().contains(where: { ["perf", "assert"].contains($0) }),
        let dot = filename.lastIndex(of: ".")
      else { continue }
      let ext = String(filename[filename.index(after: dot)...])
      guard extensions[ext] != nil else { continue }
      let name = (ext == "txt" ? "" : "P-") + String(filename[..<dot])
      let identifier = (Array(pieces.dropLast()) + [name]).joined(separator: "_")
      var properties = [String: String]()
      for field in identifier.split(separator: "_", omittingEmptySubsequences: true) {
        guard let split = field.firstIndex(of: "-") else {
          throw RestoreFailure("Malformed radio firmware dimensions.")
        }
        let key = String(field[..<split])
        let value = String(field[field.index(after: split)...])
        if key == "P", let antenna = value.firstIndex(of: "-") {
          properties["P"] = String(value[..<antenna])
          properties["A"] = String(value[value.index(after: antenna)...])
        } else {
          properties[key] = value
        }
      }
      var keys = [ext]
      for dimension in dimensions {
        if let value = properties.removeValue(forKey: dimension) { keys.append(value) }
      }
      try require(properties.isEmpty && keys.count >= 3, "Unknown radio firmware dimensions.")
      var node = root
      for key in keys {
        if node.children[key] == nil { node.children[key] = Node() }
        node = node.children[key]!
      }
      let input = inputs[links[path] ?? path]!
      let bytes = try ext == "txt" ? nvram(input) : input
      try require(node.bytes == nil || node.bytes == bytes, "Conflicting radio firmware input.")
      node.bytes = bytes
    }
    func prune(_ node: Node, depth: Int) {
      for child in node.children.values { prune(child, depth: depth + 1) }
      if node.bytes == nil, depth > 3, let first = node.children.values.first,
        node.children.values.allSatisfy({ $0.equals(first) })
      {
        node.bytes = first.bytes
      }
      if let bytes = node.bytes, node.children.values.allSatisfy({ $0.bytes == bytes }) {
        node.children = [:]
      }
    }
    prune(root, depth: 0)
    var result = [String: Data]()
    func walk(_ node: Node, keys: [String]) throws {
      if let data = node.bytes {
        try require(keys.count >= 3, "Incomplete radio firmware selection.")
        let suffix = keys.count > 3 ? "," + keys.dropFirst(3).joined(separator: "-") : ""
        let path =
          "brcm/brcmfmac" + keys[1] + keys[2].lowercased()
          + "-pcie.apple" + suffix + "." + extensions[keys[0]]!
        try require(
          safeRelative(path) && (result[path] == nil || result[path] == data),
          "Conflicting radio firmware output.")
        result[path] = data
      }
      for key in node.children.keys.sorted() { try walk(node.children[key]!, keys: keys + [key]) }
    }
    try walk(root, keys: [])
    return result
  }

  private static func nvram(_ bytes: Data) throws -> Data {
    try require(bytes.allSatisfy { $0 < 128 }, "Radio NVRAM is not ASCII.")
    let text = String(decoding: bytes, as: UTF8.self)
    var result = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
      guard let split = line.firstIndex(of: "=") else {
        throw RestoreFailure("Invalid radio NVRAM record.")
      }
      result +=
        line[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
        + "=" + line[line.index(after: split)...] + "\n"
    }
    return Data(result.utf8)
  }

  /// The antenna SKUs Apple ships a Wi-Fi board's aliases for. brcmfmac tries
  /// `<board>-<sku>` before `<board>` and the chip's generic name.
  public static let antennaSKUs = ["ID", "X0", "X2", "X3"]

  /// M4 Pro and M4 Max laptops and the Wi-Fi board of their BCM4388 rev C2
  /// (the ADT `wlan` node's `module-instance`, which aura copies into
  /// `brcm,board-type`). J614s and J616s are read from their device trees; the
  /// M4 Max boards share their M4 Pro sibling's board, as every M1 to M3
  /// Pro/Max pair does.
  public static let m4ProMaxWiFi: [String: (chip: String, board: String)] = [
    "j614s": ("4388c2", "mriya"), "j614c": ("4388c2", "mriya"),
    "j616s": ("4388c2", "hostomel"), "j616c": ("4388c2", "hostomel"),
  ]

  /// The package names a board's Wi-Fi still lacks: firmware (`.bin`),
  /// regulatory data (`.clm_blob`) and NVRAM (`.txt`), for the board itself
  /// and each antenna SKU, resolved the way brcmfmac resolves them. An empty
  /// result means Linux can bring the radio up on every SKU of that board.
  public static func missingWiFi(
    _ outputs: [String: Data], chip: String, board: String
  ) -> [String] {
    let base = "brcm/brcmfmac" + chip + "-pcie.apple"
    let named = Set(outputs.filter { !$0.value.isEmpty }.keys)
    var missing = [String]()
    for sku in [""] + antennaSKUs {
      let stems = (sku.isEmpty ? [] : [base + "," + board + "-" + sku]) + [base + "," + board]
      for ext in ["bin", "clm_blob"] {
        let candidates = stems.map { $0 + "." + ext } + [base + "." + ext]
        if !candidates.contains(where: named.contains) {
          missing.append(candidates[0])
        }
      }
      // NVRAM names carry the module and vendor after the board (and SKU).
      // A board-wide name must not be another SKU's.
      func nvram(_ stem: String, skuSpecific: Bool) -> Bool {
        named.contains { name in
          guard name.hasSuffix(".txt") else { return false }
          if name == stem + ".txt" { return true }
          guard name.hasPrefix(stem + "-") else { return false }
          if skuSpecific { return true }
          let next = name.dropFirst(stem.count + 1).prefix { $0 != "-" && $0 != "." }
          return !antennaSKUs.contains(String(next))
        }
      }
      let nvramPresent =
        (!sku.isEmpty && nvram(stems[0], skuSpecific: true))
        || nvram(base + "," + board, skuSpecific: false) || named.contains(base + ".txt")
      if !nvramPresent { missing.append(stems[0] + ".txt") }
    }
    return missing
  }

  /// Whether a converted Wi-Fi set carries firmware for this board.
  public static func carriesWiFi(_ outputs: [String: Data], board: String) -> Bool {
    outputs.contains { name, data in
      !data.isEmpty && name.hasPrefix("brcm/brcmfmac") && name.hasSuffix(".bin")
        && (name.contains("-pcie.apple," + board + ".")
          || name.contains("-pcie.apple," + board + "-"))
    }
  }

  public enum WiFiSource: String, Sendable { case system, recovery }

  /// A restore image's System volume ships every board's Wi-Fi firmware,
  /// while its Recovery image may carry only part of a chip's set: 26.6.2
  /// (25G83) Recovery holds no usable BCM4388 rev C2 firmware. Prefer the
  /// stub restore image's System volume (`RadioFirmwareRestoreImages`), and
  /// use Recovery only when it alone has this board's firmware or the board
  /// is unknown. Never the running macOS.
  public static func wifiSource(board: String?, system: [String: Data]?) -> WiFiSource {
    guard let board, let system, carriesWiFi(system, board: board) else { return .recovery }
    return .system
  }

  /// `outputs` with this board's Wi-Fi outputs (`...-pcie.apple,<board>.`
  /// and `...,<board>-<sku>.`) replaced by `board` ones: the converted files
  /// of that one board from the stub restore image's System volume.
  public static func replacingWiFi(
    _ outputs: [String: Data], board: String, with boardOutputs: [String: Data]
  ) throws -> [String: Data] {
    func own(_ name: String) -> Bool {
      name.contains("-pcie.apple," + board + ".") || name.contains("-pcie.apple," + board + "-")
    }
    try require(
      !boardOutputs.isEmpty && boardOutputs.keys.allSatisfy(own),
      "The board's Wi-Fi firmware names another board.")
    return outputs.filter { !own($0.key) }.merging(boardOutputs) { _, board in board }
  }

  /// The Bluetooth names a board still lacks: firmware and its patch table
  /// (`.bin` and `.ptb`) for at least one radio module vendor.
  public static func missingBluetooth(
    _ outputs: [String: Data], chip: String, board: String
  ) -> [String] {
    let stem = "brcm/brcmbt" + chip + "-apple," + board
    let complete = ["-a", "-m", "-u", ""].contains { vendor in
      ["bin", "ptb"].allSatisfy { outputs[stem + vendor + "." + $0]?.isEmpty == false }
    }
    return complete ? [] : [stem + "-u.bin", stem + "-u.ptb"]
  }

  public static func bluetooth(
    _ inputs: [String: Data], links: [String: String] = [:]
  ) throws -> [String: Data] {
    try validate(inputs, links: links)
    let vendors = ["AMKOR": "a", "MUR": "m", "USI": "u", "GEN": ""]
    var result = [String: Data]()
    var selected = Set<String>()
    for path in (Array(inputs.keys) + Array(links.keys)).sorted() {
      try Task.checkCancellation()
      let filename = URL(fileURLWithPath: path).lastPathComponent
      guard let dot = filename.lastIndex(of: ".") else { continue }
      let ext = String(filename[filename.index(after: dot)...])
      let stem = String(filename[..<dot])
      guard ["bin", "ptb"].contains(ext), !stem.contains("_DEV") else { continue }
      let parts = stem.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
      guard let first = parts.first,
        first.lowercased().range(
          of: #"\Abcm43[0-9]{2}[a-z][0-9]\z"#,
          options: .regularExpression) != nil, let pcie = parts.firstIndex(of: "PCIE")
      else { continue }
      var index = pcie + 1
      if index < parts.count, parts[index] == "macOS" { index += 1 }
      if index < parts.count, parts[index] == "Willamette" { index += 1 }
      guard index < parts.count else { continue }
      var board = parts[index]
      while let last = board.last, "ES2".contains(last) { board.removeLast() }
      let matches = Set(parts.compactMap { vendors[$0] })
      guard matches.count == 1, let vendor = matches.first else { continue }
      let chip = String(first.lowercased().dropFirst(3))
      let name =
        "brcm/brcmbt" + chip + "-apple," + board.lowercased()
        + (vendor.isEmpty ? "" : "-" + vendor) + "." + ext
      let input = inputs[links[path] ?? path]!
      try require(
        safeRelative(name) && (result[name] == nil || result[name] == input),
        "Conflicting Bluetooth firmware output.")
      // A .ptb without the corresponding .bin is not a usable selection.
      if ext == "bin" { selected.insert(String(name.dropLast(4))) }
      result[name] = input
    }
    return result.filter {
      !$0.key.hasSuffix(".ptb") || selected.contains(String($0.key.dropLast(4)))
    }
  }
}
