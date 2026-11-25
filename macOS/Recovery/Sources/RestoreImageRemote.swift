import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What Recovery reads from Apple over the network: a restore image by HTTP
/// ranges from Apple's update CDN (the host the main installer's restore
/// image helper admits), and an archive's FCS release key from Apple's public
/// FCS key service (`RestoreImageKey.keyURL`), both over HTTPS with no
/// redirect followed and no more bytes accepted than asked for. The release
/// key is public, so it proves nothing about the archive: the pinned image
/// size, manifest SHA-256 and the archive's own authentication do
/// (RestoreImageStubPlan, RestoreImageArchive). The network call is
/// `Transport`, so the checks can run without one.
public enum RestoreImageRemote {
  public enum Failure: Error, Equatable {
    /// The URL isn't one this reads from.
    case refusedURL
    /// No answer, or one this doesn't accept (status, length, range, tag).
    case badResponse(String)
    /// The network failed or timed out.
    case unreachable(String)
  }

  public static let imageHost = "updates.cdn-apple.com"
  /// A P-256 PKCS#8 key is a few hundred bytes; the restore image helper caps
  /// the same download at 16 KiB.
  public static let releaseKeyLimit = 16384

  /// One GET: the status, the headers and at most `limit` bytes of body (a
  /// longer one is cut off and reported as `limit + 1` bytes).
  public typealias Transport = (_ request: URLRequest, _ limit: Int) throws -> (
    status: Int, headers: [String: String], body: Data
  )

  /// A restore image's size and a reader of its ranges on Apple's update CDN.
  /// Every read must come from the file the first one saw (same length, and
  /// `If-Match` its ETag when it has one).
  public static func image(_ url: URL, transport: @escaping Transport = live) throws -> (
    size: Int, read: RestoreImageDirectory.Read
  ) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", parts.host == imageHost, parts.port == nil, parts.user == nil,
      parts.password == nil, parts.query == nil, parts.fragment == nil
    else { throw Failure.refusedURL }
    let (_, first) = try range(url, 0, 1, size: nil, tag: nil, transport: transport)
    guard let total = first["content-range"]?.split(separator: "/").last.flatMap({ Int($0) }),
      total > 0
    else { throw Failure.badResponse("\(url.absoluteString) didn't report its size") }
    let tag = first["etag"]
    return (
      total,
      { offset, count in
        try range(url, offset, count, size: total, tag: tag, transport: transport).0
      }
    )
  }

  static func range(
    _ url: URL, _ offset: Int, _ count: Int, size: Int?, tag: String?, transport: Transport
  ) throws -> (Data, [String: String]) {
    // An empty range can't be asked for: "bytes=a-(a-1)" is answered with the whole file.
    guard count > 0 else { return (Data(), [:]) }
    guard offset >= 0, count <= 64 << 20 else { throw Failure.refusedURL }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
    let last = offset + count - 1
    request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
    if let tag { request.setValue(tag, forHTTPHeaderField: "If-Match") }
    let answer = try transport(request, count)
    let headers = Dictionary(
      answer.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    let what = "\(url.absoluteString) didn't return bytes \(offset)-\(last)"
    guard answer.status == 206 else { throw Failure.badResponse("\(what) (HTTP \(answer.status))") }
    let expected = "bytes \(offset)-\(last)/" + (size.map { String($0) } ?? "")
    guard answer.body.count == count, let range = headers["content-range"],
      size == nil ? range.hasPrefix(expected) : range == expected,
      tag == nil || headers["etag"] == tag
    else { throw Failure.badResponse(what) }
    return (answer.body, headers)
  }

  /// The PEM release key at `url`, which must be a key URL `RestoreImageKey`
  /// admits: a 200 of at most `releaseKeyLimit` bytes. As the restore image
  /// helper does, it follows at most two redirects, each to a key URL it
  /// admits with the same path (wkms-public.apple.com answers with one to
  /// fcs-keys-pub-prod.cdn-apple.com).
  public static func releaseKey(_ url: URL, transport: Transport = live) throws -> Data {
    func admitted(_ url: URL) -> Bool {
      (try? RestoreImageKey.keyURL(["com.apple.wkms.fcs-key-url": Data(url.absoluteString.utf8)]))
        == url
    }
    guard admitted(url) else { throw Failure.refusedURL }
    var location = url
    for redirects in 0...2 {
      let request = URLRequest(
        url: location, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
      let answer = try transport(request, releaseKeyLimit)
      if [301, 302, 303, 307, 308].contains(answer.status), redirects < 2 {
        let headers = Dictionary(
          answer.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let next = headers["location"].flatMap({ URL(string: $0) }), admitted(next),
          next.path == url.path
        else {
          throw Failure.badResponse(
            "\(location.absoluteString) redirects outside Apple's key service")
        }
        location = next
        continue
      }
      guard answer.status == 200 else {
        throw Failure.badResponse("\(location.absoluteString) answered HTTP \(answer.status)")
      }
      guard !answer.body.isEmpty, answer.body.count <= releaseKeyLimit else {
        throw Failure.badResponse("\(location.absoluteString) is not a release key")
      }
      return answer.body
    }
    throw Failure.badResponse("\(url.absoluteString) redirects too often")
  }

  /// Archive keys for `RestoreImageStubFiles(archiveKey:)`: each archive's
  /// FCS response opened with the release key fetched from its key URL (one
  /// fetch per URL), and checked to open the archive's root header.
  public final class ArchiveKeys {
    let transport: Transport
    private var releaseKeys = [URL: Data]()
    /// The key URLs fetched, in order, for the log.
    public private(set) var fetched = [URL]()

    public init(transport: @escaping Transport = RestoreImageRemote.live) {
      self.transport = transport
    }

    public func key(
      _ entry: RestoreImageDirectory.Entry, metadata: [String: Data], head: Data? = nil
    ) throws -> Data {
      let url = try RestoreImageKey.keyURL(metadata)
      let pem: Data
      if let known = releaseKeys[url] {
        pem = known
      } else {
        pem = try RestoreImageRemote.releaseKey(url, transport: transport)
        releaseKeys[url] = pem
        fetched.append(url)
      }
      let key = try RestoreImageKey.unwrap(metadata, releaseKey: pem)
      if let head { try RestoreImageKey.authenticateRoot(head, archiveKey: key) }
      return key
    }
  }

  /// URLSession, ephemeral: no cookies, cache or credentials; no redirect is
  /// followed (one could leave Apple's hosts); a body past `limit` is cut off.
  public static let live: Transport = { request, limit in
    let task = Fetch(limit: limit)
    let session = URLSession(configuration: .ephemeral, delegate: task, delegateQueue: nil)
    session.dataTask(with: request).resume()
    let deadline = DispatchTime.now() + request.timeoutInterval + 10
    if task.done.wait(timeout: deadline) == .timedOut {
      session.invalidateAndCancel()
      throw Failure.unreachable("\(request.url?.absoluteString ?? "") timed out")
    }
    session.finishTasksAndInvalidate()
    guard let response = task.response else {
      throw Failure.unreachable(task.error?.localizedDescription ?? "no response")
    }
    var headers = [String: String]()
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let value = value as? String { headers[key] = value }
    }
    // An answer this refuses (a redirect, an error status) was cancelled
    // before its body: its status is the result. So is a body cut off at
    // `limit + 1` bytes, which the caller refuses by its length.
    guard [200, 206].contains(response.statusCode) else {
      return (response.statusCode, headers, Data())
    }
    if let error = task.error, task.data.count <= limit {
      throw Failure.unreachable(error.localizedDescription)
    }
    return (response.statusCode, headers, task.data)
  }

  final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
    let done = DispatchSemaphore(value: 0)
    init(limit: Int) { self.limit = limit }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      self.response = response
      completionHandler(nil)
    }
    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      self.response = response as? HTTPURLResponse
      completionHandler([200, 206].contains(self.response?.statusCode) ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      self.data.append(data.prefix(max(0, limit + 1 - self.data.count)))
      if self.data.count > limit { dataTask.cancel() }
    }
    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
      self.error = error
      done.signal()
    }
  }
}
