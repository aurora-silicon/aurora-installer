// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest

@testable import AuroraFirmware

private final class RangeServer: @unchecked Sendable {
  let fd: Int32
  let port: UInt16
  let variant: String
  let lock = NSLock()
  let workers = DispatchGroup()
  var requests: [String] = []
  var stopping = false
  var headersSent = false
  let releaseBody = DispatchSemaphore(value: 0)

  init(_ variant: String) throws {
    self.variant = variant
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    fd = descriptor
    guard descriptor >= 0 else { throw RestoreFailure("Cannot create fixture socket.") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 && listen(descriptor, 8) == 0 else {
      close(descriptor)
      throw RestoreFailure("Cannot bind fixture socket.")
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
    }
    port = UInt16(bigEndian: address.sin_port)
    workers.enter()
    DispatchQueue.global().async { [self] in
      defer { workers.leave() }
      for _ in 0..<3 {
        if lock.withLock({ stopping }) { break }
        let client = accept(fd, nil, nil)
        if client < 0 { break }
        if lock.withLock({ stopping }) {
          close(client)
          break
        }
        var enabled: Int32 = 1
        _ = setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16384 {
          let count = recv(client, &buffer, buffer.count, 0)
          if count <= 0 { break }
          request.append(contentsOf: buffer.prefix(count))
          if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        lock.withLock { requests.append(String(decoding: request, as: UTF8.self)) }
        let status = variant == "200" ? 200 : variant == "redirect" ? 302 : 206
        let body = variant == "changed" ? "fail" : variant == "length" ? "extra" : "test"
        let extent = variant == "extent" ? "bytes 0-3/20" : "bytes 7-10/20"
        let length = variant == "length" ? 5 : 4
        let extra =
          variant == "encoding"
          ? "Content-Encoding: gzip\r\n"
          : variant == "redirect" ? "Location: http://127.0.0.1:\(port)/other\r\n" : ""
        let headers =
          "HTTP/1.1 \(status) Fixture\r\nContent-Range: \(extent)\r\nContent-Length: \(length)\r\n\(extra)Connection: close\r\n\r\n"
        func sendAll(_ data: Data) {
          data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
              let count = send(
                client, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
              if count <= 0 { break }
              offset += count
            }
          }
        }
        sendAll(Data(headers.utf8))
        if variant == "slow" {
          lock.withLock { headersSent = true }
          _ = releaseBody.wait(timeout: .now() + 10)
        }
        sendAll(Data(body.utf8))
        close(client)
      }
    }
  }
  func stop() {
    lock.withLock { stopping = true }
    // Wake accept explicitly: shutting down a listening socket is not portable.
    let wake = socket(AF_INET, SOCK_STREAM, 0)
    if wake >= 0 {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      close(wake)
    }
    workers.wait()
    close(fd)
  }
  func received() -> [String] { lock.withLock { requests } }
  func responseStarted() -> Bool { lock.withLock { headersSent } }
}

/// Serves exact ranges of `image` and keeps each connection open for the
/// next request, as the restore-image CDN does.
private final class KeepAliveRangeServer: @unchecked Sendable {
  let fd: Int32
  let port: UInt16
  let image: Data
  let lock = NSLock()
  let workers = DispatchGroup()
  var accepted = 0
  var served = 0
  var stopping = false
  var clients: [Int32] = []

  init(image: Data) throws {
    self.image = image
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    fd = descriptor
    guard descriptor >= 0 else { throw RestoreFailure("Cannot create fixture socket.") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 && listen(descriptor, 16) == 0 else {
      close(descriptor)
      throw RestoreFailure("Cannot bind fixture socket.")
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
    }
    port = UInt16(bigEndian: address.sin_port)
    workers.enter()
    DispatchQueue.global().async { [self] in
      defer { workers.leave() }
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 { break }
        if lock.withLock({ stopping }) {
          close(client)
          break
        }
        lock.withLock {
          accepted += 1
          clients.append(client)
        }
        workers.enter()
        DispatchQueue.global().async { [self] in
          defer { workers.leave() }
          serve(client)
        }
      }
    }
  }

  private func serve(_ client: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(
      client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else {
        let count = recv(client, &buffer, buffer.count, 0)
        if count <= 0 { break }
        pending.append(contentsOf: buffer.prefix(count))
        continue
      }
      let head = String(decoding: pending[..<end.lowerBound], as: UTF8.self).lowercased()
      pending = Data(pending[end.upperBound...])
      guard
        let line = head.components(separatedBy: "\r\n").first(where: {
          $0.hasPrefix("range: bytes=")
        })
      else { break }
      let bounds = line.dropFirst("range: bytes=".count).split(separator: "-").compactMap {
        Int($0)
      }
      guard bounds.count == 2, bounds[0] <= bounds[1], bounds[1] < image.count else { break }
      lock.withLock { served += 1 }
      let body = image[bounds[0]...bounds[1]]
      var response = Data(
        ("HTTP/1.1 206 Fixture\r\nContent-Range: bytes \(bounds[0])-\(bounds[1])/\(image.count)"
          + "\r\nContent-Length: \(body.count)\r\n\r\n").utf8)
      response.append(body)
      let sent = response.withUnsafeBytes { bytes in
        var offset = 0
        while offset < response.count {
          let count = send(
            client, bytes.baseAddress!.advanced(by: offset), response.count - offset, 0)
          if count <= 0 { return false }
          offset += count
        }
        return true
      }
      if !sent { break }
    }
    close(client)
  }

  func stop() {
    let connected = lock.withLock {
      stopping = true
      return clients
    }
    for client in connected { shutdown(client, SHUT_RDWR) }
    let wake = socket(AF_INET, SOCK_STREAM, 0)
    if wake >= 0 {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      close(wake)
    }
    workers.wait()
    close(fd)
  }
  func connections() -> Int { lock.withLock { accepted } }
  func requests() -> Int { lock.withLock { served } }
}

final class TransportTests: XCTestCase, @unchecked Sendable {
  func testRestoreArchiveDiscoveryRequiresOneExactBoundedRange() throws {
    let url = URL(string: "https://updates.cdn-apple.com/fixture.ipsw")!
    let valid = ["Content-Range": "bytes 0-0/1073741824", "Content-Length": "1"]
    XCTAssertEqual(
      try IPSWHTTPRangeReader.discoveredSize(
        XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: valid))
      ), 1_073_741_824)
    for status in [200, 301, 302, 416] {
      XCTAssertThrowsError(
        try IPSWHTTPRangeReader.discoveredSize(
          XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: valid))))
    }
    for (key, value) in [
      ("Content-Range", "bytes 1-1/1073741824"), ("Content-Range", "bytes 0-0/*"),
      ("Content-Range", "bytes 0-0/21"), ("Content-Range", "bytes 0-0/137438953473"),
      ("Content-Range", "bytes 0-0/+100"), ("Content-Range", "bytes 0-0/100 trailing"),
      ("Content-Length", "0"), ("Content-Length", "2"), ("Content-Encoding", "gzip"),
    ] {
      var headers = valid
      headers[key] = value
      XCTAssertThrowsError(
        try IPSWHTTPRangeReader.discoveredSize(
          XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: headers))))
    }
  }
  func testFCSRedirectAdmissionAndLimit() throws {
    let path = "/fcs-keys/" + String(repeating: "a", count: 43) + "="
    let apple = try XCTUnwrap(URL(string: "https://wkms-public.apple.com" + path))
    let cdn = try XCTUnwrap(URL(string: "https://fcs-keys-pub-prod.cdn-apple.com" + path))
    let policy = RedirectPolicy(keyPath: path)
    XCTAssertTrue(policy.allows(apple))
    XCTAssertTrue(policy.allows(cdn))
    XCTAssertFalse(policy.allows(apple))
    XCTAssertFalse(RedirectPolicy(keyPath: nil).allows(apple))
    XCTAssertFalse(RedirectPolicy(keyPath: path).allows(URL(string: "https://example.org" + path)!))
    XCTAssertFalse(
      RedirectPolicy(keyPath: path).allows(
        URL(
          string: "https://wkms-public.apple.com/fcs-keys/" + String(repeating: "b", count: 43)
            + "=")!))
  }
  func testExactHTTPRangeAndRedirectRefusal() async throws {
    for variant in ["valid", "200", "extent", "length", "encoding", "changed", "redirect"] {
      let server = try RangeServer(variant)
      defer { server.stop() }
      let source = SourceRecord(
        sizeBytes: 20, sha256: Data().sha256, url: "http://127.0.0.1:\(server.port)/image")
      let record = RangeRecord(offset: 2, size: 4, sha256: Data("test".utf8).sha256)
      do {
        let result = try await fetchRange(source, record: record, base: 5)
        XCTAssertEqual(variant, "valid")
        XCTAssertEqual(result, Data("test".utf8))
      } catch { XCTAssertNotEqual(variant, "valid", "\(error)") }
      let requests = server.received()
      XCTAssertEqual(requests.count, variant == "valid" ? 1 : 3)
      for request in requests {
        XCTAssertTrue(request.hasPrefix("GET /image HTTP/1.1"))
        XCTAssertTrue(request.lowercased().contains("range: bytes=7-10\r\n"))
        XCTAssertTrue(request.lowercased().contains("accept-encoding: identity\r\n"))
      }
    }
  }
  func testRangesReuseConnectionsInsteadOfOpeningOnePerRange() async throws {
    let image = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let server = try KeepAliveRangeServer(image: image)
    defer { server.stop() }
    let source = SourceRecord(
      sizeBytes: image.count, sha256: image.sha256, url: "http://127.0.0.1:\(server.port)/image")
    for index in 0..<12 {
      let expected = Data(image[(index * 256)..<(index * 256 + 256)])
      let bytes = try await fetchRange(
        source, record: RangeRecord(offset: index * 256, size: 256, sha256: expected.sha256),
        base: 0)
      XCTAssertEqual(bytes, expected)
    }
    XCTAssertEqual(server.requests(), 12)
    // Every range used to open its own session, and so its own connection.
    XCTAssertLessThanOrEqual(server.connections(), 2)
  }

  func testCancellationDuringStreaming() async throws {
    let server = try RangeServer("slow")
    defer {
      server.releaseBody.signal()
      server.stop()
    }
    let task = Task {
      try await fetchRange(
        SourceRecord(
          sizeBytes: 20, sha256: Data().sha256, url: "http://127.0.0.1:\(server.port)/image"),
        record: RangeRecord(offset: 2, size: 4, sha256: Data("test".utf8).sha256), base: 5)
    }
    for _ in 0..<1000 {
      if server.responseStarted() { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(server.responseStarted(), "Fixture did not start streaming")
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled range returned bytes")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    XCTAssertEqual(server.received().count, 1)
  }

  func testRestoreRangeResumesAfterTransientFailuresAndStopsOnFinalOnes() async throws {
    let url = try XCTUnwrap(URL(string: "https://updates.cdn-apple.com/fixture.ipsw"))
    let image = Data((0..<64).map { UInt8($0) })
    // Each answer serves one request: a status, how many body bytes to send,
    // and the error that ends the response early, if any.
    let fixture = RangeExchangeFixture(image: image)
    fixture.answers = [
      (206, 3, URLError(.networkConnectionLost)), (503, 0, nil), (206, 2, URLError(.timedOut)),
      (206, 99, nil),
    ]
    let reader = try IPSWHTTPRangeReader(url: url, sizeBytes: 64, exchange: fixture.exchange)
    let bytes = try await reader.read(offset: 10, count: 8)
    XCTAssertEqual(bytes, image[10..<18])
    XCTAssertEqual(
      fixture.ranges, ["bytes=10-17", "bytes=13-17", "bytes=13-17", "bytes=15-17"],
      "each retry resumes after the bytes that arrived")
    XCTAssertEqual(fixture.waits, [.seconds(1), .seconds(2), .seconds(4)])

    // A connection that closes early without an error resumes as well.
    fixture.answers = [(206, 5, nil), (206, 99, nil)]
    fixture.ranges = []
    let resumed = try await reader.read(offset: 0, count: 8)
    XCTAssertEqual(resumed, image[0..<8])
    XCTAssertEqual(fixture.ranges, ["bytes=0-7", "bytes=5-7"])

    // Retrying is bounded: six attempts, then the last transient error.
    fixture.answers = Array(repeating: (206, 1, URLError(.networkConnectionLost)), count: 9)
    fixture.ranges = []
    fixture.waits = []
    do {
      _ = try await reader.read(offset: 0, count: 64)
      XCTFail("An endlessly failing range was accepted")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
      XCTAssertTrue(TransientTransport.isTransient(error))
    }
    XCTAssertEqual(fixture.ranges.count, 6)
    XCTAssertEqual(fixture.waits.count, 5)

    // A wrong answer is final: no retry.
    for answer in [(200, 99, nil), (416, 0, nil), (206, 2, URLError(.cancelled))]
      as [(Int, Int, URLError?)]
    {
      fixture.answers = [answer, (206, 99, nil)]
      fixture.ranges = []
      do {
        _ = try await reader.read(offset: 0, count: 8)
        XCTFail("A final failure was retried into success: \(answer)")
      } catch {
        XCTAssertFalse(TransientTransport.isTransient(error), "\(error)")
      }
      XCTAssertEqual(fixture.ranges.count, 1)
    }

    // Discovery retries a lost connection too.
    fixture.answers = [(206, 0, URLError(.notConnectedToInternet)), (206, 1, nil)]
    fixture.ranges = []
    let discovered = try await IPSWHTTPRangeReader.discover(url: url, exchange: fixture.exchange)
    XCTAssertEqual(discovered.sizeBytes, 64)
    XCTAssertEqual(fixture.ranges, ["bytes=0-0", "bytes=0-0"])
    XCTAssertTrue(TransientTransport.isTransient(HTTPServerError(status: 502)))
    XCTAssertFalse(TransientTransport.isTransient(RestoreFailure("final")))
  }
}

/// Answers range requests from an in-memory image, as scripted.
private final class RangeExchangeFixture: @unchecked Sendable {
  let image: Data
  var answers = [(status: Int, bytes: Int, error: URLError?)]()
  var ranges = [String]()
  var waits = [Duration]()
  init(image: Data) { self.image = image }

  var exchange: HTTPExchange {
    HTTPExchange(
      perform: { request, validate, receive in
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        self.ranges.append(range)
        let answer = self.answers.removeFirst()
        let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let start = bounds[0]
        let end = bounds[1]
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: XCTUnwrap(request.url), statusCode: answer.status, httpVersion: nil,
            headerFields: [
              "Content-Range": "bytes \(start)-\(end)/\(self.image.count)",
              "Content-Length": String(end - start + 1),
            ]))
        try validate(response)
        let body = Data(self.image[start...end].prefix(answer.bytes))
        if !body.isEmpty { try receive(body) }
        if let error = answer.error { throw error }
      },
      sleep: { self.waits.append($0) })
  }
}
