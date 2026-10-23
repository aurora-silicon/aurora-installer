// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import XCTest

@testable import RestoreImageCore

final class RestoreImageTests: XCTestCase, @unchecked Sendable {
  func fixture(_ name: String) throws -> Data {
    try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
  }
  func vectors() throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: fixture("go-vectors"))
  }
  func bytes(_ values: [String: String], _ key: String) throws -> Data {
    try XCTUnwrap(Data(base64Encoded: XCTUnwrap(values[key])))
  }
  func temporary() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: path) }
    return path
  }
  func testGoCryptoVectors() throws {
    let v = try vectors()
    let key = try bytes(v, "key")
    let material = try bytes(v, "material")
    let plain = try bytes(v, "plain")
    let ciphertext = try bytes(v, "ciphertext")
    let response = try JSONSerialization.data(withJSONObject: [
      "enc-request": v["enc"]!, "wrapped-key": v["wrapped"]!,
    ])
    let md = ["com.apple.wkms.fcs-response": response]
    XCTAssertEqual(try unwrap(md, releaseKey: Data(v["pem"]!.utf8)), key)
    var changed = try bytes(v, "wrapped")
    changed[0] ^= 1
    let forged = try JSONSerialization.data(withJSONObject: [
      "enc-request": v["enc"]!, "wrapped-key": changed.base64EncodedString(),
    ])
    XCTAssertThrowsError(
      try unwrap(["com.apple.wkms.fcs-response": forged], releaseKey: Data(v["pem"]!.utf8)))
    XCTAssertEqual(try ctr(material, data: ciphertext), plain)
    XCTAssertEqual(
      derive(key, salt: Data("salt".utf8), info: Data("AEA_RHEK".utf8), size: 80),
      try bytes(v, "hkdf"))
    let mac = try unhex(v["mac"]!)
    try authenticate(material, data: ciphertext, salt: Data("metadata".utf8), expected: mac)
    XCTAssertThrowsError(
      try authenticate(material, data: plain, salt: Data("metadata".utf8), expected: mac))
    XCTAssertThrowsError(try authenticate(material, data: ciphertext, expected: mac))
  }
  func testMetadataBoundsAndAmbiguity() throws {
    func archive(_ entries: [Data]) -> Data {
      let body = entries.reduce(Data()) { $0 + littleBytes($1.count + 4, count: 4) + $1 }
      return Data("AEA1".utf8) + littleBytes(1, count: 4) + littleBytes(body.count, count: 4) + body
    }
    let valid = archive([Data("key\0value".utf8)])
    XCTAssertEqual(try metadata(valid)["key"], Data("value".utf8))
    for data in [
      Data(valid.prefix(5)), Data(valid.dropLast()),
      archive([Data("key\0one".utf8), Data("key\0two".utf8)]), archive([Data("unterminated".utf8)]),
    ] {
      XCTAssertThrowsError(try metadata(data))
    }
    var oversized = valid
    oversized.replaceSubrange(8..<12, with: littleBytes(1_048_577, count: 4))
    XCTAssertThrowsError(try metadata(oversized))
    var badEntry = valid
    badEntry.replaceSubrange(12..<16, with: littleBytes(3, count: 4))
    XCTAssertThrowsError(try metadata(badEntry))
  }
  func testAppleURLAdmission() throws {
    let suffix = "/fcs-keys/" + String(repeating: "a", count: 43) + "="
    for host in ["wkms-public.apple.com", "fcs-keys-pub-prod.cdn-apple.com"] {
      _ = try keyURL("https://" + host + suffix)
    }
    for url in [
      "http://wkms-public.apple.com" + suffix, "https://wkms-public.apple.com:443" + suffix,
      "https://user@wkms-public.apple.com" + suffix,
      "https://wkms-public.apple.com.evil.invalid" + suffix,
      "https://wkms-public.apple.com" + suffix + "?x=1",
      "https://wkms-public.apple.com" + suffix + "#fragment",
      "https://wkms-public.apple.com" + suffix + "\n",
      "https://wkms-public.apple.com/fcs-keys/../secret",
      "https://wkms-public.apple.com/fcs-keys/%61" + suffix,
    ] {
      XCTAssertThrowsError(try keyURL(url))
    }
    XCTAssertTrue(appleRangeURL("https://updates.cdn-apple.com/restore.ipsw"))
    for url in [
      "http://updates.cdn-apple.com/a", "https://updates.cdn-apple.com:443/a",
      "https://updates.cdn-apple.com/a?x", "https://evil.invalid/a",
    ] {
      XCTAssertFalse(appleRangeURL(url))
    }
  }
  func testRecipeAdmission() throws {
    let data = try fixture("j700-25G83-ranges")
    let recipe = try strictRecipe(data)
    let path = try temporary().appendingPathComponent("recipe.json")
    try data.write(to: path)
    _ = try readRecipe(path, digest: data.sha256)
    XCTAssertThrowsError(try readRecipe(path, digest: Data("changed".utf8).sha256))
    let mutations: [(inout RangeRecipe) -> Void] = [
      { $0.files[0].name = "../escape" }, { $0.files.append($0.files[0]) },
      { $0.source.url = "https://example.org/archive" },
      { $0.segments.removeValue(forKey: $0.segments.keys.first!) },
      { $0.files[0].size = maxFileBytes + 1 },
      { $0.files[0].storage[0].spans[0].offset = $0.systemImage.decoded.sizeBytes },
      { $0.source.sizeBytes = Int.max }, { $0.prefix.size = Int.max },
      { $0.headers[0].cluster = Int.max },
      { $0.segments["9223372036854775807"] = $0.segments.values.first! },
    ]
    for mutate in mutations {
      var changed = recipe
      mutate(&changed)
      XCTAssertThrowsError(try changed.validate())
    }
    var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    extra["unknown"] = 1
    XCTAssertThrowsError(try strictRecipe(JSONSerialization.data(withJSONObject: extra)))
    XCTAssertThrowsError(try strictRecipe(data + Data("{}".utf8)))
  }
  func testGoCompressionVectorsAndAPFSTypes() throws {
    let v = try vectors()
    let plain = try bytes(v, "plain")
    let compressed = try bytes(v, "lzfse")
    XCTAssertEqual(try boundedLZFSE(compressed, maximum: plain.count), plain)
    XCTAssertThrowsError(try boundedLZFSE(compressed, maximum: 1))
    XCTAssertThrowsError(try boundedLZFSE(Data(compressed.dropLast()), maximum: plain.count))
    for kind in [3, 4, 7, 8, 11, 12] {
      let attr =
        Data("fpmc".utf8) + littleBytes(kind, count: 4) + littleBytes(plain.count, count: 8)
      let block = try bytes(v, kind <= 4 ? "zlib" : kind <= 8 ? "lzvn" : "lzfse")
      let storage: [Data]
      if kind % 2 == 1 {
        storage = [attr + block]
      } else if kind == 4 {
        var fork = Data(count: 272)
        fork.replaceSubrange(0..<4, with: Data([0, 0, 1, 0]))
        fork.replaceSubrange(260..<264, with: littleBytes(1, count: 4))
        fork.replaceSubrange(264..<268, with: littleBytes(12, count: 4))
        fork.replaceSubrange(268..<272, with: littleBytes(block.count, count: 4))
        storage = [attr, fork + block]
      } else {
        storage = [attr, littleBytes(8, count: 4) + littleBytes(8 + block.count, count: 4) + block]
      }
      XCTAssertEqual(try decompressStorage(storage), plain, "APFS type \(kind)")
      var tooBig = storage
      tooBig[0].replaceSubrange(8..<16, with: littleBytes(maxFileBytes + 1, count: 8))
      XCTAssertThrowsError(try decompressStorage(tooBig))
      if kind % 2 == 0 {
        var malformed = storage
        malformed[1].replaceSubrange(0..<4, with: littleBytes(Int(UInt32.max), count: 4))
        XCTAssertThrowsError(try decompressStorage(malformed))
      }
      let sentinel: UInt8 = kind <= 4 ? 0xff : kind <= 8 ? 6 : 0
      if kind % 2 == 1 {
        XCTAssertEqual(try decompressStorage([attr + Data([sentinel]) + plain]), plain)
      }
    }
    XCTAssertThrowsError(try decompressStorage([]))
  }
  func testAPFSLZVNPaddingAndInstructionBoundaries() throws {
    let v = try vectors()
    let plain = try bytes(v, "plain")
    let compressed = try bytes(v, "lzvn")
    let padded = compressed + Data(repeating: 0xa5, count: 34)
    XCTAssertEqual(try lzvnPayload(padded, expected: plain.count), compressed)
    for kind in [7, 8] {
      let attr =
        Data("fpmc".utf8) + littleBytes(kind, count: 4) + littleBytes(plain.count, count: 8)
      let storage =
        kind == 7
        ? [attr + padded]
        : [attr, littleBytes(8, count: 4) + littleBytes(8 + padded.count, count: 4) + padded]
      XCTAssertEqual(try decompressStorage(storage), plain)
    }
    // An EOS-shaped sequence inside literal data must not terminate parsing.
    let literal = Data([6, 0, 0, 0, 0, 0, 0, 0])
    let encoded = Data([0xe8]) + literal + Data([6, 0, 0, 0, 0, 0, 0, 0])
    XCTAssertEqual(try lzvnPayload(encoded + Data([0xa5]), expected: 8), encoded)
    let attr = Data("fpmc".utf8) + littleBytes(7, count: 4) + littleBytes(8, count: 8)
    XCTAssertEqual(try decompressStorage([attr + encoded + Data([0xa5])]), literal)
    for malformed in [
      Data([6]), Data([0xe0]), Data([0xe2, 65]), Data([0x07, 1]), Data([0xf1]), Data([0x00, 0]),
    ] {
      XCTAssertThrowsError(try lzvnPayload(malformed, expected: 8))
    }
    XCTAssertThrowsError(try lzvnPayload(encoded, expected: 7))
    XCTAssertThrowsError(try lzvnPayload(encoded, expected: 9))
    XCTAssertThrowsError(try lzvnPayload(Data(encoded.dropLast()), expected: 8))
  }

  struct AEAFixture: Decodable {
    struct Record: Decodable {
      let record: RangeRecord
      let data: Data
    }
    let recipe: RangeRecipe
    let key: Data
    let plain: Data
    let records: [Record]
  }
  func testGoAuthenticatedAEAAndAtomicPublication() throws {
    let f = try JSONDecoder().decode(AEAFixture.self, from: fixture("go-aea"))
    try f.recipe.validate()
    let fetched = Dictionary(uniqueKeysWithValues: f.records.map { ($0.record, $0.data) })
    let decoded = try decodeRanges(f.recipe, fetched: fetched, archiveKey: f.key)
    XCTAssertEqual(decoded[0], f.plain)
    for record in f.records {
      var changed = fetched
      changed[record.record]![record.record == f.recipe.prefix ? record.data.count - 1 : 0] ^= 1
      XCTAssertThrowsError(try decodeRanges(f.recipe, fetched: changed, archiveKey: f.key))
    }
    let parent = try temporary()
    let output = parent.appendingPathComponent("firmware")
    var wrong = f.recipe
    wrong.files[0].sha256 = Data("bad".utf8).sha256
    XCTAssertThrowsError(try assembleRangeFiles(wrong, decoded: decoded, output: output))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    try assembleRangeFiles(f.recipe, decoded: decoded, output: output)
    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("test.bin")), f.plain)
    XCTAssertThrowsError(try assembleRangeFiles(f.recipe, decoded: decoded, output: output))
  }
  func testStage1IdentityAndAlignment() throws {
    let parent = try temporary()
    let path = parent.appendingPathComponent("boot.bin")
    let data = Data(repeating: 42, count: 16384)
    try data.write(to: path)
    try verifyStage1(path, digest: data.sha256, size: "16384")
    for size in ["16383", "32768", "0", "-1"] {
      XCTAssertThrowsError(try verifyStage1(path, digest: data.sha256, size: size))
    }
    XCTAssertThrowsError(try verifyStage1(path, digest: Data().sha256, size: "16384"))
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    XCTAssertThrowsError(try verifyStage1(link, digest: data.sha256, size: "16384"))
  }
  func testAdmissionAndLocalFailuresAreNotFallback() async throws {
    let parent = try temporary()
    let path = parent.appendingPathComponent("recipe.json")
    try Data("{}".utf8).write(to: path)
    do {
      try await extractFirmwareRanges(
        path, digest: Data("{}".utf8).sha256, output: parent.appendingPathComponent("out"))
      XCTFail("Invalid recipe admitted")
    } catch { XCTAssertFalse((error as? RestoreFailure)?.fallback ?? false) }
    do {
      try await withDeadline(seconds: 0) { try await Task.sleep(for: .seconds(20)) }
      XCTFail("Deadline ignored")
    } catch { XCTAssertTrue(error is CancellationError) }
  }
}
