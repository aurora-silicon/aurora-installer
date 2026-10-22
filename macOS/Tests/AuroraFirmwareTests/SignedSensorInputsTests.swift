import Foundation
import XCTest

@testable import AuroraFirmware

final class SignedSensorInputsTests: XCTestCase {
  struct Corpus: Decodable {
    struct Vector: Decodable {
      let name: String
      let input: Data
      let accepted: Bool
      let expected: Data?
    }
    let vectors: [Vector]
    let rootKeys: [Vector]
  }

  func testCompleteSignedEnvelopesMatchTheIndependentCollector() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "sensor-calibration", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    for vector in corpus.rootKeys {
      if vector.accepted {
        XCTAssertEqual(try SignedSensorInputs.rootKey(vector.input), vector.input, vector.name)
      } else {
        XCTAssertThrowsError(try SignedSensorInputs.rootKey(vector.input), vector.name)
      }
    }
    for vector in corpus.vectors {
      if vector.accepted {
        XCTAssertEqual(
          try SignedSensorInputs.calibration(in: vector.input), vector.expected, vector.name)
      } else {
        XCTAssertThrowsError(try SignedSensorInputs.calibration(in: vector.input), vector.name)
      }
    }
  }

  static func der(_ tag: UInt8, _ value: Data) -> Data {
    if value.count < 0x80 { return Data([tag, UInt8(value.count)]) + value }
    if value.count < 0x100 { return Data([tag, 0x81, UInt8(value.count)]) + value }
    return Data([tag, 0x82, UInt8(value.count >> 8), UInt8(value.count & 0xff)]) + value
  }

  static func text(_ value: String) -> Data { der(0x16, Data(value.utf8)) }

  static func payload(_ type: String) -> Data {
    der(0x30, text("IM4P") + text(type) + text("1.0") + der(4, Data("CALB synthetic".utf8)))
  }

  static func record(_ type: String) -> Data {
    let manifest = der(0x30, text("IM4M") + der(2, Data([0])) + der(4, Data("factory".utf8)))
    return der(0x30, text("IMG4") + payload(type) + der(0xa0, manifest))
  }

  static let seal = der(0x30, text("IM4M") + der(2, Data([0])) + der(4, Data("sealing".utf8)))
  static let trust = Data(repeating: 0x5a, count: 300)

  static func sealed(_ type: String) -> Data {
    let image = der(0x30, text("IMG4") + payload(type) + der(0xa0, seal))
    return der(
      0x30,
      text("comb") + der(0x30, text("fdrd") + der(4, image))
        + der(0x30, text("secb") + der(4, trust)))
  }

  func testFactoryRecordsAreResealedUnderTheSealingManifest() throws {
    for type in ["MSRk", "FSC2"] {
      XCTAssertEqual(
        try SignedSensorInputs.reseal(Self.record(type), seal: Self.seal, trust: Self.trust),
        Self.sealed(type), type)
    }
    let root = try SignedSensorInputs.reseal(
      Self.record("MSRk"), seal: Self.seal, trust: Self.trust)
    XCTAssertEqual(try SignedSensorInputs.rootKey(root), root)
    XCTAssertThrowsError(try SignedSensorInputs.sealedCalibration(root))
    for (record, seal) in [
      (Self.record("FSC2").dropLast(), Self.seal), (Self.sealed("FSC2"), Self.seal),
      (Self.record("FSC2"), Data("not a manifest".utf8)), (Data(), Self.seal),
    ] {
      XCTAssertThrowsError(
        try SignedSensorInputs.reseal(Data(record), seal: seal, trust: Self.trust))
    }
    XCTAssertThrowsError(
      try SignedSensorInputs.reseal(Self.record("FSC2"), seal: Self.seal, trust: Data()))
  }

  func testOnlyACompleteSealedFSC2CalibrationIsLoadable() throws {
    let good = Self.sealed("FSC2")
    XCTAssertEqual(try SignedSensorInputs.sealedCalibration(good), good)
    for candidate in [
      Self.record("FSC2"), good.dropLast(), good + Data("trailing".utf8), Self.sealed("MSRk"),
    ] {
      XCTAssertThrowsError(try SignedSensorInputs.sealedCalibration(Data(candidate)))
    }
    XCTAssertEqual(
      try SignedSensorInputs.loadableCalibration(
        Self.record("FSC2"), seal: Self.seal, trust: Self.trust), good)
    let combined = Self.sealed("FSCl")
    XCTAssertEqual(
      try SignedSensorInputs.loadableCalibration(combined, seal: Data(), trust: Data()), combined)
  }
}
