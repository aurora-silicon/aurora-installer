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
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = request.timeoutInterval
  config.timeoutIntervalForResource = request.timeoutInterval
  config.httpCookieStorage = nil
  config.urlCache = nil
  let session = URLSession(
    configuration: config, delegate: RedirectPolicy(keyPath: keyPath), delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  let (bytes, response) = try await session.bytes(for: request)
  guard let response = response as? HTTPURLResponse else {
    throw RestoreFailure("Invalid HTTP response.")
  }
  try validate(response)
  var data = Data()
  data.reserveCapacity(maximum)
  for try await byte in bytes {
    try Task.checkCancellation()
    try require(data.count < maximum, "HTTP response exceeds its admitted length.")
    data.append(byte)
  }
  return data
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
