import Foundation
import XCTest
import zlib

@testable import AuroraFirmware

/// Answers each read after `delay`, and records how many were in flight.
private actor SlowSource: FirmwareRangeReading {
  nonisolated let sizeBytes: Int
  let inner: ZIPSource
  let delay: Duration
  var inFlight = 0
  var mostInFlight = 0
  var reads: [(offset: Int, count: Int)] = []

  init(_ inner: ZIPSource, delay: Duration) {
    self.inner = inner
    self.delay = delay
    sizeBytes = inner.sizeBytes
  }

  func read(offset: Int, count: Int) async throws -> Data {
    inFlight += 1
    mostInFlight = max(mostInFlight, inFlight)
    defer { inFlight -= 1 }
    try await Task.sleep(for: delay)
    reads.append((offset, count))
    return try await inner.read(offset: offset, count: count)
  }
}

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

  func testStreamingStoredDeflatedZIP64AndDescriptorsPreserveContentAndDigest() async throws {
    for record in try fixture().archives {
      let archive = try await IPSWArchive.open(
        ZIPSource(data: XCTUnwrap(Data(base64Encoded: record.data))))
      let member = try XCTUnwrap(archive.members.first)
      let expected = Data("<plist>synthetic</plist>".utf8)
      var output = Data()
      let digest = try await archive.stream(
        member, maximumBytes: 1024, maximumCompressedBytes: 1024,
        expectedSHA256: expected.sha256, consume: { output.append($0) })
      XCTAssertEqual(output, expected, record.name)
      XCTAssertEqual(digest, expected.sha256, record.name)
    }
  }

  func testLargeStreamingMemberRetainsOnlyBoundedChunksAndChecksTheCompleteDigest() async throws {
    let source = ZIPSource(data: try largeBytes())
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    var count = 0
    var largest = 0
    let expected = "3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351"
    let digest = try await archive.stream(
      member, maximumBytes: 64 << 20, maximumCompressedBytes: 1 << 20,
      expectedSHA256: expected,
      consume: {
        count += $0.count
        largest = max(largest, $0.count)
        XCTAssertTrue($0.allSatisfy { $0 == 0 })
      })
    XCTAssertEqual(count, 64 << 20)
    XCTAssertLessThanOrEqual(largest, 1 << 20)
    XCTAssertEqual(digest, expected)
  }

  func testStreamingBudgetsFailBeforeReadingAMemberAndSinkFailureStopsDelivery() async throws {
    let source = ZIPSource(data: try largeBytes())
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    let before = await source.transferred()
    for (output, input) in [(1, 1 << 20), (64 << 20, 1), (-1, 1 << 20)] {
      do {
        try await archive.stream(member, maximumBytes: output, maximumCompressedBytes: input) { _ in
          XCTFail("Invalid budget reached the sink")
        }
        XCTFail("Invalid streaming budget admitted")
      } catch is RestoreFailure {}
    }
    let after = await source.transferred()
    XCTAssertEqual(after, before)
    var deliveries = 0
    do {
      try await archive.stream(
        member, maximumBytes: 64 << 20, maximumCompressedBytes: 1 << 20
      ) { _ in
        deliveries += 1
        throw CancellationError()
      }
      XCTFail("Cancelled sink continued")
    } catch is CancellationError {}
    XCTAssertEqual(deliveries, 1)
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

  private func largeBytes() throws -> Data {
    struct Large: Decodable { let archive: Data }
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "zip-prefix", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Large.self, from: Data(contentsOf: url)).archive
  }

  func testPrefixesInteroperateAndCompleteReadsStillCheckCRCAndEnd() async throws {
    for record in try fixture().archives {
      let archive = try await IPSWArchive.open(
        ZIPSource(
          data: try XCTUnwrap(Data(base64Encoded: record.data))))
      let member = try XCTUnwrap(archive.members.first)
      let prefix = try await archive.readPrefix(member, maximumBytes: 5)
      XCTAssertEqual(prefix, Data("<plis".utf8), record.name)
      let complete = try await archive.readPrefix(member, maximumBytes: 1024)
      XCTAssertEqual(complete, Data("<plist>synthetic</plist>".utf8), record.name)
    }
    for type in ["stored", "deflate"] {
      var changed = try bytes(type)
      let cd = try central(changed)
      let crc = try changed.little(cd + 16, 4) ^ 1
      set(&changed, at: 14, value: crc, width: 4)
      set(&changed, at: cd + 16, value: crc, width: 4)
      let archive = try await IPSWArchive.open(ZIPSource(data: changed))
      do {
        _ = try await archive.readPrefix(try XCTUnwrap(archive.members.first), maximumBytes: 1024)
        XCTFail("Complete prefix ignored its CRC")
      } catch is RestoreFailure {}
    }
  }

  func testLargeDeflatedImagePrefixHasBoundedInputAndOutput() async throws {
    let source = ZIPSource(data: try largeBytes())
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    XCTAssertEqual(member.sizeBytes, 64 << 20)
    let before = await source.transferred()
    let header = try await archive.readPrefix(member, maximumBytes: 0x11000)
    XCTAssertEqual(header, Data(repeating: 0, count: 0x11000))
    let after = await source.transferred()
    XCTAssertLessThanOrEqual(after - before, 65536 + 256)
    for (output, input) in [(0, 1024), ((1 << 20) + 1, 1024), (0x11000, 1), (1024, 0)] {
      do {
        _ = try await archive.readPrefix(
          member, maximumBytes: output, maximumCompressedBytes: input)
        XCTFail("Invalid or exhausted prefix budget admitted")
      } catch is RestoreFailure {}
    }
  }

  func testCompleteDeflatedPrefixesRejectLengthChangesAndTrailingData() async throws {
    for change in [-1, 1, 0] {
      var data = try bytes("deflate")
      var cd = try central(data)
      if change == 0 {
        let compressed = try data.little(18, 4)
        data.insert(0, at: cd)
        cd += 1
        set(&data, at: 18, value: compressed + 1, width: 4)
        set(&data, at: cd + 20, value: compressed + 1, width: 4)
        set(&data, at: data.count - 22 + 16, value: cd, width: 4)
      } else {
        let length = try data.little(22, 4) + change
        set(&data, at: 22, value: length, width: 4)
        set(&data, at: cd + 24, value: length, width: 4)
      }
      let archive = try await IPSWArchive.open(ZIPSource(data: data))
      do {
        _ = try await archive.readPrefix(try XCTUnwrap(archive.members.first), maximumBytes: 1024)
        XCTFail("Complete prefix accepted a changed stream length")
      } catch is RestoreFailure {}
    }
  }

  func testSparseMultiGiBStoredImageDoesNotReadItsBody() async throws {
    let original = try largeBytes()
    let cd = try central(original)
    let size = 2 << 30
    let start = 30 + "large.img".utf8.count
    var header = Data(original.prefix(start))
    set(&header, at: 8, value: 0, width: 2)
    set(&header, at: 18, value: size, width: 4)
    set(&header, at: 22, value: size, width: 4)
    var tail = Data(original.suffix(from: cd))
    set(&tail, at: 10, value: 0, width: 2)
    set(&tail, at: 20, value: size, width: 4)
    set(&tail, at: 24, value: size, width: 4)
    set(&tail, at: tail.count - 22 + 16, value: start + size, width: 4)
    let source = ZIPSource(
      size: start + size + tail.count, spans: [(0, header), (start + size, tail)])
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    let prefix = try await archive.readPrefix(member, maximumBytes: 0x11000)
    XCTAssertEqual(prefix, Data(repeating: 0, count: 0x11000))
    let transferred = await source.transferred()
    XCTAssertLessThan(transferred, 150_000)
    var delivered = 0
    do {
      try await archive.stream(member, maximumBytes: size, maximumCompressedBytes: size) { bytes in
        delivered += bytes.count
        XCTAssertEqual(bytes.count, 4 << 20)
        throw CancellationError()
      }
      XCTFail("Cancelled stored-image sink continued")
    } catch is CancellationError {}
    XCTAssertEqual(delivered, 4 << 20)
    let streamed = await source.transferred()
    XCTAssertLessThan(streamed, 5 << 20)
  }

  func testLongMembersKeepRangesInFlightAndDeliverThemInOrder() async throws {
    let original = try largeBytes()
    let cd = try central(original)
    let range = 4 << 20
    let size = 10 * range + 12345
    var body = Data(count: size)
    body.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      for index in 0..<size {
        bytes[index] = UInt8(truncatingIfNeeded: index / range * 31 + index % 7)
      }
    }
    let crc = body.withUnsafeBytes {
      Int(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(size)))
    }
    let start = 30 + "large.img".utf8.count
    var header = Data(original.prefix(start))
    set(&header, at: 8, value: 0, width: 2)
    set(&header, at: 14, value: crc, width: 4)
    set(&header, at: 18, value: size, width: 4)
    set(&header, at: 22, value: size, width: 4)
    var tail = Data(original.suffix(from: cd))
    set(&tail, at: 10, value: 0, width: 2)
    set(&tail, at: 16, value: crc, width: 4)
    set(&tail, at: 20, value: size, width: 4)
    set(&tail, at: 24, value: size, width: 4)
    set(&tail, at: tail.count - 22 + 16, value: start + size, width: 4)
    let source = SlowSource(
      ZIPSource(
        size: start + size + tail.count, spans: [(0, header), (start, body), (start + size, tail)]),
      delay: .milliseconds(200))
    let archive = try await IPSWArchive.open(source)
    let member = try XCTUnwrap(archive.members.first)
    // Opening read the directory at the end of the archive.
    let opening = await source.reads.count
    var delivered = Data()
    try await archive.stream(member, maximumBytes: size, maximumCompressedBytes: size) {
      delivered.append($0)
    }
    XCTAssertEqual(delivered, body)
    let mostInFlight = await source.mostInFlight
    let allReads = await source.reads
    let reads = allReads.dropFirst(opening).filter { $0.offset >= start }
    XCTAssertEqual(mostInFlight, IPSWArchive.rangesInFlight)
    XCTAssertEqual(reads.map(\.count).reduce(0, +), size, "Each body byte is read once")
    XCTAssertEqual(reads.count, 11)
    XCTAssertTrue(reads.allSatisfy { $0.count <= range })
  }

  func testWholeDirectoryAdmissionRejectsUnusedUnsafeLocalRecords() async throws {
    for change in [0, 1, 2] {
      var data = try bytes()
      let cd = try central(data)
      switch change {
      case 0: set(&data, at: cd + 38, value: 0o120777 << 16, width: 4)
      case 1: data[30] ^= 1
      default:
        set(&data, at: 6, value: 1, width: 2)
        set(&data, at: cd + 8, value: 1, width: 2)
      }
      let archive = try await IPSWArchive.open(ZIPSource(data: data))
      do {
        try await archive.validateEntries()
        XCTFail("Unsafe local record was admitted")
      } catch is RestoreFailure {}
    }
  }
}
