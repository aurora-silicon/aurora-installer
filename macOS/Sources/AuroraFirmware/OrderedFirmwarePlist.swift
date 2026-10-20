// SPDX-License-Identifier: MIT
import Foundation

/// Firmware dictionaries are ordered: their serialized byte offsets are part
/// of the interface. Foundation's unordered dictionaries cannot represent it.
indirect enum FirmwarePlist {
  struct Entry {
    let key: String
    var value: FirmwarePlist
  }
  case dictionary([Entry])
  case array([FirmwarePlist])
  case string(String)
  case integer(UInt32)
  case bytes(Data)
  case boolean(Bool)
  case interface

  subscript(_ key: String) -> FirmwarePlist? {
    guard case .dictionary(let entries) = self else { return nil }
    return entries.first { $0.key == key }?.value
  }
  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var integer: UInt32? {
    if case .integer(let value) = self { return value }
    return nil
  }
  var data: Data? {
    if case .bytes(let value) = self { return value }
    return nil
  }
  var array: [Self]? {
    if case .array(let value) = self { return value }
    return nil
  }

  static func decode(_ input: Data) throws -> Self {
    try require(
      input.count <= 16 << 20 && input.allSatisfy { $0 < 128 },
      "Firmware property list exceeds its input budget or encoding.")
    // Firmware uses ID/IDREF links, not DTD-defined entities. On some SDKs a
    // non-resolving XMLParser silently drops an external reference instead of
    // reporting it, which would change the firmware without a parse error.
    let text = String(decoding: input, as: UTF8.self)
    let markup = text.replacingOccurrences(
      of: #"(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>"#, with: "", options: .regularExpression)
    try require(
      !markup.contains("<!ENTITY")
        && markup.range(
          of: #"&(?!(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);)"#,
          options: .regularExpression) == nil,
      "Firmware XML cannot define or reference custom entities.")
    let delegate = FirmwareXMLParser()
    let parser = XMLParser(data: input)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    try require(
      parser.parse() && !delegate.failed && delegate.stack.isEmpty && delegate.root != nil,
      "Malformed firmware property list.")
    var ids = [String: FirmwareXMLParser.Node]()
    var budget = 100000
    func value(_ node: FirmwareXMLParser.Node, active: Set<ObjectIdentifier>) throws -> Self {
      budget -= 1
      try require(
        budget >= 0 && !active.contains(ObjectIdentifier(node)),
        "Cyclic or oversized firmware property list.")
      var active = active
      active.insert(ObjectIdentifier(node))
      if let id = node.attributes["ID"] {
        try require(ids[id] == nil || ids[id] === node, "Duplicate firmware property identifier.")
        ids[id] = node
      }
      if let ref = node.attributes["IDREF"] {
        guard let target = ids[ref], target.tag == node.tag, node.children.isEmpty else {
          throw RestoreFailure("Unknown firmware property reference.")
        }
        return try value(target, active: active)
      }
      switch node.tag {
      case "plist":
        try require(node.children.count == 1, "Invalid firmware plist root.")
        return try value(node.children[0], active: active)
      case "dict":
        try require(node.children.count % 2 == 0, "Incomplete firmware property dictionary.")
        var entries = [Entry]()
        var keys = Set<String>()
        for index in stride(from: 0, to: node.children.count, by: 2) {
          let key = node.children[index]
          try require(key.tag == "key" && key.children.isEmpty, "Invalid firmware property key.")
          guard let text = try value(key, active: active).string, keys.insert(text).inserted else {
            throw RestoreFailure("Duplicate firmware property key.")
          }
          entries.append(
            Entry(key: text, value: try value(node.children[index + 1], active: active)))
        }
        return .dictionary(entries)
      case "array": return .array(try node.children.map { try value($0, active: active) })
      case "string", "key":
        try require(node.children.isEmpty, "Invalid firmware property string.")
        return .string(node.text)
      case "integer":
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = text.hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
        guard let number, node.children.isEmpty else {
          throw RestoreFailure("Invalid firmware integer.")
        }
        return .integer(number)
      case "data":
        let text = node.text.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: text), node.children.isEmpty else {
          throw RestoreFailure("Invalid firmware property data.")
        }
        return .bytes(data)
      case "true", "false":
        try require(node.children.isEmpty, "Invalid firmware property boolean.")
        return .boolean(node.tag == "true")
      default: throw RestoreFailure("Unsupported firmware property type.")
      }
    }
    return try value(delegate.root!, active: [])
  }
}

private final class FirmwareXMLParser: NSObject, XMLParserDelegate {
  final class Node {
    let tag: String
    let attributes: [String: String]
    var text = ""
    var children = [Node]()
    init(_ tag: String, _ attributes: [String: String]) {
      self.tag = tag
      self.attributes = attributes
    }
  }
  var stack = [Node]()
  var root: Node?
  var failed = false
  private var count = 0
  private var textBytes = 0

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    count += 1
    guard count <= 100000, stack.count < 64 else {
      failed = true
      parser.abortParsing()
      return
    }
    let node = Node(name, attributes)
    if let parent = stack.last {
      parent.children.append(node)
    } else {
      guard root == nil else {
        failed = true
        parser.abortParsing()
        return
      }
      root = node
    }
    stack.append(node)
  }
  func parser(_ parser: XMLParser, foundCharacters text: String) {
    textBytes += text.utf8.count
    guard textBytes <= 16 << 20 else {
      failed = true
      parser.abortParsing()
      return
    }
    stack.last?.text += text
  }
  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard stack.last?.tag == name else {
      failed = true
      parser.abortParsing()
      return
    }
    stack.removeLast()
  }
  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) {
    failed = true
    parser.abortParsing()
  }
  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?
  ) {
    failed = true
    parser.abortParsing()
  }
}
