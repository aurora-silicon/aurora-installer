import Foundation
import RecoveryCompression

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// RestoreImageArchive against the archives of Fixtures/RestoreImageArchive
// (generate.py: aea.py's independent writer, disposable key), the restore
// image helper's Go reference archive (go-aea.json), and the resource fork
// layout of RestoreImageResourceFork. Each archive decodes to its plain
// image's length and SHA-256 in any input chunking, or is refused with the
// failure its fixture names; a refused archive's last handed-on byte is
// never past a verified segment. With AURORA_TEST_LZFSE=none (the Linux
// run without the Go decoder) archives that need an LZFSE decoder are
// skipped and counted.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }

  static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  static let fixtures = here.appendingPathComponent("Fixtures/RestoreImageArchive")
  static let profiles: [String: RestoreImageArchive.Profile] = [
    "restore": .restoreImage, "small": .init(segmentBytes: 1024, clusterWidth: 4),
  ]

  static func hex(_ text: String) -> Data {
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      out.append(UInt8(text[index..<next], radix: 16)!)
      index = next
    }
    return out
  }

  /// Decodes `archive` fed in `chunk`-byte pieces; the plain image's
  /// identity, or the error, and the pieces handed on.
  static func decode(
    _ archive: Data, key: Data, profile: RestoreImageArchive.Profile, chunk: Int,
    archiveSize: Int? = nil, maximumOutput: Int = RestoreImageDirectory.maximumMember,
    feed: Int? = nil
  ) -> (Result<(bytes: Int, sha256: String), Error>, [Int]) {
    var pieces = [Int]()
    var hash = RecoveryDigest.Stream()
    let result = Result { () -> (bytes: Int, sha256: String) in
      let decoder = try RestoreImageArchive.Decoder(
        archiveKey: key, archiveSize: archiveSize ?? archive.count,
        maximumOutput: maximumOutput, profile: profile)
      let end = feed ?? archive.count
      var at = 0
      while at < end {
        let next = min(at + chunk, end)
        try decoder.consume(archive.subdata(in: at..<next)) {
          pieces.append($0.count)
          hash.update($0)
        }
        at = next
      }
      let identity = try decoder.finish()
      expect(identity.sha256 == hash.finish(), "finish's SHA-256 is the handed-on bytes'")
      expect(decoder.plainSize == identity.bytes, "plainSize")
      return identity
    }
    return (result, pieces)
  }

  static func failure(_ error: Error) -> String {
    guard let failure = error as? RestoreImageArchive.Failure else { return "\(error)" }
    return "\(failure)"
  }

  static func main() throws {
    let noDecoder = ProcessInfo.processInfo.environment["AURORA_TEST_LZFSE"] == "none"
    let expected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
      as! [String: [String: Any]]
    var decoded = 0
    var refused = 0
    var skipped = 0
    for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
      if noDecoder && value["lzfse"] as! Bool {
        skipped += 1
        continue
      }
      let archive = try Data(contentsOf: fixtures.appendingPathComponent(name + ".aea"))
      let key = hex(value["key"] as! String)
      let profile = profiles[value["profile"] as! String]!
      let want = value["expect"] as! String
      for chunk in [1, 7, 1000, 4096, 1 << 20] {
        let (result, pieces) = decode(archive, key: key, profile: profile, chunk: chunk)
        // Nothing larger than one segment is ever handed on.
        expect(
          pieces.allSatisfy { $0 > 0 && $0 <= profile.segmentBytes },
          "\(name) at \(chunk): pieces \(pieces.max() ?? 0)")
        switch (result, want) {
        case (.success(let identity), "ok"):
          expect(
            identity.bytes == value["bytes"] as! Int
              && identity.sha256 == value["sha256"] as! String,
            "\(name) at \(chunk): \(identity)")
          // Every piece but the last is a whole segment.
          expect(
            pieces.dropLast().allSatisfy { $0 == profile.segmentBytes },
            "\(name) at \(chunk): segment pieces")
        case (.failure(let error), let want) where want != "ok":
          expect(failure(error) == want, "\(name) at \(chunk): \(error), want \(want)")
          // Only whole segments, each verified, were handed on before the
          // refusal; one in the header or the root hands on none.
          let early =
            ["root", "salt", "metadata", "first", "wrong", "profile"].contains {
              name.hasPrefix($0)
            } && name != "root-plain-size"
          expect(
            pieces.dropLast().allSatisfy { $0 == profile.segmentBytes }
              && (!early || pieces.isEmpty),
            "\(name) at \(chunk): \(pieces.count) pieces before the refusal")
        default:
          expect(false, "\(name) at \(chunk): \(result), want \(want)")
        }
      }
      if want == "ok" {
        decoded += 1
        let plain = value["bytes"] as! Int
        // The archive cut short, declared longer or shorter, a byte too many,
        // and a plain image larger than the caller admits.
        for (what, size, feed, limit) in [
          ("cut short", archive.count, archive.count - 1, plain),
          ("declared longer", archive.count + 1, archive.count, plain),
          ("declared shorter", archive.count - 1, archive.count - 1, plain),
          ("over the output limit", archive.count, archive.count, plain - 1),
        ] where limit > 0 {
          let (result, _) = decode(
            archive, key: key, profile: profile, chunk: 4096, archiveSize: size,
            maximumOutput: limit, feed: feed)
          if case .failure(let error) = result {
            expect(failure(error) == "invalidArchive", "\(name) \(what): \(error)")
          } else {
            expect(false, "\(name) \(what): decoded")
          }
        }
        do {
          let decoder = try RestoreImageArchive.Decoder(
            archiveKey: key, archiveSize: archive.count, profile: profile)
          try decoder.consume(archive) { _ in }
          var more = false
          do { try decoder.consume(Data([0])) { _ in } } catch { more = true }
          expect(more, "\(name): a byte past the archive is refused")
        } catch {
          expect(false, "\(name): \(error)")
        }
        // The public entry point takes the restore image's profile only.
        if value["profile"] as! String == "restore" {
          let length = try RestoreImageArchive.prefixLength(archive.prefix(12))
          let prefix = archive.prefix(length)
          expect(
            (try? RestoreImageArchive.plainSize(prefix, archiveKey: key, archiveSize: archive.count))
              == plain, "\(name): plainSize")
          let wrong = Data(key.map { $0 ^ 1 })
          expect(
            (try? RestoreImageArchive.plainSize(
              prefix, archiveKey: wrong, archiveSize: archive.count)) == nil,
            "\(name): plainSize under another key")
          let decoder = try RestoreImageArchive.Decoder(
            archiveKey: key, archiveSize: archive.count)
          var hash = RecoveryDigest.Stream()
          try decoder.consume(archive) { hash.update($0) }
          expect(
            try decoder.finish().sha256 == value["sha256"] as! String
              && hash.finish() == value["sha256"] as! String, "\(name): public decoder")
        } else {
          let small = try? RestoreImageArchive.Decoder(
            archiveKey: key, archiveSize: archive.count)
          var refusedProfile = false
          do { try small?.consume(archive) { _ in } } catch { refusedProfile = true }
          expect(refusedProfile, "\(name): the public decoder refuses a small profile")
        }
      } else {
        refused += 1
      }
    }
    expect(decoded >= 4 && refused >= 25, "cases: \(decoded) decoded, \(refused) refused")
    for size in [0, 16, 33] {
      expect(
        (try? RestoreImageArchive.Decoder(archiveKey: Data(count: size), archiveSize: 100)) == nil
          || size == 32, "a \(size)-byte key is refused")
    }

    // The restore image helper's Go reference archive (one LZFSE segment).
    if !noDecoder {
      let go = here.appendingPathComponent(
        "../../RestoreImage/Tests/RestoreImageCoreTests/Fixtures/go-aea.json")
      let json = try JSONSerialization.jsonObject(with: Data(contentsOf: go)) as! [String: Any]
      var archive = Data()
      for record in (json["records"] as! [[String: Any]]).sorted(by: {
        (($0["record"] as! [String: Any])["offset"] as! Int)
          < (($1["record"] as! [String: Any])["offset"] as! Int)
      }) {
        let offset = (record["record"] as! [String: Any])["offset"] as! Int
        expect(offset == archive.count, "go-aea records are contiguous")
        archive += Data(base64Encoded: record["data"] as! String)!
      }
      let plain = Data(base64Encoded: json["plain"] as! String)!
      let (result, _) = decode(
        archive, key: Data(base64Encoded: json["key"] as! String)!, profile: .restoreImage,
        chunk: 4096)
      expect(
        (try? result.get())?.sha256 == RecoveryDigest.sha256(plain),
        "the Go reference archive: \(result)")
    } else {
      skipped += 1
    }

    // The stream walk ahead of the decoder.
    func raw(_ bytes: [UInt8]) -> [UInt8] {
      Array("bvx-".utf8) + (0..<4).map { UInt8(truncatingIfNeeded: bytes.count >> (8 * $0)) }
        + bytes
    }
    let end = Array("bvx$".utf8)
    let body = [UInt8](repeating: 0x41, count: 300)
    let walks: [(String, [UInt8], Int, Bool)] = [
      ("one stored block", raw(body) + end, 300, true),
      ("two stored blocks", raw(Array(body[0..<100])) + raw(Array(body[100...])) + end, 300, true),
      ("more than declared", raw(body) + end, 299, false),
      ("less than declared", raw(body) + end, 301, false),
      ("bytes after the end", raw(body) + end + [0], 300, false),
      ("no end", raw(body), 300, false),
      ("a block past the input", Array(raw(body).dropLast()) + end, 300, false),
      ("an unknown block", Array("bvx9".utf8) + [44, 1, 0, 0] + body + end, 300, false),
      ("a short v2 header", Array("bvx2".utf8) + [UInt8](repeating: 0, count: 20), 0, false),
      ("empty", [], 300, false),
    ]
    for (what, stream, size, admitted) in walks {
      let out = try? RestoreImageArchive.boundedLZFSE(stream, maximum: size)
      expect((out != nil) == admitted, "LZFSE walk, \(what)")
      if let out { expect(out == body, "LZFSE walk, \(what): bytes") }
    }

    // The decmpfs type 12 resource fork: a table of block offsets, then
    // 64 KiB blocks that each decode to the file's bytes.
    for size in [0, 1, 65535, 65536, 65537, 3 * 65536 + 17] {
      var r = UInt64(size) &* 0x9e37_79b9_7f4a_7c15 | 1
      let plain = (0..<size).map { i -> UInt8 in
        r = r &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return i % 3 == 0 ? UInt8(truncatingIfNeeded: r >> 59) : 0x20
      }
      var fork = [UInt8]()
      let writer = try RestoreImageResourceFork(bytes: size) { data, offset in
        if fork.count < offset + data.count {
          fork += [UInt8](repeating: 0, count: offset + data.count - fork.count)
        }
        fork.replaceSubrange(offset..<(offset + data.count), with: data)
      }
      var at = 0
      for piece in [1, 4000, 70000] where at < size {
        let next = min(size, at + piece)
        try writer.append(Data(plain[at..<next]))
        at = next
      }
      if at < size { try writer.append(Data(plain[at...])) }
      expect((try? writer.append(Data([0]))) == nil, "fork \(size): a byte too many")
      try writer.finish()
      let blocks = (size + 65535) / 65536
      func u32(_ at: Int) -> Int { fork[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | Int($1) } }
      let offsets = (0...blocks).map { u32($0 * 4) }
      expect(offsets.first == (blocks + 1) * 4 && offsets.last == fork.count, "fork \(size): table")
      var rebuilt = [UInt8]()
      for index in 0..<blocks {
        let chunk = Array(fork[offsets[index]..<offsets[index + 1]])
        var out = [UInt8](repeating: 0, count: 65537)
        let count = chunk.withUnsafeBufferPointer { s in
          out.withUnsafeMutableBufferPointer { t in
            aurora_lzfse_decode(t.baseAddress!, t.count, s.baseAddress!, s.count)
          }
        }
        expect(count == min(65536, size - index * 65536), "fork \(size): block \(index) length")
        rebuilt += out.prefix(count)
      }
      expect(rebuilt == plain, "fork \(size): bytes")
      let attribute = [UInt8](RestoreImageResourceFork.attribute(bytes: size))
      expect(
        attribute.count == 16 && attribute[0..<8] == [0x66, 0x70, 0x6d, 0x63, 12, 0, 0, 0]
          && attribute[8..<16].reversed().reduce(0) { $0 << 8 | Int($1) } == size,
        "fork \(size): decmpfs header")
    }

    if failures > 0 {
      print("RestoreImageArchive: \(failures) failures")
      exit(1)
    }
    print(
      "RestoreImageArchive: \(decoded) archives decoded, \(refused) refused as expected"
        + (skipped > 0 ? ", \(skipped) skipped without an LZFSE decoder" : "") + ", forks OK")
  }
}
