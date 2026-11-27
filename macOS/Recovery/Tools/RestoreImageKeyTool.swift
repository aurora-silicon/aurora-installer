import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// `aurora-restore-key`: the archive key of a restore image's Apple Encrypted
/// Archive, without CryptoKit, for recoveryOS (see RestoreImageKey).
///
///     aurora-restore-key member IMAGE NAME
///     aurora-restore-key key-url ARCHIVE
///     aurora-restore-key unwrap ARCHIVE RELEASE_KEY_PEM OUTPUT
///
/// `member` prints the offset, size and CRC-32 (hex) of the stored member
/// NAME of a restore image, IMAGE being a local file or an
/// https://updates.cdn-apple.com/ URL (no other URL) read with HTTP ranges (see
/// RestoreImageMember); `curl -r` or `dd` then reads the member itself.
/// ARCHIVE needs only the archive's first bytes (header, metadata, salt and
/// root header). `key-url` prints where its private key is fetched from;
/// `unwrap` writes the 32-byte archive key that `aea decrypt -key` takes to a
/// new file OUTPUT (mode 0600, never replacing one) once it authenticates the
/// archive's root header. Exit 64 is a usage error.
@main struct RestoreImageKeyTool {
  static func fail(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("aurora-restore-key: " + message + "\n").utf8))
    exit(status)
  }

  /// At most `limit` bytes from the start of `path`; a read error is
  /// reported, not taken for a short file.
  static func read(_ path: String, limit: Int) -> Data {
    do {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      return try handle.read(upToCount: limit) ?? Data()
    } catch {
      fail("can't read \(path): \(error.localizedDescription)")
    }
  }

  /// Header, metadata (at most 1 MiB), salt and root header.
  static func head(_ path: String) -> Data { read(path, limit: 12 + 1024 * 1024 + 32 + 112) }

  /// The release key PEM: a P-256 PKCS#8 key is a few hundred bytes; the
  /// restore image helper caps the same download at 16 KiB.
  static func releaseKey(_ path: String) -> Data {
    let pem = read(path, limit: 16384 + 1)
    guard pem.count <= 16384 else { fail("\(path) is larger than a release key (16 KiB)") }
    return pem
  }

  /// Writes all of `bytes` to a new file at `path` (mode 0600; an existing
  /// file or symlink there is refused) and syncs it; on any failure the
  /// file is removed if it is still the one created here.
  static func create(_ path: String, _ bytes: Data) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { fail("can't create \(path): \(String(cString: strerror(errno)))") }
    var created = stat()
    guard fstat(descriptor, &created) == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      fail("can't create \(path): \(reason) (an empty file may be left)")
    }
    /// Removes `path` only while it is still the file this created.
    func remove() {
      var now = stat()
      if lstat(path, &now) == 0, now.st_dev == created.st_dev, now.st_ino == created.st_ino {
        unlink(path)
      }
    }
    func abandon(_ what: String) -> Never {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      remove()
      fail("can't \(what) \(path): \(reason)")
    }
    var done = 0
    while done < bytes.count {
      let written = bytes.withUnsafeBytes {
        write(descriptor, $0.baseAddress! + done, bytes.count - done)
      }
      if written < 0 {
        if errno == EINTR { continue }
        abandon("write")
      }
      if written == 0 {
        errno = EIO
        abandon("write")
      }
      done += written
    }
    guard fsync(descriptor) == 0 else { abandon("sync") }
    guard close(descriptor) == 0 else {
      let reason = String(cString: strerror(errno))
      remove()
      fail("can't close \(path): \(reason)")
    }
  }

  /// A restore image's size and a reader of its ranges: a local file, or
  /// Apple's update CDN over HTTPS (the host the restore image helper
  /// admits; no other host, port, query or credentials).
  static func image(_ source: String) throws -> (Int, RestoreImageMember.Read) {
    // A URL is anything with a scheme; a local path that happens to hold
    // "://" can be given as ./path.
    guard source.contains("://"), !source.hasPrefix("/"), !source.hasPrefix(".") else {
      let handle: FileHandle
      do {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
      } catch {
        fail("can't read \(source): \(error.localizedDescription)")
      }
      let size = Int(try handle.seekToEnd())
      return (
        size,
        { offset, count in
          try handle.seek(toOffset: UInt64(offset))
          return try handle.read(upToCount: count) ?? Data()
        }
      )
    }
    guard let url = URLComponents(string: source), url.scheme == "https",
      url.host == "updates.cdn-apple.com",
      url.port == nil, url.user == nil, url.password == nil, url.query == nil,
      url.fragment == nil, let location = url.url
    else { fail("\(source) is not a restore image on https://updates.cdn-apple.com/") }
    // The first byte, for the total size in Content-Range and the ETag
    // every later read must match (If-Match), so all come from one file.
    let (_, first) = try fetch(location, 0, 1, size: nil, tag: nil)
    guard let range = first?.value(forHTTPHeaderField: "Content-Range"),
      let total = range.split(separator: "/").last.flatMap({ Int($0) }), total > 0
    else { fail("\(source) didn't report its size") }
    let tag = first?.value(forHTTPHeaderField: "ETag")
    return (total, { offset, count in try fetch(location, offset, count, size: total, tag: tag).0 })
  }

  /// One range request: no redirect is followed (a redirect could leave
  /// Apple's CDN), any answer but a 206 is cancelled before its body is
  /// read, and the body may not grow past the range.
  final class RangeTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
      completionHandler(self.response?.statusCode == 206 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      self.data.append(data)
      if self.data.count > limit { dataTask.cancel() }
    }
    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
      self.error = error
      done.signal()
    }
  }

  /// `count` bytes at `offset` of `url`: a 206 of exactly that range of a
  /// file of `size` bytes (when known) with ETag `tag` (when there is one).
  static func fetch(_ url: URL, _ offset: Int, _ count: Int, size: Int?, tag: String?) throws
    -> (Data, HTTPURLResponse?)
  {
    // An empty range can't be asked for: "bytes=a-(a-1)" is ignored and
    // answered with the whole file.
    if count == 0 { return (Data(), nil) }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
    let last = offset + count - 1
    request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
    if let tag { request.setValue(tag, forHTTPHeaderField: "If-Match") }
    let task = RangeTask(limit: count)
    let session = URLSession(configuration: .ephemeral, delegate: task, delegateQueue: nil)
    session.dataTask(with: request).resume()
    task.done.wait()
    session.finishTasksAndInvalidate()
    let what = "\(url.absoluteString) didn't return bytes \(offset)-\(last)"
    guard let response = task.response else {
      fail("can't read \(url.absoluteString): \(task.error?.localizedDescription ?? "no response")")
    }
    guard response.statusCode == 206 else { fail("\(what) (HTTP \(response.statusCode))") }
    if let error = task.error {
      fail("can't read \(url.absoluteString): \(error.localizedDescription)")
    }
    let expected = "bytes \(offset)-\(last)/" + (size.map { String($0) } ?? "")
    guard task.data.count == count,
      let range = response.value(forHTTPHeaderField: "Content-Range"),
      size == nil ? range.hasPrefix(expected) : range == expected,
      tag == nil || response.value(forHTTPHeaderField: "ETag") == tag
    else { fail(what) }
    return (task.data, response)
  }

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch arguments.first {
      case "key-url" where arguments.count == 2:
        print(
          try RestoreImageKey.keyURL(RestoreImageKey.metadata(head(arguments[1]))).absoluteString)
      case "member" where arguments.count == 3:
        let (size, read) = try image(arguments[1])
        let member = try RestoreImageMember.locate(arguments[2], archiveSize: size, read: read)
        print(member.offset, member.size, String(format: "%08x", member.crc32))
      case "unwrap" where arguments.count == 4:
        let archive = head(arguments[1])
        let metadata = try RestoreImageKey.metadata(archive)
        let key = try RestoreImageKey.unwrap(metadata, releaseKey: releaseKey(arguments[2]))
        // The key must open this archive, not only unwrap.
        try RestoreImageKey.authenticateRoot(archive, archiveKey: key)
        create(arguments[3], key)
      default:
        fail(
          "usage: aurora-restore-key member IMAGE NAME | key-url ARCHIVE"
            + " | unwrap ARCHIVE RELEASE_KEY_PEM OUTPUT", 64)
      }
    } catch {
      fail("\(error)")
    }
  }
}
