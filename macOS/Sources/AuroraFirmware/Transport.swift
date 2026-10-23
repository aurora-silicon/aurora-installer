// SPDX-License-Identifier: MIT
import Foundation

func keyURL(_ raw: String) throws -> URL {
  let pattern =
    #"^https://(wkms-public\.apple\.com|fcs-keys-pub-prod\.cdn-apple\.com)/fcs-keys/[A-Za-z0-9_-]{43}=\z"#
  try require(
    raw.range(of: pattern, options: .regularExpression) != nil,
    "FCS URL is outside Apple's public service.")
  guard let url = URL(string: raw) else { throw RestoreFailure("Invalid FCS URL.") }
  return url
}
func appleRangeURL(_ raw: String) -> Bool {
  guard raw.hasPrefix("https://updates.cdn-apple.com/"), let u = URLComponents(string: raw) else {
    return false
  }
  return u.scheme == "https" && u.host == "updates.cdn-apple.com" && u.port == nil
    && u.user == nil && u.password == nil && u.query == nil && u.fragment == nil
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let keyPath: String?
  private let lock = NSLock()
  private var redirects = 0
  init(keyPath: String?) { self.keyPath = keyPath }
  func allows(_ url: URL) -> Bool {
    lock.withLock {
      guard let keyPath, redirects < 2, url.path == keyPath,
        (try? keyURL(url.absoluteString)) != nil
      else { return false }
      redirects += 1
      return true
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url, allows(url) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

func httpBytes(
  _ request: URLRequest, maximum: Int, keyPath: String? = nil,
  validate: (HTTPURLResponse) throws -> Void
) async throws -> Data {
  var data = Data()
  data.reserveCapacity(maximum)
  try await httpStream(request, keyPath: keyPath, validate: validate) { chunk in
    try require(chunk.count <= maximum - data.count, "HTTP response exceeds its admitted length.")
    data.append(chunk)
  }
  return data
}

/// One long-lived session carries every request, so consecutive and
/// concurrent ranges reuse its connections instead of paying a TCP and TLS
/// handshake, and a fresh TCP slow start, for every range. Each request
/// brings its own redirect rules as its task delegate. A request still times
/// out after its own `timeoutInterval` without data; the whole transfer may
/// take longer, since ranges in flight together share the link.
let transportSession: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.httpCookieStorage = nil
  config.urlCache = nil
  config.httpMaximumConnectionsPerHost = IPSWArchive.rangesInFlight
  config.timeoutIntervalForResource = 600
  return URLSession(configuration: config)
}()

/// Validates the response head before handing on any body byte. The body
/// arrives in chunks of up to 64 KiB; what arrived before a failure is
/// handed on first, so a resumed request continues after it.
func httpStream(
  _ request: URLRequest, keyPath: String? = nil,
  validate: (HTTPURLResponse) throws -> Void, receive: (Data) throws -> Void
) async throws {
  let (bytes, response) = try await transportSession.bytes(
    for: request, delegate: RedirectPolicy(keyPath: keyPath))
  guard let response = response as? HTTPURLResponse else {
    throw RestoreFailure("Invalid HTTP response.")
  }
  try validate(response)
  let chunkBytes = 65_536
  var buffer = [UInt8]()
  buffer.reserveCapacity(chunkBytes)
  do {
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count == chunkBytes {
        try Task.checkCancellation()
        try receive(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
      }
    }
  } catch {
    if !buffer.isEmpty, !(error is CancellationError) { try receive(Data(buffer)) }
    throw error
  }
  if !buffer.isEmpty { try receive(Data(buffer)) }
}

/// A server error answer; a later attempt may succeed.
public struct HTTPServerError: Error, Equatable, Sendable {
  public let status: Int
}

/// Failures a later attempt can get past: the connection was lost or timed
/// out, there is no network yet, the host can't be reached right now, or the
/// server answered with an error. Anything else is final.
public enum TransientTransport {
  static let codes: [URLError.Code] = [
    .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
    .dnsLookupFailed, .notConnectedToInternet,
  ]
  /// Waits before attempts 2 through 6.
  static let delays: [Duration] = [
    .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
  ]

  public static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? URLError { return codes.contains(error.code) }
    return error is HTTPServerError
  }
}

/// One HTTP exchange; fixtures replace the live session.
struct HTTPExchange: Sendable {
  var perform:
    @Sendable (URLRequest, (HTTPURLResponse) throws -> Void, (Data) throws -> Void) async throws
      -> Void
  var sleep: @Sendable (Duration) async throws -> Void

  static let live = HTTPExchange(
    perform: { request, validate, receive in
      try await httpStream(request, validate: validate, receive: receive)
    }, sleep: { try await Task.sleep(for: $0) })

  /// Retries transient failures with backoff. Cancellation and every other
  /// failure, and the last transient one, are thrown as they are.
  func retrying(_ attempt: () async throws -> Void) async throws {
    var waited = 0
    while true {
      try Task.checkCancellation()
      do {
        return try await attempt()
      } catch {
        guard TransientTransport.isTransient(error), waited < TransientTransport.delays.count
        else { throw error }
        try await sleep(TransientTransport.delays[waited])
        waited += 1
      }
    }
  }
}

func fetchKey(_ raw: String) async throws -> Data {
  let url = try keyURL(raw)
  var request = URLRequest(url: url)
  request.timeoutInterval = 30
  return try await httpBytes(request, maximum: 16384, keyPath: url.path) {
    try require($0.statusCode == 200, "Apple FCS service did not return a key.")
  }
}

func fetchRange(_ source: SourceRecord, record: RangeRecord, base: Int) async throws -> Data {
  let start = base + record.offset
  let end = start + record.size - 1
  var last: any Error = RestoreFailure("Firmware range could not be fetched.")
  for attempt in 0..<3 {
    try Task.checkCancellation()
    do {
      guard let url = URL(string: source.url) else { throw RestoreFailure("Invalid range URL.") }
      var request = URLRequest(url: url)
      request.timeoutInterval = 45
      request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      let data = try await httpBytes(request, maximum: record.size) { response in
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? ""
        try require(
          response.statusCode == 206
            && response.value(forHTTPHeaderField: "Content-Range")
              == "bytes \(start)-\(end)/\(source.sizeBytes)"
            && response.value(forHTTPHeaderField: "Content-Length") == String(record.size)
            && (encoding.isEmpty || encoding == "identity"),
          "Apple did not return the exact requested firmware range.")
      }
      try require(
        data.count == record.size && data.sha256 == record.sha256,
        "Firmware range size or SHA-256 mismatch.")
      return data
    } catch {
      try Task.checkCancellation()
      last = error
      if attempt < 2 { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
    }
  }
  throw last
}

public func withDeadline<T: Sendable>(
  seconds: Int, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask(operation: operation)
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw CancellationError()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
