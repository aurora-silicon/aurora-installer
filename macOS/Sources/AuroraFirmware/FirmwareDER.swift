// SPDX-License-Identifier: MIT
import Foundation

/// Bounded canonical DER shared by signed sensor and generic firmware inputs.
enum FirmwareDER {
  struct Element {
    let tag: UInt8
    let content: Range<Int>
    let whole: Range<Int>
  }

  static func element(_ data: Data, at start: Int, limit: Int) throws -> Element {
    try require(
      start >= 0 && limit <= data.count && start <= limit - 2,
      "Truncated firmware record.")
    let tag = data[start]
    var length = Int(data[start + 1])
    var content = start + 2
    if length >= 128 {
      let count = length & 127
      try require(
        (1...4).contains(count) && content <= limit - count && data[content] != 0,
        "Invalid firmware record length.")
      length = data[content..<(content + count)].reduce(0) { ($0 << 8) | Int($1) }
      content += count
      try require(length >= 128, "Noncanonical firmware record length.")
    }
    try require(length <= limit - content, "Firmware record escapes its enclosing record.")
    return Element(
      tag: tag, content: content..<(content + length), whole: start..<(content + length))
  }

  static func children(_ data: Data, _ element: Element) throws -> [Element] {
    var at = element.content.lowerBound
    var result = [Element]()
    while at < element.content.upperBound {
      try require(result.count < 1024, "Too many firmware record fields.")
      let child = try self.element(data, at: at, limit: element.content.upperBound)
      result.append(child)
      at = child.whole.upperBound
    }
    return result
  }

  static func text(_ data: Data, _ element: Element, _ expected: String) -> Bool {
    element.tag == 0x16 && data[element.content].elementsEqual(expected.utf8)
  }

}
