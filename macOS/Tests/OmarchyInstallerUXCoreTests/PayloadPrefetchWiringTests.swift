#if os(macOS)
  import Foundation
  import XCTest

  final class PayloadPrefetchWiringTests: XCTestCase {
    func testTheDownloadStartsBeforeTheEngineChecksTheMac() throws {
      // Wiring guard only: the payload download overlaps engine inspection
      // and the size choice instead of waiting for the first plan.
      let source = try String(
        contentsOf: Self.packageRoot.appendingPathComponent(
          "Sources/OmarchyAppleInstallerApp/LiveInstallerEnvironment.swift"),
        encoding: .utf8)
      let preparation = try XCTUnwrap(source.range(of: "func preparePlan("))
      let body = source[preparation.upperBound...]
      let begin = try XCTUnwrap(body.range(of: "beginPayloadPrefetch(release.assets.payload)"))
      let inspection = try XCTUnwrap(body.range(of: "EngineInspectionRunner().inspect("))
      let store = try XCTUnwrap(
        body.range(of: "try catalogStore.store(release.assets.catalogIdentity)"))
      let sample = try XCTUnwrap(
        body.range(of: "prefetch.bytesOnDisk(for: release.assets.payload)"))
      XCTAssertLessThan(store.lowerBound, begin.lowerBound)
      XCTAssertLessThan(begin.lowerBound, inspection.lowerBound)
      XCTAssertLessThan(sample.lowerBound, inspection.lowerBound)
      let reserve = try XCTUnwrap(
        body.range(of: "let planningReserve = release.assets.planningReserveBytes"))
      let freshProbe = try XCTUnwrap(body.range(of: "try AppleSiliconHostInspector().inspect()"))
      XCTAssertLessThan(sample.lowerBound, reserve.lowerBound)
      XCTAssertLessThan(reserve.lowerBound, freshProbe.lowerBound)
      XCTAssertLessThan(freshProbe.lowerBound, inspection.lowerBound)
      XCTAssertNotNil(body.range(of: "reservedBytes: planningReserve"))
      XCTAssertEqual(source.components(separatedBy: "beginPayloadPrefetch(release").count, 2)
    }

    private static var packageRoot: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }
  }
#endif
