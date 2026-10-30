// SPDX-License-Identifier: MIT
import Foundation

/// Shared M1–M3 radio firmware conversions. Inputs are admitted, relative files
/// from the selected Recovery image, never arbitrary host filesystem paths.
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
        safeRelative(name) && safeRelative(target) && name.utf8.count <= 4096,
        "Invalid radio firmware alias.")
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
      guard let input = inputs[links[path] ?? path] else { continue }
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
