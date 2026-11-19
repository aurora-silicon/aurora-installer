import Foundation
import XCTest

@testable import AuroraAppleInstallerTrustCore

final class BootLoaderVersionTests: XCTestCase {
  func testAuraMarker() throws {
    let found = try XCTUnwrap(
      BootLoaderVersion.find(in: Data("code ##aura_ver##1.0b1\0 more".utf8)))
    XCTAssertEqual(found, BootLoaderVersion(loader: .aura, version: "1.0b1"))
    XCTAssertFalse(found.isLegacy)
    XCTAssertEqual(found.description, "aura 1.0b1")
  }

  func testLegacyMarker() throws {
    let found = try XCTUnwrap(
      BootLoaderVersion.find(in: Data("code ##m1n1_ver##v1.5.2\0 more".utf8)))
    XCTAssertEqual(found, BootLoaderVersion(loader: .legacy, version: "v1.5.2"))
    XCTAssertTrue(found.isLegacy)
    XCTAssertEqual(found.description, "legacy v1.5.2")
  }

  func testAuraMarkerWinsOverLegacy() {
    let image = Data("##m1n1_ver##v1.5.2\0 ... ##aura_ver##1.0b1\0".utf8)
    XCTAssertEqual(
      BootLoaderVersion.find(in: image), BootLoaderVersion(loader: .aura, version: "1.0b1"))
  }

  func testNoMarker() {
    XCTAssertNil(BootLoaderVersion.find(in: Data("kernel STACKBOT".utf8)))
  }

  func testSlicedDataUsesItsOwnIndices() {
    let whole = Data("padding ##aura_ver##1.0b1\0tail".utf8)
    let slice = whole[whole.index(whole.startIndex, offsetBy: 8)...]
    XCTAssertEqual(
      BootLoaderVersion.find(in: slice), BootLoaderVersion(loader: .aura, version: "1.0b1"))
  }
}
