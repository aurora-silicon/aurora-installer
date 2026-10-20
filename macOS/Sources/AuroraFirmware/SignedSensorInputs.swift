// SPDX-License-Identifier: MIT
import Foundation

/// Select complete signed calibration records without removing their envelope.
/// Callers admit the physical source separately; ambiguous inputs are rejected.
public enum SignedSensorInputs {

  /// Preserve the complete device-local signed root-key container. This admits
  /// its structure and type; the enclave verifies the certificate chain.
  public static func rootKey(_ data: Data) throws -> Data {
    try require(
      data.startIndex == 0 && !data.isEmpty && data.count <= 16 << 20,
      "Invalid signed sensor root-key size.")
    let outer = try FirmwareDER.element(data, at: 0, limit: data.count)
    try require(
      outer.tag == 0x30 && outer.whole.count == data.count,
      "Invalid signed sensor root-key envelope.")
    let parts = try FirmwareDER.children(data, outer)
    try require(
      parts.count == 3 && FirmwareDER.text(data, parts[0], "IMG4")
        && parts[1].tag == 0x30 && parts[2].tag == 0xa0,
      "Missing signed sensor root-key envelope.")
    let payload = try FirmwareDER.children(data, parts[1])
    try require(
      payload.count == 4 && FirmwareDER.text(data, payload[0], "IM4P")
        && FirmwareDER.text(data, payload[1], "MSRk") && payload[2].tag == 0x16
        && !payload[2].content.isEmpty && payload[3].tag == 4 && !payload[3].content.isEmpty,
      "Invalid sensor root-key payload.")
    let wrapper = try FirmwareDER.children(data, parts[2])
    try require(
      wrapper.count == 1 && wrapper[0].tag == 0x30,
      "Invalid sensor root-key manifest wrapper.")
    let manifest = try FirmwareDER.children(data, wrapper[0])
    try require(
      manifest.count >= 2 && FirmwareDER.text(data, manifest[0], "IM4M"),
      "Missing sensor root-key manifest.")
    return data
  }

  public static func calibration(in container: Data) throws -> Data {
    try require(
      container.startIndex == 0 && !container.isEmpty && container.count <= 1 << 30,
      "Invalid sensor calibration source size.")
    var found = Set<Data>()
    for (marker, combined) in [
      (Data([0x16, 4]) + Data("IMG4".utf8), false),
      (Data([0x16, 4]) + Data("comb".utf8), true),
    ] {
      var offset = 0
      var candidates = 0
      while offset < container.count,
        let match = container.range(of: marker, in: offset..<container.count)
      {
        try Task.checkCancellation()
        offset = match.lowerBound + 1
        candidates += 1
        try require(candidates <= 65536, "Too many sensor calibration candidates.")
        for header in 2...6 where match.lowerBound >= header {
          let start = match.lowerBound - header
          guard container[start] == 0x30,
            let outer = try? FirmwareDER.element(container, at: start, limit: container.count),
            outer.content.lowerBound == match.lowerBound,
            outer.whole.count <= 16 << 20
          else { continue }
          if (try? (combined ? validCombined(container, outer) : validStandalone(container, outer)))
            == true
          {
            found.insert(container.subdata(in: outer.whole))
            try require(found.count <= 1, "Ambiguous signed sensor calibration.")
          }
        }
      }
    }
    try require(found.count == 1, "Expected exactly one distinct signed sensor calibration.")
    return found.first!
  }

  private static func validStandalone(_ data: Data, _ outer: FirmwareDER.Element) throws -> Bool {
    let parts = try FirmwareDER.children(data, outer)
    guard parts.count >= 3, FirmwareDER.text(data, parts[0], "IMG4"), parts[1].tag == 0x30,
      parts[2].tag == 0xa0
    else { return false }
    let payload = try FirmwareDER.children(data, parts[1])
    guard payload.count >= 4, FirmwareDER.text(data, payload[0], "IM4P"),
      FirmwareDER.text(data, payload[1], "FSC2"),
      payload[3].tag == 4
    else { return false }
    let prefix = data[payload[3].content].prefix(256)
    return prefix.range(of: Data("CALB".utf8)) != nil
      && data[parts[2].content].range(of: Data("IM4M".utf8)) != nil
  }

  private static func validCombined(_ data: Data, _ outer: FirmwareDER.Element) throws -> Bool {
    let fields = try FirmwareDER.children(data, outer)
    guard fields.count == 3, FirmwareDER.text(data, fields[0], "comb"), fields[1].tag == 0x30,
      fields[2].tag == 0x30
    else { return false }
    let record = try FirmwareDER.children(data, fields[1])
    let security = try FirmwareDER.children(data, fields[2])
    guard record.count == 2, FirmwareDER.text(data, record[0], "fdrd"), record[1].tag == 4,
      let first = security.first, FirmwareDER.text(data, first, "secb")
    else { return false }
    let image = try FirmwareDER.element(
      data, at: record[1].content.lowerBound, limit: record[1].content.upperBound)
    guard image.tag == 0x30, image.whole.upperBound == record[1].content.upperBound else {
      return false
    }
    let parts = try FirmwareDER.children(data, image)
    guard parts.count >= 2, FirmwareDER.text(data, parts[0], "IMG4"), parts[1].tag == 0x30 else {
      return false
    }
    let payload = try FirmwareDER.children(data, parts[1])
    guard payload.count >= 4, FirmwareDER.text(data, payload[0], "IM4P"),
      FirmwareDER.text(data, payload[1], "FSCl"),
      payload[2].tag == 0x16, payload[3].tag == 4
    else { return false }
    let prefix = data[payload[3].content].prefix(64)
    let remainder = data[parts[1].whole.upperBound..<image.content.upperBound]
    return prefix.range(of: Data("CALB".utf8)) != nil
      && remainder.range(of: Data("IM4M".utf8)) != nil
      && remainder.range(of: Data("FSCl".utf8)) != nil
  }
}
