#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeHandoffRawReaderTests: XCTestCase {
    func testReusableReadBufferHashesTheCompleteImageAndRejectsTruncation() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let pattern = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
      var source = Data()
      for _ in 0..<1025 { source.append(pattern) }
      source.append(0xa5)
      let path = root.appendingPathComponent("image")
      try source.write(to: path)
      let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(fd, 0)
      defer { close(fd) }
      let expected = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(
        try NativeHandoffRawReader.digest(descriptor: fd, bytes: UInt64(source.count)),
        expected)
      XCTAssertEqual(lseek(fd, 0, SEEK_CUR), 0)
      XCTAssertThrowsError(
        try NativeHandoffRawReader.digest(descriptor: fd, bytes: UInt64(source.count + 1)))
    }
  }
#endif
