import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

// RestoreImageRemote without a network: a fake transport serves
// Fixtures/RestoreImageMember/classic.zip by ranges and the release key of
// Fixtures/RestoreImageKey (cli.py: cli-archive.bin wraps 32 bytes of '*'
// for cli-release-key.pem). Ranges come back exactly, from one file (ETag),
// and nothing else is accepted; only Apple's update CDN and FCS key hosts are
// asked; the archive key unwraps and opens the archive's root header, one
// fetch per key URL.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }

  static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  static let keys = here.appendingPathComponent("Fixtures/RestoreImageKey")

  /// A server of `file` by ranges; `tamper` changes its answers.
  final class Server {
    let file: Data
    var requests = [URLRequest]()
    var tamper: (inout (status: Int, headers: [String: String], body: Data)) -> Void = { _ in }
    init(_ file: Data) { self.file = file }
    func transport(_ request: URLRequest, _ limit: Int) throws -> (
      status: Int, headers: [String: String], body: Data
    ) {
      requests.append(request)
      guard let range = request.value(forHTTPHeaderField: "Range"),
        range.hasPrefix("bytes=")
      else { return (200, ["ETag": "\"one\""], file.prefix(limit + 1)) }
      let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
      let first = bounds[0]
      let last = min(bounds[1], file.count - 1)
      var answer = (
        status: 206,
        headers: ["Content-Range": "bytes \(first)-\(last)/\(file.count)", "ETag": "\"one\""],
        body: file.subdata(in: first..<(last + 1)).prefix(limit + 1)
      )
      if let tag = request.value(forHTTPHeaderField: "If-Match"), tag != "\"one\"" {
        answer = (412, [:], Data())
      }
      tamper(&answer)
      return answer
    }
  }

  static func failure<T>(_ body: () throws -> T) -> Error? {
    do {
      _ = try body()
      return nil
    } catch { return error }
  }

  static func main() throws {
    let zip = try Data(
      contentsOf: here.appendingPathComponent("Fixtures/RestoreImageMember/classic.zip"))
    let url = URL(string: "https://updates.cdn-apple.com/2026/fixture/classic.zip")!

    // Ranges of the image, exactly.
    let server = Server(zip)
    let (size, read) = try RestoreImageRemote.image(url, transport: server.transport)
    expect(size == zip.count, "size \(size)")
    for (offset, count) in [(0, 1), (7, 100), (zip.count - 10, 10), (5, 0)] {
      expect(
        (try? read(offset, count)) == zip.subdata(in: offset..<(offset + count)),
        "range \(offset)+\(count)")
    }
    expect(
      server.requests.dropFirst().allSatisfy {
        $0.value(forHTTPHeaderField: "If-Match") == "\"one\""
      },
      "every read is bound to the first one's ETag")
    expect(
      (try? RestoreImageDirectory.read(archiveSize: size, read: read)) != nil,
      "the ZIP directory reads over ranges")

    // Answers that aren't exactly the range asked for are refused.
    let tampers: [(String, (inout (status: Int, headers: [String: String], body: Data)) -> Void)] =
      [
        ("a 200", { $0.status = 200 }),
        ("a short body", { $0.body = $0.body.dropLast() }),
        ("a long body", { $0.body.append(0) }),
        ("another range", { $0.headers["Content-Range"] = "bytes 1-1/\(zip.count)" }),
        ("another size", { $0.headers["Content-Range"] = "bytes 7-106/\(zip.count + 1)" }),
        ("another ETag", { $0.headers["ETag"] = "\"two\"" }),
        ("no Content-Range", { $0.headers.removeValue(forKey: "Content-Range") }),
      ]
    for (what, change) in tampers {
      server.tamper = change
      expect(
        failure({ try read(7, 100) }) is RestoreImageRemote.Failure, "\(what) refused")
    }
    server.tamper = { _ in }
    for refused in [
      "http://updates.cdn-apple.com/a.zip", "https://updates.cdn-apple.com.evil.example/a.zip",
      "https://example.com/a.zip", "https://updates.cdn-apple.com:444/a.zip",
      "https://updates.cdn-apple.com/a.zip?x=1", "https://user@updates.cdn-apple.com/a.zip",
    ] {
      let before = server.requests.count
      expect(
        failure({ try RestoreImageRemote.image(URL(string: refused)!, transport: server.transport) }
        )
          as? RestoreImageRemote.Failure == .refusedURL,
        "\(refused) refused")
      expect(server.requests.count == before, "\(refused) never asked")
    }

    // The release key: fetched from the archive's key URL, unwrapped, and
    // checked against the archive's root header.
    let head = try Data(contentsOf: keys.appendingPathComponent("cli-archive.bin"))
    let pem = try Data(contentsOf: keys.appendingPathComponent("cli-release-key.pem"))
    let metadata = try RestoreImageKey.metadata(head)
    let keyURL = try RestoreImageKey.keyURL(metadata)
    let fcs = Server(pem)
    let archiveKeys = RestoreImageRemote.ArchiveKeys(transport: fcs.transport)
    let entry = RestoreImageDirectory.Entry(
      name: "fixture.aea", compressedSize: head.count, size: head.count, method: 0,
      localHeader: 0, crc32: 0, flags: 0, mode: 0o100644, isDirectory: false)
    let key = try archiveKeys.key(entry, metadata: metadata, head: head)
    expect(key == Data(repeating: 0x2a, count: 32), "the archive key")
    _ = try archiveKeys.key(entry, metadata: metadata)
    expect(fcs.requests.count == 1 && archiveKeys.fetched == [keyURL], "one fetch per key URL")
    expect(fcs.requests.first?.url == keyURL, "fetched from the key URL")
    expect(
      fcs.requests.first?.value(forHTTPHeaderField: "Range") == nil, "the key is fetched whole")
    // A key that doesn't open this archive's root header is refused.
    var flipped = head
    flipped[flipped.count - 1] ^= 1
    expect(
      failure({
        try RestoreImageRemote.ArchiveKeys(transport: fcs.transport).key(
          entry, metadata: metadata, head: flipped)
      }) as? RestoreImageKey.Failure == .authentication,
      "a root header the key doesn't open")
    for (what, change) in [
      (
        "HTTP 404",
        { (answer: inout (status: Int, headers: [String: String], body: Data)) in
          answer.status = 404
        }
      ),
      ("an empty key", { $0.body = Data() }),
      ("a key past 16 KiB", { $0.body = Data(repeating: 0x41, count: 16385) }),
    ] as [(String, (inout (status: Int, headers: [String: String], body: Data)) -> Void)] {
      let bad = Server(pem)
      bad.tamper = { answer in
        answer.status = 200
        change(&answer)
      }
      // Answer a whole GET (the key) through the same tamper.
      let transport: RestoreImageRemote.Transport = { request, limit in
        var answer = (status: 200, headers: [String: String](), body: pem.prefix(limit + 1))
        bad.tamper(&answer)
        return answer
      }
      expect(
        failure({
          try RestoreImageRemote.ArchiveKeys(transport: transport).key(entry, metadata: metadata)
        })
          is RestoreImageRemote.Failure, "\(what) refused")
    }
    // Redirects: at most two, each to an admitted key URL with the same path.
    let keyPath = keyURL.path
    let cdn = URL(string: "https://fcs-keys-pub-prod.cdn-apple.com" + keyPath)!
    func redirecting(_ hops: [String]) -> (RestoreImageRemote.Transport, () -> [URL]) {
      var asked = [URL]()
      let transport: RestoreImageRemote.Transport = { request, limit in
        asked.append(request.url!)
        if asked.count <= hops.count {
          return (301, ["Location": hops[asked.count - 1]], Data())
        }
        return (200, [:], pem.prefix(limit + 1))
      }
      return (transport, { asked })
    }
    do {
      let (transport, asked) = redirecting([cdn.absoluteString])
      let key = try? RestoreImageRemote.ArchiveKeys(transport: transport).key(
        entry, metadata: metadata, head: head)
      expect(key == Data(repeating: 0x2a, count: 32), "a redirect to Apple's key CDN is followed")
      expect(asked() == [keyURL, cdn], "asked \(asked())")
    }
    for (what, hops) in [
      ("another host", ["https://evil.example" + keyPath]),
      (
        "another path",
        [
          "https://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        ]
      ),
      ("plain HTTP", ["http://fcs-keys-pub-prod.cdn-apple.com" + keyPath]),
      ("no Location", [""]),
      ("three redirects", [cdn.absoluteString, keyURL.absoluteString, cdn.absoluteString]),
    ] {
      let (transport, asked) = redirecting(hops)
      expect(
        failure({ try RestoreImageRemote.releaseKey(keyURL, transport: transport) })
          is RestoreImageRemote.Failure, "a redirect to \(what) refused")
      expect(asked().count <= 3, "\(what): at most three requests")
    }

    for refused in [
      "https://evil.example/fcs-keys/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "http://wkms-public.apple.com/fcs-keys/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "https://wkms-public.apple.com/fcs-keys/AAAA=",
    ] {
      var other = metadata
      other["com.apple.wkms.fcs-key-url"] = Data(refused.utf8)
      let count = fcs.requests.count
      expect(
        failure({
          try RestoreImageRemote.ArchiveKeys(transport: fcs.transport).key(entry, metadata: other)
        })
          != nil && fcs.requests.count == count, "\(refused) never fetched")
      expect(
        failure({
          try RestoreImageRemote.releaseKey(URL(string: refused)!, transport: fcs.transport)
        })
          != nil && fcs.requests.count == count, "\(refused) never fetched directly")
    }

    if failures > 0 {
      print("RestoreImageRemote: \(failures) failures")
      exit(1)
    }
    print("RestoreImageRemote: ranges, refusals and archive keys OK")
  }
}
