import Foundation
import XCTest

@testable import AuroraFirmware

/// Boundary cases for the MacBook Neo light sensor calibration (issue #170):
/// the six channel gains are unsigned 16-bit values, only a zero gain leaves
/// the sensor uncalibrated, and a record outside the expected layout is
/// refused. Every record here is synthetic.
final class NeoLightSensorCalibrationTests: XCTestCase {
  /// LSCI offsets of the six gains, in the order the output lists them.
  private static let gainOffsets = [58, 62, 66, 60, 64, 68]
  /// Output slots of the six gains. Slots 5, 6 and 10 hold a constant 1.
  private static let gainSlots = [7, 8, 9, 11, 12, 13]

  private func record(gains: [Int] = Array(repeating: 255, count: 6), fixed: [UInt32]? = nil)
    -> Data
  {
    var lsci = Data(repeating: 0, count: 156)
    lsci[0] = 5
    lsci[1] = 4
    lsci[4] = 156
    for (index, value) in (fixed ?? Array(repeating: 0x0001_0000, count: 5)).enumerated() {
      for byte in 0..<4 {
        lsci[28 + index * 4 + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte)))
      }
    }
    for (offset, gain) in zip(Self.gainOffsets, gains) {
      lsci[offset] = UInt8(truncatingIfNeeded: gain)
      lsci[offset + 1] = UInt8(truncatingIfNeeded: gain >> 8)
    }
    return lsci
  }

  private func values(_ calibration: Data) -> [Float] {
    (0..<14).map { slot in
      let at = 16 + slot * 4
      let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(calibration[at + $1]) << (8 * UInt32($1)) }
      return Float(bitPattern: bits)
    }
  }

  func testEveryChannelGainIsReadAsUnsigned16Bit() throws {
    // Each gain is an exact multiple of 255, so its ratio is an exact Float.
    // Read as signed, every one of them is negative.
    let cases: [(gain: Int, ratio: Float)] = [
      (0x807f, 129), (0x817e, 130), (0xff00, 256), (0xffff, 257),
    ]
    for (channel, slot) in Self.gainSlots.enumerated() {
      for (gain, ratio) in cases {
        var gains = Array(repeating: 255, count: 6)
        gains[channel] = gain
        let calibration = try XCTUnwrap(
          NeoFirmwareConversions.alsCalibration(record(gains: gains)),
          "channel \(channel) gain \(gain)")
        var expected = [Float](repeating: 1, count: 14)
        expected[slot] = ratio
        XCTAssertEqual(values(calibration), expected, "channel \(channel) gain \(gain)")
      }
    }
    let all = try XCTUnwrap(
      NeoFirmwareConversions.alsCalibration(
        record(gains: [0xffff, 0xff00, 0x817e, 0x807f, 0xfe01, 0x8000])))
    XCTAssertEqual(
      values(all), [1, 1, 1, 1, 1, 1, 1, 257, 256, 130, 1, 129, 255, Float(32768.0 / 255.0)])
  }

  func testOnlyAZeroGainLeavesTheSensorUncalibrated() throws {
    for channel in 0..<6 {
      var gains = Array(repeating: 255, count: 6)
      gains[channel] = 0
      XCTAssertNil(try NeoFirmwareConversions.alsCalibration(record(gains: gains)), "\(channel)")
      // The smallest gain, one with a zero low byte, one with a zero high
      // byte, and the two that are zero or negative as a signed value.
      for gain in [1, 0x0100, 0x00ff, 0x8000, 0xffff] {
        gains[channel] = gain
        let calibration = try XCTUnwrap(
          NeoFirmwareConversions.alsCalibration(record(gains: gains)),
          "channel \(channel) gain \(gain)")
        XCTAssertEqual(
          values(calibration)[Self.gainSlots[channel]], Float(Double(gain) / 255.0),
          "channel \(channel) gain \(gain)")
      }
    }
    XCTAssertNil(
      try NeoFirmwareConversions.alsCalibration(record(gains: Array(repeating: 0, count: 6))))
  }

  func testAZeroGainDoesNotExcuseARecordOutsideTheLayout() throws {
    // nil means "install without the file"; a record the converter doesn't
    // understand must still be refused, whatever its gains are.
    for gains in [Array(repeating: 255, count: 6), Array(repeating: 0, count: 6)] {
      let valid = record(gains: gains)
      var wrongType = valid
      wrongType[0] = 4
      var wrongVersion = valid
      wrongVersion[1] = 5
      var shortLength = valid
      shortLength[4] = 155
      // The length field is two bytes: 0x019c has the right low byte.
      var wideLength = valid
      wideLength[5] = 1
      var longer = valid + Data([0])
      let longerSameLength = longer
      longer[4] = 157
      // A slice that doesn't start at index 0, built so that the length field
      // also reads 156 at the backing buffer's offsets 4 and 5.
      var backing = Data([0, 0]) + valid
      backing[4] = 156
      backing[5] = 0
      let slice = backing[2...]
      XCTAssertEqual(slice.startIndex, 2)
      XCTAssertEqual(Array(slice.prefix(6)), [5, 4, 156, 0, 156, 0])
      for (name, lsci) in [
        ("type", wrongType), ("version", wrongVersion), ("short length", shortLength),
        ("wide length", wideLength), ("157 bytes", longer),
        ("157 bytes, length 156", longerSameLength), ("155 bytes", Data(valid.dropLast())),
        ("empty", Data()), ("slice", slice),
      ] {
        XCTAssertThrowsError(try NeoFirmwareConversions.alsCalibration(lsci), name) { error in
          XCTAssertTrue(error is RestoreFailure, name)
        }
      }
    }
  }

  func testTheOutputLayoutAndSignedFixedPointValues() throws {
    // 16.16 fixed point: 1, -1, 0.5, -0.5 and the most negative value.
    let fixed: [UInt32] = [0x0001_0000, 0xffff_0000, 0x0000_8000, 0xffff_8000, 0x8000_0000]
    let calibration = try XCTUnwrap(
      NeoFirmwareConversions.alsCalibration(
        record(gains: [255, 510, 765, 1020, 1275, 1530], fixed: fixed)))
    XCTAssertEqual(calibration.count, 80)
    XCTAssertEqual(
      Array(calibration.prefix(16)),
      [0x31, 0x2e, 0x15, 0x65, 0xd6, 0xb8, 0x46, 0x07, 56, 0, 0, 0, 0, 0, 0, 0])
    XCTAssertEqual(values(calibration), [1, -1, 0.5, -0.5, -32768, 1, 1, 1, 2, 3, 1, 4, 5, 6])
    XCTAssertEqual(Array(calibration.suffix(8)), Array(repeating: 0, count: 8))
  }
}
