import Foundation
import XCTest

@testable import AuroraFirmware

private actor ZIPSource: FirmwareRangeReading {
  nonisolated let sizeBytes: Int
  let spans: [(Int, Data)]
  var requests: [(Int, Int)] = []

  init(data: Data) {
    sizeBytes = data.count
    spans = [(0, data)]
  }
  init(size: Int, spans: [(Int, Data)]) {
    sizeBytes = size
    self.spans = spans
  }

  func read(offset: Int, count: Int) throws -> Data {
    try require(offset >= 0 && count > 0 && offset <= sizeBytes - count, "Fixture range bounds.")
    requests.append((offset, count))
    var result = Data(repeating: 0, count: count)
    for (start, data) in spans {
      let low = max(offset, start)
      let high = min(offset + count, start + data.count)
      if low < high {
        result.replaceSubrange(
          (low - offset)..<(high - offset), with: data[(low - start)..<(high - start)])
      }
    }
    return result
  }
  func transferred() -> Int { requests.reduce(0) { $0 + $1.1 } }
}

final class IPSWArchiveTests: XCTestCase, @unchecked Sendable {
  struct Fixture: Decodable {
    struct Archive: Decodable {
      let name: String
      let data: String
    }
    struct Sparse: Decodable {
      struct Span: Decodable {
        let offset: Int
        let data: String
      }
      let size: Int
      let spans: [Span]
    }
    let archives: [Archive]
    let sparse: Sparse
  }

  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "zip-interop", withExtension: "json", subdirectory: "Fixtures")
    )
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  private func bytes(_ name: String = "stored") throws -> Data {
    let record = try XCTUnwrap(fixture().archives.first { $0.name == name })
    return try XCTUnwrap(Data(base64Encoded: record.data))
  }
  private func set(_ data: inout Data, at offset: Int, value: Int, width: Int) {
    data.replaceSubrange(offset..<(offset + width), with: littleBytes(value, count: width))
  }
  private func central(_ data: Data) throws -> Int {
    try data.little(data.count - 22 + 16, 4)
  }
  private func rejected(_ data: Data) async {
    do {
      _ = try await IPSWArchive.open(ZIPSource(data: data))
      XCTFail("Invalid ZIP was accepted")
    } catch is RestoreFailure {} catch { XCTFail("Unexpected error: \(error)") }
  }
  private func unreadable(_ data: Data, maximum: Int = 1024, digest: String? = nil) async throws {
    let archive = try await IPSWArchive.open(ZIPSource(data: data))
    do {
      _ = try await archive.read(
        try XCTUnwrap(archive.members.first), maximumBytes: maximum, expectedSHA256: digest)
      XCTFail("Unsafe member was extracted")
    } catch is RestoreFailure {}
  }

  func testStoredDeflatedZIP64AndDataDescriptorInteroperate() async throws {
    for record in try fixture().archives {
      let source = ZIPSource(data: try XCTUnwrap(Data(base64Encoded: record.data)))
      let archive = try await IPSWArchive.open(source)
      XCTAssertEqual(archive.members.map(\.name), ["BuildManifest.plist"])
      let member = try XCTUnwrap(archive.members.first)
      let expected = Data("<plist>synthetic</plist>".utf8)
      let data = try await archive.read(member, maximumBytes: 1024, expectedSHA256: expected.sha256)
      XCTAssertEqual(data, expected, record.name)
    }
  }

  func testSparseArchiveBeyond4GiBUsesOnlyBoundedRanges() async throws {
    let fixture = try fixture().sparse
    let spans = try fixture.spans.map { ($0.offset, try XCTUnwrap(Data(base64Encoded: $0.data))) }
    let source = ZIPSource(size: fixture.size, spans: spans)
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    XCTAssertEqual(member.localHeaderOffset, 5 * 1024 * 1024 * 1024)
    let data = try await archive.read(member, maximumBytes: 1024)
    XCTAssertEqual(data, Data("ZIP64 sparse member".utf8))
    let transferred = await source.transferred()
    XCTAssertLessThan(transferred, 100_000)
  }

  func testMalformedDirectoryCountsBoundsAndPathsAreRejected() async throws {
    let original = try bytes()
    for index in [0, 1, 2, 3] {
      var data = original
      let end = data.count - 22
      switch index {
      case 0: set(&data, at: end + 4, value: 1, width: 2)
      case 1: set(&data, at: end + 10, value: 2, width: 2)
      case 2: set(&data, at: end + 12, value: 8 * 1024 * 1024 + 1, width: 4)
      default:
        let start = try central(data) + 46
        data.replaceSubrange(start..<(start + 3), with: Data("../".utf8))
      }
      await rejected(data)
    }
    await rejected(Data(original.dropLast()))
    await rejected(Data(repeating: 0, count: 22))
  }

  func testEncryptionSymlinksUnknownMethodsAndLocalIdentityAreRejected() async throws {
    let original = try bytes()
    for index in [0, 1, 2, 3] {
      var data = original
      let cd = try central(data)
      switch index {
      case 0:
        set(&data, at: 6, value: 1, width: 2)
        set(&data, at: cd + 8, value: 1, width: 2)
      case 1: set(&data, at: cd + 38, value: 0o120777 << 16, width: 4)
      case 2:
        set(&data, at: 8, value: 99, width: 2)
        set(&data, at: cd + 10, value: 99, width: 2)
      default: data[30] ^= 1
      }
      try await unreadable(data)
    }
  }

  func testCRCOutputBudgetDigestAndDeflateLengthAreEnforced() async throws {
    let original = try bytes()
    try await unreadable(original, maximum: 1)
    try await unreadable(original, digest: String(repeating: "0", count: 64))
    var changed = original
    changed[30 + "BuildManifest.plist".utf8.count] ^= 1
    try await unreadable(changed)
    var compressed = try bytes("deflate")
    let size = try compressed.little(22, 4)
    set(&compressed, at: 22, value: size - 1, width: 4)
    let cd = try central(compressed)
    set(&compressed, at: cd + 24, value: size - 1, width: 4)
    try await unreadable(compressed)
  }

  func testSourceAdmissionRefusesForeignHostsAndUnboundedSizes() throws {
    for url in [
      "http://updates.cdn-apple.com/image.ipsw", "https://example.org/image.ipsw",
      "https://updates.cdn-apple.com/image?token=x",
    ] {
      XCTAssertThrowsError(
        try IPSWHTTPRangeReader(url: XCTUnwrap(URL(string: url)), sizeBytes: 4096))
    }
    XCTAssertThrowsError(
      try IPSWHTTPRangeReader(
        url: XCTUnwrap(URL(string: "https://updates.cdn-apple.com/image.ipsw")), sizeBytes: Int.max)
    )
  }
}
