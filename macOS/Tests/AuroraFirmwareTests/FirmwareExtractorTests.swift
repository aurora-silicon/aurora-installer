import Foundation
import XCTest

@testable import AuroraFirmware

final class FirmwareExtractorTests: XCTestCase, @unchecked Sendable {
  func testBundledRecipeAdmitsOnlyItsExactModelAndBoundedPartialDownload() throws {
    let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
    // The 6 GHz policy table adds one 14,728,357-byte output. Its compressed
    // extents lie in segments already fetched for the other radio files, so
    // the partial download is unchanged; only local publication space grows.
    XCTAssertEqual(plan.authenticatedRangeBytes, 15_996_940)
    XCTAssertEqual(plan.sourceSizeBytes, 19_772_231_540)
    XCTAssertEqual(plan.outputs.count, 14)
    XCTAssertEqual(plan.outputs.reduce(0) { $0 + $1.sizeBytes }, 46_743_151)
    XCTAssertEqual(plan.requiredDiskBytes, 47_824_896)
    for model in ["apple,j614s", "apple,j414s", "j700", "apple,j700/../other"] {
      XCTAssertThrowsError(try FirmwareExtractionPlan.bundled(for: model))
    }
  }

  func testResumeVerifiesPublishedBytesAndRejectsChangesOrSymlinks() async throws {
    let fixture = try JSONDecoder().decode(
      RestoreImageTests.AEAFixture.self,
      from: Data(
        contentsOf: XCTUnwrap(
          Bundle.module.url(forResource: "go-aea", withExtension: "json", subdirectory: "Fixtures"))
      ))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("firmware")
    let recipe = fixture.recipe
    let decoded = try decodeRanges(
      recipe,
      fetched: Dictionary(uniqueKeysWithValues: fixture.records.map { ($0.record, $0.data) }),
      archiveKey: fixture.key)
    try assembleRangeFiles(recipe, decoded: decoded, output: output)
    let plan = FirmwareExtractionPlan(
      deviceIdentifier: "fixture", recipeSHA256: String(repeating: "a", count: 64), recipe: recipe)
    let extractor = FirmwareExtractor()
    XCTAssertEqual(try extractor.verify(plan, at: output).files.count, 1)
    let checkpoint = root.appendingPathComponent("checkpoint")
    let resumed = try await extractor.extractOrResume(plan, to: output, cacheDirectory: checkpoint)
    XCTAssertEqual(resumed.files.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    let file = output.appendingPathComponent("test.bin")
    let original = try Data(contentsOf: file)
    try Data("changed".utf8).write(to: file)
    XCTAssertThrowsError(try extractor.verify(plan, at: output))
    do {
      _ = try await extractor.extractOrResume(plan, to: output, cacheDirectory: checkpoint)
      XCTFail("Changed publication was accepted on resume")
    } catch is RestoreFailure {}
    XCTAssertEqual(try Data(contentsOf: file), Data("changed".utf8))
    try FileManager.default.removeItem(at: file)
    let alternate = root.appendingPathComponent("alternate")
    try original.write(to: alternate)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alternate)
    XCTAssertThrowsError(try extractor.verify(plan, at: output))
  }
}
