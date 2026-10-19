import Darwin
import Foundation
import XCTest

@testable import AuroraFirmware

final class RangeCacheTests: XCTestCase, @unchecked Sendable {
  private let a = Data("first authenticated range".utf8)
  private let b = Data("second authenticated range".utf8)

  private func record(_ bytes: Data) -> RangeRecord {
    RangeRecord(offset: 0, size: bytes.count, sha256: bytes.sha256)
  }

  private func source() -> SourceRecord {
    SourceRecord(
      sizeBytes: 4096, sha256: String(repeating: "a", count: 64),
      url: "https://updates.cdn-apple.com/fixture")
  }

  private func temporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  func testInterruptionReopensVerifiedRangesAndDownloadsOnlyMissingBytes() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("checkpoint")
    let records = [record(a), record(b)]
    var cache: FirmwareRangeCache? = try FirmwareRangeCache(directory: directory, records: records)
    let first = a
    let cached = try await cache!.fetch(source(), record: records[0], base: 0) { _, _, _ in first }
    XCTAssertEqual(cached, a)
    do {
      _ = try await cache!.fetch(source(), record: records[1], base: 0) { _, _, _ in
        throw CancellationError()
      }
      XCTFail("Interrupted fetch succeeded")
    } catch is CancellationError {}
    cache = nil

    let resumed = try FirmwareRangeCache(directory: directory, records: records)
    let reused = try await resumed.fetch(source(), record: records[0], base: 0) { _, _, _ in
      throw RestoreFailure("A verified checkpoint was downloaded again")
    }
    XCTAssertEqual(reused, a)
    let second = b
    let downloaded = try await resumed.fetch(source(), record: records[1], base: 0) { _, _, _ in
      second
    }
    XCTAssertEqual(downloaded, b)
    try await resumed.retire(records)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testCorruptBytesAreRefetchedAndBadDownloadCannotPoisonCheckpoint() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("checkpoint")
    let descriptor = record(a)
    let cache = try FirmwareRangeCache(directory: directory, records: [descriptor])
    let bytes = a
    _ = try await cache.fetch(source(), record: descriptor, base: 0) { _, _, _ in bytes }
    let file = directory.appendingPathComponent(descriptor.sha256)
    try Data(repeating: 0, count: a.count).write(to: file)
    let fixed = try await cache.fetch(source(), record: descriptor, base: 0) { _, _, _ in bytes }
    XCTAssertEqual(fixed, a)
    try FileManager.default.removeItem(at: file)
    do {
      _ = try await cache.fetch(source(), record: descriptor, base: 0) { _, _, _ in
        Data("wrong".utf8)
      }
      XCTFail("Invalid download was accepted")
    } catch is RestoreFailure {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testSymlinkAndHardlinkEntriesAreRejectedWithoutFollowingThem() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("checkpoint")
    let descriptor = record(a)
    let cache = try FirmwareRangeCache(directory: directory, records: [descriptor])
    let outside = root.appendingPathComponent("outside")
    try a.write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    let entry = directory.appendingPathComponent(descriptor.sha256)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside)
    for hardlink in [false, true] {
      if hardlink {
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.linkItem(at: outside, to: entry)
      }
      do {
        _ = try await cache.fetch(source(), record: descriptor, base: 0) { _, _, _ in
          throw CancellationError()
        }
        XCTFail("Unsafe cache entry accepted")
      } catch is RestoreFailure {}
      XCTAssertEqual(try Data(contentsOf: outside), a)
    }
  }

  func testDirectoryOwnershipModeLockAndForeignEntriesAreChecked() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("checkpoint")
    let records = [record(a)]
    var cache: FirmwareRangeCache? = try FirmwareRangeCache(directory: directory, records: records)
    XCTAssertNotNil(cache)
    XCTAssertThrowsError(try FirmwareRangeCache(directory: directory, records: records))
    cache = nil
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    XCTAssertThrowsError(try FirmwareRangeCache(directory: directory, records: records))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    XCTAssertThrowsError(try FirmwareRangeCache(directory: link, records: records))
    let foreign = directory.appendingPathComponent("keep-me")
    try Data("unrelated".utf8).write(to: foreign)
    XCTAssertThrowsError(try FirmwareRangeCache(directory: directory, records: records))
    XCTAssertEqual(try Data(contentsOf: foreign), Data("unrelated".utf8))
  }

  func testAbandonedStagingFileIsRetiredAndUnadmittedRangeIsRejected() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent("." + UUID().uuidString.lowercased() + ".partial")
    try a.write(to: partial)
    let cache = try FirmwareRangeCache(directory: root, records: [record(a)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    do {
      _ = try await cache.fetch(source(), record: record(b), base: 0) { _, _, _ in
        throw CancellationError()
      }
      XCTFail("Unadmitted range accepted")
    } catch is RestoreFailure {}
    do {
      _ = try await cache.fetch(source(), record: record(a), base: Int.min) { _, _, _ in
        throw CancellationError()
      }
      XCTFail("Invalid base accepted")
    } catch is RestoreFailure {}
  }

  func testInterruptedPublicationIsRetiredWithoutFollowingSymlinks() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("checkpoint")
    let output = root.appendingPathComponent("firmware")
    let records = [record(a)]
    let outside = root.appendingPathComponent("outside")
    try a.write(to: outside)
    var cache: FirmwareRangeCache? = try FirmwareRangeCache(directory: directory, records: records)
    let workspace = try await cache!.publicationWorkspace(beside: output)
    let nested = workspace.appendingPathComponent("apple/nested")
    try FileManager.default.createDirectory(
      at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try b.write(to: nested.appendingPathComponent("incomplete"))
    try FileManager.default.createSymbolicLink(
      at: workspace.appendingPathComponent("outside-link"), withDestinationURL: outside)
    cache = nil
    let resumed = try FirmwareRangeCache(directory: directory, records: records)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    XCTAssertEqual(try Data(contentsOf: outside), a)
    let fresh = try await resumed.publicationWorkspace(beside: output)
    XCTAssertEqual(fresh, workspace)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.path), [])
  }
}
