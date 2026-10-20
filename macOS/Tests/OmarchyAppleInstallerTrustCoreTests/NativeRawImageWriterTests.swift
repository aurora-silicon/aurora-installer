#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeRawImageWriterTests: XCTestCase, @unchecked Sendable {
    struct Source: FirmwareRangeReading {
      let bytes: Data
      var sizeBytes: Int { bytes.count }
      func read(offset: Int, count: Int) async throws -> Data {
        try Task.checkCancellation()
        return bytes.subdata(in: offset..<(offset + count))
      }
    }
    static func source() throws -> Data {
      let path = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-payload-vectors",
          withExtension: "json", subdirectory: "Fixtures"))
      let document =
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
      let archives = document["archives"] as! [String: String]
      return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(archives["btrfs"])))
    }
    final class Target: @unchecked Sendable {
      let directory: URL
      let url: URL
      var flushed = 0
      var opened = 0
      var writes = 0
      var rejectFlush = false
      var rejectWrite = false
      let capacity: UInt64
      init(capacity: UInt64) throws {
        self.capacity = capacity
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("disposable-image-target")
        try Data(repeating: 0xcc, count: Int(capacity)).write(to: url)
      }
      deinit { try? FileManager.default.removeItem(at: directory) }
      var partition: RemovalPartition {
        RemovalPartition(
          identifier: "disk0s9", uuid: "00000000-0000-0000-0000-000000000009",
          type: "Linux Filesystem", offset: 4 << 20, size: capacity, name: "")
      }
      var platform: NativeRawImagePlatform {
        NativeRawImagePlatform(
          openTarget: { _ in
            self.opened += 1
            let fd = open(self.url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeRawImageError.invalidTarget }
            return fd
          },
          writeChunk: { fd, bytes, offset in
            self.writes += 1
            if self.rejectWrite { throw NativeRawImageError.writeFailed }
            XCTAssertLessThanOrEqual(bytes.count, 4 << 20)
            XCTAssertEqual(bytes.count % 4096, 0)
            XCTAssertEqual(offset % 4096, 0)
            try NativeRawImagePlatform.write(fd, bytes, offset)
          },
          flush: { fd in
            self.flushed += 1
            if self.rejectFlush { throw NativeRawImageError.flushFailed }
            guard fsync(fd) == 0 else { throw NativeRawImageError.flushFailed }
          })
      }
    }

    func testUnalignedDecoderCallbacksProduceOnlyCompleteRawBlocks() throws {
      let total = (1 << 20) + 4096
      var written = Data()
      var calls = [(UInt64, Int)]()
      var sink = NativeRawImageWriter.AlignedSink(expected: UInt64(total)) { bytes, offset in
        XCTAssertEqual(offset % 4096, 0)
        XCTAssertEqual(bytes.count % 4096, 0)
        XCTAssertLessThanOrEqual(bytes.count, 4 << 20)
        calls.append((offset, bytes.count))
        written.append(bytes)
      }
      try sink.append(Data(repeating: 0x11, count: (1 << 20) - 1))
      XCTAssertTrue(calls.isEmpty)
      try sink.append(Data([0x22]))
      XCTAssertEqual(calls.count, 1)
      try sink.append(Data(repeating: 0x33, count: 4095))
      try sink.append(Data([0x44]))
      try sink.finish()
      XCTAssertEqual(calls.map { $0.1 }, [1 << 20, 4096])
      XCTAssertEqual(written.count, total)
      XCTAssertEqual(written[(1 << 20) - 1], 0x22)
      XCTAssertEqual(written[total - 1], 0x44)
    }

    func testStreamingWritesOnlyTheImagePrefixAndReturnsTheFlushedSourceIdentity() async throws {
      let archive = try await IPSWArchive.open(Source(bytes: Self.source()))
      for name in ["boot.img", "root.img"] {
        let member = try XCTUnwrap(archive.members.first { $0.name == name })
        let target = try Target(capacity: UInt64(member.sizeBytes + 4096))
        let receipt = try await NativeRawImageWriter.write(
          archive: archive, member: member,
          partition: target.partition, platform: target.platform, verify: { _ in })
        let expected = try await archive.read(member, maximumBytes: member.sizeBytes)
        let written = try Data(contentsOf: target.url)
        XCTAssertEqual(written.prefix(member.sizeBytes), expected)
        XCTAssertEqual(written.suffix(4096), Data(repeating: 0xcc, count: 4096))
        XCTAssertEqual(
          receipt.contentSHA256,
          SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(receipt.installedBytes, UInt64(member.sizeBytes))
        XCTAssertEqual(receipt.partitionUUID, target.partition.uuid.lowercased())
        XCTAssertEqual(receipt.verification, "source-sha256-write-flushed-v1")
        XCTAssertEqual(target.flushed, 1)
      }
    }

    func testLargeExpandedRootAcceptsASmallImageWithoutAllocatingThePartitionSize() async throws {
      let archive = try await IPSWArchive.open(Source(bytes: Self.source()))
      let member = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      let target = try Target(capacity: UInt64(member.sizeBytes + 4096))
      let original = target.partition
      let expanded = RemovalPartition(
        identifier: original.identifier, uuid: original.uuid,
        type: original.type, offset: original.offset, size: 200 << 30, name: original.name)
      let receipt = try await NativeRawImageWriter.write(
        archive: archive, member: member,
        partition: expanded, platform: target.platform, verify: { _ in })
      XCTAssertEqual(receipt.partitionSizeBytes, 200 << 30)
      XCTAssertEqual(receipt.installedBytes, UInt64(member.sizeBytes))
      XCTAssertEqual(try Data(contentsOf: target.url).count, member.sizeBytes + 4096)
    }

    func testUndersizedOrChangedTargetsAreRejectedBeforeOpening() async throws {
      let archive = try await IPSWArchive.open(Source(bytes: Self.source()))
      let member = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      let tooSmall = try Target(capacity: UInt64(member.sizeBytes - 4096))
      do {
        _ = try await NativeRawImageWriter.write(
          archive: archive, member: member,
          partition: tooSmall.partition, platform: tooSmall.platform, verify: { _ in })
        XCTFail("Undersized partition admitted")
      } catch {}
      XCTAssertEqual(tooSmall.opened, 0)
      let changed = try Target(capacity: UInt64(member.sizeBytes))
      do {
        _ = try await NativeRawImageWriter.write(
          archive: archive, member: member,
          partition: changed.partition, platform: changed.platform,
          verify: { _ in throw NativeOSPartitionError.changedLayout })
        XCTFail("Changed identity admitted")
      } catch {}
      XCTAssertEqual(changed.opened, 0)
    }

    func testWriteOrFlushFailureCannotProduceAReceipt() async throws {
      let archive = try await IPSWArchive.open(Source(bytes: Self.source()))
      let member = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      for flush in [false, true] {
        let target = try Target(capacity: UInt64(member.sizeBytes))
        target.rejectFlush = flush
        target.rejectWrite = !flush
        do {
          _ = try await NativeRawImageWriter.write(
            archive: archive, member: member,
            partition: target.partition, platform: target.platform, verify: { _ in })
          XCTFail("Failed device operation returned a receipt")
        } catch {}
        XCTAssertEqual(target.flushed, flush ? 1 : 0)
      }
    }

    func testCorruptArchiveDataNeverReachesTheSuccessfulFlush() async throws {
      var bytes = try Self.source()
      let original = try await IPSWArchive.open(Source(bytes: bytes))
      let member = try XCTUnwrap(original.members.first { $0.name == "root.img" })
      let header = member.localHeaderOffset
      func little(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
      let dataStart = header + 30 + little(header + 26) + little(header + 28)
      bytes[dataStart] ^= 0xff
      let archive = try await IPSWArchive.open(Source(bytes: bytes))
      let corrupt = try XCTUnwrap(archive.members.first { $0.name == "root.img" })
      let target = try Target(capacity: UInt64(corrupt.sizeBytes))
      do {
        _ = try await NativeRawImageWriter.write(
          archive: archive, member: corrupt,
          partition: target.partition, platform: target.platform, verify: { _ in })
        XCTFail("Corrupt source returned a receipt")
      } catch {}
      XCTAssertEqual(target.flushed, 0)
    }
  }
#endif
