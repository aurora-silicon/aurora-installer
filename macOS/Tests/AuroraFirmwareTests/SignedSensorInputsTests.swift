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
}
