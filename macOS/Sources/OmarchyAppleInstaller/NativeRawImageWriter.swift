#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  enum NativeRawImageError: Error, Equatable {
    case invalidTarget, invalidImage, writeFailed, flushFailed
  }

  struct NativeRawImageReceipt: Codable, Equatable, Sendable {
    let partitionIdentifier: String
    let partitionUUID: String
    let partitionSizeBytes: UInt64
    let installedBytes: UInt64
    let contentSHA256: String
    let verification: String
    enum CodingKeys: String, CodingKey {
      case partitionIdentifier = "partition_identifier"
      case partitionUUID = "partition_uuid"
      case partitionSizeBytes = "partition_size_bytes"
      case installedBytes = "installed_bytes"
      case contentSHA256 = "content_sha256"
      case verification
    }
  }

  /// A verified partition descriptor is the entire write capability. The live
  /// opener admits raw character devices only; fixtures supply disposable files.
  struct NativeRawImagePlatform: Sendable {
    var openTarget: @Sendable (RemovalPartition) throws -> Int32
    var writeChunk: @Sendable (Int32, Data, UInt64) throws -> Void
    var flush: @Sendable (Int32) throws -> Void

    static var live: Self {
      Self(
        openTarget: { partition in
          let descriptor = open(
            "/dev/r" + partition.identifier,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
          guard descriptor >= 0 else { throw NativeRawImageError.invalidTarget }
          do {
            var info = stat()
            var named = stat()
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
              lstat("/dev/r" + partition.identifier, &named) == 0,
              named.st_mode & S_IFMT == S_IFCHR, named.st_ino == info.st_ino,
              named.st_dev == info.st_dev, named.st_rdev == info.st_rdev,
              ioctl(descriptor, 0x4004_6418, &blockSize) == 0,
              ioctl(descriptor, 0x4008_6419, &blockCount) == 0,
              blockSize > 0, blockCount > 0
            else { throw NativeRawImageError.invalidTarget }
            let size = blockCount.multipliedReportingOverflow(by: UInt64(blockSize))
            guard !size.overflow, size.partialValue == partition.size else {
              throw NativeRawImageError.invalidTarget
            }
            return descriptor
          } catch {
            close(descriptor)
            throw error
          }
        }, writeChunk: write,
        flush: { descriptor in
          // Synchronize the device cache, preserving the production streaming
          // path without introducing a full root-image readback on first write.
          var request = [UInt64](repeating: 0, count: 3)
          guard
            request.withUnsafeMutableBytes({ ioctl(descriptor, 0x8018_6416, $0.baseAddress!) }) == 0
          else {
            throw NativeRawImageError.flushFailed
          }
        })
    }

    static func write(_ descriptor: Int32, _ bytes: Data, _ offset: UInt64) throws {
      try bytes.withUnsafeBytes { buffer in
        var written = 0
        while written < bytes.count {
          try Task.checkCancellation()
          let amount = pwrite(
            descriptor, buffer.baseAddress!.advanced(by: written),
            bytes.count - written, off_t(offset) + off_t(written))
          if amount < 0 && errno == EINTR { continue }
          guard amount > 0, amount <= bytes.count - written else {
            throw NativeRawImageError.writeFailed
          }
          written += amount
        }
      }
    }
  }

  enum NativeRawImageWriter {
    /// Deflate can end a callback between device blocks. Keep only the trailing
    /// partial block and submit complete 4 KiB blocks to the raw partition.
    struct AlignedSink {
      let expected: UInt64
      let write: (Data, UInt64) throws -> Void
      private(set) var received: UInt64 = 0
      private(set) var copied: UInt64 = 0
      private var pending = Data()

      mutating func append(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 4 << 20,
          UInt64(bytes.count) <= expected - received
        else { throw NativeRawImageError.invalidImage }
        received += UInt64(bytes.count)
        pending.append(bytes)
        try drain(force: false)
      }

      mutating func finish() throws {
        guard received == expected, pending.count % 4096 == 0 else {
          throw NativeRawImageError.invalidImage
        }
        try drain(force: true)
        guard copied == expected, pending.isEmpty else { throw NativeRawImageError.invalidImage }
      }

      private mutating func drain(force: Bool) throws {
        while pending.count >= (force ? 4096 : 1 << 20) {
          let count = min(4 << 20, pending.count - pending.count % 4096)
          guard count > 0 else { break }
          try write(Data(pending.prefix(count)), copied)
          copied += UInt64(count)
          pending.removeFirst(count)
        }
      }
    }

    /// Archive CRC, output length and SHA-256 are completed before a successful
    /// device-cache flush can produce a receipt. No extracted image is retained.
    static func write(
      archive: IPSWArchive, member: IPSWArchiveMember,
      partition: RemovalPartition, platform: NativeRawImagePlatform = .live,
      verify: @Sendable (RemovalPartition) throws -> Void
    ) async throws -> NativeRawImageReceipt {
      guard
        partition.identifier.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression)
          != nil,
        UUID(uuidString: partition.uuid) != nil, partition.type == "Linux Filesystem",
        ["boot.img", "root.img"].contains(member.name), !member.isDirectory,
        member.sizeBytes > 0, member.sizeBytes % 4096 == 0,
        UInt64(member.sizeBytes) <= partition.size
      else { throw NativeRawImageError.invalidImage }
      try Task.checkCancellation()
      try verify(partition)
      let descriptor = try platform.openTarget(partition)
      defer { close(descriptor) }
      try verify(partition)
      var sink = AlignedSink(expected: UInt64(member.sizeBytes)) { bytes, offset in
        try platform.writeChunk(descriptor, bytes, offset)
      }
      let digest = try await archive.stream(
        member, maximumBytes: member.sizeBytes,
        maximumCompressedBytes: member.compressedSize
      ) { bytes in
        try sink.append(bytes)
      }
      try sink.finish()
      try Task.checkCancellation()
      try platform.flush(descriptor)
      try verify(partition)
      return NativeRawImageReceipt(
        partitionIdentifier: partition.identifier,
        partitionUUID: partition.uuid.lowercased(), partitionSizeBytes: partition.size,
        installedBytes: sink.copied, contentSHA256: digest,
        verification: "source-sha256-write-flushed-v1")
    }
  }
#endif
