// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest

@testable import RestoreImageCore

private final class RangeServer: @unchecked Sendable {
  let fd: Int32
  let port: UInt16
  let variant: String
  let lock = NSLock()
  let workers = DispatchGroup()
  var requests: [String] = []
  var stopping = false

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
        if variant == "slow" { Thread.sleep(forTimeInterval: 2) }
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
}

final class TransportTests: XCTestCase, @unchecked Sendable {
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
  func testCancellationDuringStreaming() async throws {
    let server = try RangeServer("slow")
    defer { server.stop() }
    let task = Task {
      try await fetchRange(
        SourceRecord(
          sizeBytes: 20, sha256: Data().sha256, url: "http://127.0.0.1:\(server.port)/image"),
        record: RangeRecord(offset: 2, size: 4, sha256: Data("test".utf8).sha256), base: 5)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled range returned bytes")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    XCTAssertEqual(server.received().count, 1)
  }
}
