// SPDX-License-Identifier: MIT
import Foundation

/// Select complete signed calibration records without removing their envelope.
/// Callers admit the physical source separately; ambiguous inputs are rejected.
public enum SignedSensorInputs {

  /// Preserve a complete combined root-key record, including its trust bundle.
  /// Structural admission does not establish the issuer chain or sensor binding.
  public static func rootKey(_ data: Data) throws -> Data {
    try combined(data, payload: "MSRk", kind: "root-key", noun: "root key")
  }

  /// Admit a calibration in the combined layout the enclave loads: its FSC2
  /// IM4P under the sealing manifest, with the trust bundle as secb.
  public static func sealedCalibration(_ data: Data) throws -> Data {
    try combined(data, payload: "FSC2", kind: "calibration", noun: "calibration")
  }

  /// The calibration the enclave can load. It refuses a standalone FSC2 IMG4
  /// but loads the same IM4P resealed like the root key; an FSCl record
  /// already has the combined layout and is kept as it is.
  public static func loadableCalibration(_ data: Data, seal: Data, trust: Data) throws -> Data {
    let outer = try FirmwareDER.element(data, at: 0, limit: data.count)
    let first = try FirmwareDER.children(data, outer).first
    guard let first, FirmwareDER.text(data, first, "IMG4") else { return data }
    return try sealedCalibration(reseal(data, seal: seal, trust: trust))
  }

  /// comb { fdrd: IMG4 { record's IM4P, [0] seal }, secb: trust }: one of this
  /// Mac's signed factory records with its own manifest replaced by the FDR
  /// sealing manifest, the layout macOS hands to the enclave. Every byte comes
  /// from the device's own records; callers admit the result by type.
  public static func reseal(_ record: Data, seal: Data, trust: Data) throws -> Data {
    try require(
      record.startIndex == 0 && !record.isEmpty && record.count <= 16 << 20
        && seal.startIndex == 0 && !seal.isEmpty && seal.count <= 16 << 20
        && !trust.isEmpty && trust.count <= 16 << 20,
      "Invalid signed sensor record, seal or trust bundle size.")
    let outer = try FirmwareDER.element(record, at: 0, limit: record.count)
    try require(
      outer.tag == 0x30 && outer.whole.count == record.count,
      "Invalid signed sensor record envelope.")
    let parts = try FirmwareDER.children(record, outer)
    try require(
      parts.count == 3 && FirmwareDER.text(record, parts[0], "IMG4") && parts[1].tag == 0x30,
      "The signed sensor record is not an IMG4.")
    let manifest = try FirmwareDER.element(seal, at: 0, limit: seal.count)
    try require(
      manifest.tag == 0x30 && manifest.whole.count == seal.count,
      "The sealing record is not one DER manifest.")
    let image = der(0x30, der(0x16, Data("IMG4".utf8)) + record[parts[1].whole] + der(0xa0, seal))
    return der(
      0x30,
      der(0x16, Data("comb".utf8)) + der(0x30, der(0x16, Data("fdrd".utf8)) + der(4, image))
        + der(0x30, der(0x16, Data("secb".utf8)) + der(4, trust)))
  }

  private static func der(_ tag: UInt8, _ value: Data) -> Data {
    guard value.count >= 0x80 else { return Data([tag, UInt8(value.count)]) + value }
    let length = withUnsafeBytes(of: UInt64(value.count).bigEndian) { Data($0) }.drop { $0 == 0 }
    return Data([tag, 0x80 | UInt8(length.count)]) + length + value
  }

  private static func combined(_ data: Data, payload type: String, kind: String, noun: String)
    throws -> Data
  {
    try require(
      data.startIndex == 0 && !data.isEmpty && data.count <= 16 << 20,
      "Invalid signed sensor \(kind) size.")
    let outer = try FirmwareDER.element(data, at: 0, limit: data.count)
    try require(
      outer.tag == 0x30 && outer.whole.count == data.count,
      "Invalid signed sensor \(kind) envelope.")
    let fields = try FirmwareDER.children(data, outer)
    try require(
      fields.count == 3 && FirmwareDER.text(data, fields[0], "comb")
        && fields[1].tag == 0x30 && fields[2].tag == 0x30,
      "The sensor \(noun) requires its complete combined envelope.")
    let record = try FirmwareDER.children(data, fields[1])
    let security = try FirmwareDER.children(data, fields[2])
    try require(
      record.count == 2 && FirmwareDER.text(data, record[0], "fdrd")
        && record[1].tag == 4 && security.count == 2
        && FirmwareDER.text(data, security[0], "secb") && security[1].tag == 4
        && !security[1].content.isEmpty,
      "Missing complete sensor \(kind) record or trust bundle.")
    let image = try FirmwareDER.element(
      data, at: record[1].content.lowerBound, limit: record[1].content.upperBound)
    try require(
      image.tag == 0x30 && image.whole.upperBound == record[1].content.upperBound,
      "Invalid embedded sensor \(kind) image.")
    let parts = try FirmwareDER.children(data, image)
    try require(
      parts.count == 3 && FirmwareDER.text(data, parts[0], "IMG4")
        && parts[1].tag == 0x30 && parts[2].tag == 0xa0,
      "Missing signed sensor \(kind) envelope.")
    let payload = try FirmwareDER.children(data, parts[1])
    try require(
      payload.count == 4 && FirmwareDER.text(data, payload[0], "IM4P")
        && FirmwareDER.text(data, payload[1], type) && payload[2].tag == 0x16
        && !payload[2].content.isEmpty && payload[3].tag == 4 && !payload[3].content.isEmpty,
      "Invalid sensor \(kind) payload.")
    let wrapper = try FirmwareDER.children(data, parts[2])
    try require(
      wrapper.count == 1 && wrapper[0].tag == 0x30,
      "Invalid sensor \(kind) manifest wrapper.")
    let manifest = try FirmwareDER.children(data, wrapper[0])
    try require(
      manifest.count >= 2 && FirmwareDER.text(data, manifest[0], "IM4M"),
      "Missing sensor \(kind) manifest.")
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
