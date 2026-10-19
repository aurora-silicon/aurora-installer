import Foundation
import XCTest
@testable import AuroraFirmware

final class FirmwareExtractorTests: XCTestCase, @unchecked Sendable {
  func testBundledRecipeAdmitsOnlyItsExactModelAndBoundedPartialDownload() throws {
    let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
    XCTAssertEqual(plan.authenticatedRangeBytes, 15_996_940)
    XCTAssertEqual(plan.sourceSizeBytes, 19_772_231_540)
    XCTAssertEqual(plan.outputs.count, 13)
    XCTAssertEqual(plan.outputs.reduce(0) { $0 + $1.sizeBytes }, 32_014_794)
    XCTAssertLessThan(plan.requiredDiskBytes, 40_000_000)
    for model in ["apple,j614s", "apple,j414s", "j700", "apple,j700/../other"] {
      XCTAssertThrowsError(try FirmwareExtractionPlan.bundled(for: model))
    }
  }

  func testResumeVerifiesPublishedBytesAndRejectsChangesOrSymlinks() throws {
    let fixture = try JSONDecoder().decode(RestoreImageTests.AEAFixture.self, from: Data(contentsOf: XCTUnwrap(
      Bundle.module.url(forResource: "go-aea", withExtension: "json", subdirectory: "Fixtures"))))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("firmware")
    let recipe = fixture.recipe
    let decoded = try decodeRanges(recipe, fetched: Dictionary(uniqueKeysWithValues: fixture.records.map { ($0.record, $0.data) }), archiveKey: fixture.key)
    try assembleRangeFiles(recipe, decoded: decoded, output: output)
    let plan = FirmwareExtractionPlan(deviceIdentifier: "fixture", recipeSHA256: String(repeating: "a", count: 64), recipe: recipe)
    let extractor = FirmwareExtractor()
    XCTAssertEqual(try extractor.verify(plan, at: output).files.count, 1)
    let file = output.appendingPathComponent("test.bin")
    let original = try Data(contentsOf: file)
    try Data("changed".utf8).write(to: file)
    XCTAssertThrowsError(try extractor.verify(plan, at: output))
    try FileManager.default.removeItem(at: file)
    let alternate = root.appendingPathComponent("alternate")
    try original.write(to: alternate)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alternate)
    XCTAssertThrowsError(try extractor.verify(plan, at: output))
  }
}
