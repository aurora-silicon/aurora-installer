#if os(macOS)
  import AuroraFirmware
  import Compression
  import CryptoKit
  import Darwin
  import Foundation

  enum NativeStubFileError: Error, Equatable {
    case invalidPlan, changedFile, unsafeFile, writeFailed, invalidImage, insufficientSpace
  }

  struct NativeStubFileIdentity: Codable, Equatable, Sendable {
    let bytes: Int
    let sha256: String
  }

  /// No destination becomes visible until its complete stream is verified and
  /// flushed. Existing identical files are adopted; conflicting files survive.
  struct NativeStubFileStore: Sendable {
    let tree: NativeHandoffFileTree
    let owner: uid_t
    var namespace = "native-stub"

    func data(_ data: Data, at path: String, mode: mode_t = 0o644) async throws
      -> NativeStubFileIdentity
    {
      try await publish(path, bytes: data.count, mode: mode) { writer in
        try writer.append(data)
        return NativeStubFileIdentity(bytes: data.count, sha256: Self.hash(data))
      }
    }

    func member(
      _ member: IPSWArchiveMember, archive: IPSWArchive, at path: String,
      compressed: Bool = false, mode: mode_t = 0o644
    ) async throws -> NativeStubFileIdentity {
      try await publish(path, bytes: member.sizeBytes, mode: mode, compressed: compressed) {
        writer in
        let hash = try await archive.stream(
          member, maximumBytes: 8 << 30,
          maximumCompressedBytes: 8 << 30, consume: writer.append)
        return NativeStubFileIdentity(bytes: member.sizeBytes, sha256: hash)
      }
    }

    func local(_ source: URL, at path: String, compressed: Bool) async throws
      -> NativeStubFileIdentity
    {
      let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { throw NativeStubFileError.unsafeFile }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == owner, info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size > 0,
        info.st_size <= 8 << 30
      else { throw NativeStubFileError.unsafeFile }
      return try await publish(path, bytes: Int(info.st_size), mode: 0o644, compressed: compressed)
      { writer in
        var hash = SHA256()
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var remaining = Int(info.st_size)
        while remaining > 0 {
          try Task.checkCancellation()
          let bytes = try input.read(upToCount: min(4 << 20, remaining)) ?? Data()
          guard !bytes.isEmpty else { throw NativeStubFileError.changedFile }
          hash.update(data: bytes)
          try writer.append(bytes)
          remaining -= bytes.count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
          after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
          after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
        else { throw NativeStubFileError.changedFile }
        return NativeStubFileIdentity(bytes: Int(info.st_size), sha256: Self.hex(hash.finalize()))
      }
    }

    /// Copy a receipt-bound file from a verified source tree, including FAT.
    /// Source POSIX metadata is not used as a credential; its bytes must match.
    func file(
      _ source: NativeHandoffFileTree, path sourcePath: String,
      identity expected: NativeStubFileIdentity, at path: String
    ) async throws -> NativeStubFileIdentity {
      guard expected.bytes > 0, expected.bytes <= 256 << 20 else {
        throw NativeStubFileError.invalidPlan
      }
      let descriptor = try source.fileDescriptor(sourcePath)
      defer { close(descriptor) }
      var before = stat()
      guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
        before.st_size == expected.bytes
      else { throw NativeStubFileError.changedFile }
      return try await publish(path, bytes: expected.bytes, mode: 0o600) { writer in
        var digest = SHA256()
        var offset = 0
        while offset < expected.bytes {
          try Task.checkCancellation()
          let requested = min(4 << 20, expected.bytes - offset)
          var bytes = Data(count: requested)
          let count = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, requested, off_t(offset))
          }
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NativeStubFileError.changedFile }
          bytes.count = count
          digest.update(data: bytes)
          try writer.append(bytes)
          offset += count
        }
        var after = stat()
        guard Self.hex(digest.finalize()) == expected.sha256,
          fstat(descriptor, &after) == 0, after.st_size == before.st_size,
          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
          after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else { throw NativeStubFileError.changedFile }
        return expected
      }
    }

    func identity(_ path: String, maximum: Int = 8 << 30) throws -> NativeStubFileIdentity {
      let descriptor = try tree.fileDescriptor(path)
      defer { close(descriptor) }
      return try Self.identity(descriptor, owner: owner, maximum: maximum)
    }

    private func publish(
      _ path: String, bytes: Int, mode: mode_t, compressed: Bool = false,
      produce: (NativeStubStreamWriter) async throws -> NativeStubFileIdentity
    ) async throws -> NativeStubFileIdentity {
      let (parent, leaf) = try tree.writableParent(path)
      defer { close(parent) }
      let temporary = ".aurora-stub-" + Self.hash(Data((namespace + ":" + path).utf8))
      var stale = stat()
      if fstatat(parent, temporary, &stale, AT_SYMLINK_NOFOLLOW) == 0 {
        guard stale.st_mode & S_IFMT == S_IFREG, stale.st_uid == owner, stale.st_mode & 0o022 == 0,
          stale.st_nlink == 1, unlinkat(parent, temporary, 0) == 0
        else { throw NativeStubFileError.unsafeFile }
      } else if errno != ENOENT {
        throw NativeStubFileError.unsafeFile
      }
      let descriptor = openat(
        parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw NativeStubFileError.writeFailed }
      defer {
        close(descriptor)
        unlinkat(parent, temporary, 0)
      }
      let writer = try NativeStubStreamWriter(
        descriptor: descriptor, bytes: bytes, compressed: compressed)
      let expected = try await produce(writer)
      try writer.finish()
      guard expected.bytes == bytes, fchmod(descriptor, mode) == 0, fsync(descriptor) == 0,
        try Self.identity(descriptor, owner: owner, maximum: bytes) == expected
      else { throw NativeStubFileError.changedFile }
      try Task.checkCancellation()
      if renameatx_np(parent, temporary, parent, leaf, UInt32(RENAME_EXCL)) != 0 {
        guard errno == EEXIST else { throw NativeStubFileError.writeFailed }
        let existing = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard existing >= 0 else { throw NativeStubFileError.unsafeFile }
        defer { close(existing) }
        guard try Self.identity(existing, owner: owner, maximum: bytes) == expected else {
          throw NativeStubFileError.changedFile
        }
      }
      guard fsync(parent) == 0 else { throw NativeStubFileError.writeFailed }
      return expected
    }

    static func identity(_ descriptor: Int32, owner: uid_t, maximum: Int) throws
      -> NativeStubFileIdentity
    {
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == owner, info.st_mode & 0o022 == 0, info.st_nlink == 1,
        info.st_size >= 0, info.st_size <= maximum
      else { throw NativeStubFileError.unsafeFile }
      var hash = SHA256()
      var offset = 0
      while offset < info.st_size {
        try Task.checkCancellation()
        var bytes = Data(count: min(4 << 20, Int(info.st_size) - offset))
        let count = bytes.count
        let got = bytes.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress, count, off_t(offset))
        }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { throw NativeStubFileError.changedFile }
        hash.update(data: bytes.prefix(got))
        offset += got
      }
      var after = stat()
      guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
        after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
        after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
      else { throw NativeStubFileError.changedFile }
      return NativeStubFileIdentity(bytes: offset, sha256: hex(hash.finalize()))
    }

    static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ digest: SHA256.Digest) -> String {
      digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  /// Type-12 resource-fork compression, verified through the filesystem's own
  /// decompressed read path before publication. Both paths use bounded buffers.
  final class NativeStubStreamWriter {
    private let descriptor: Int32
    private let expected: Int
    private let compressed: Bool
    private var resource: Int32 = -1
    private var input = Data()
    private var offsets = [UInt32]()
    private var position: Int
    private var received = 0

    init(descriptor: Int32, bytes: Int, compressed: Bool) throws {
      guard bytes >= 0, bytes <= 8 << 30 else { throw NativeStubFileError.invalidPlan }
      self.descriptor = descriptor
      expected = bytes
      self.compressed = compressed
      position = ((bytes + 65535) / 65536 + 1) * 4
      if compressed {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let fcntlOK = path.withUnsafeMutableBufferPointer { buf in
          fcntl(descriptor, F_GETPATH, buf.baseAddress!) == 0
        }
        guard fcntlOK else { throw NativeStubFileError.unsafeFile }
        let pathString = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        resource = open(
          pathString + "/..namedfork/rsrc", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
          0o600)
        var original = stat()
        var fork = stat()
        guard resource >= 0, fstat(descriptor, &original) == 0, fstat(resource, &fork) == 0,
          original.st_ino == fork.st_ino, original.st_dev == fork.st_dev,
          ftruncate(resource, off_t(position)) == 0
        else {
          if resource >= 0 {
            close(resource)
            resource = -1
          }
          throw NativeStubFileError.unsafeFile
        }
      }
    }
    deinit { if resource >= 0 { close(resource) } }

    func append(_ bytes: Data) throws {
      try Task.checkCancellation()
      guard bytes.count <= expected - received else { throw NativeStubFileError.changedFile }
      if !compressed {
        try Self.write(descriptor, bytes: bytes, offset: received)
      } else {
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
          let count = min(65536 - input.count, bytes.endIndex - cursor)
          input.append(bytes[cursor..<(cursor + count)])
          cursor += count
          if input.count == 65536 { try block() }
        }
      }
      received += bytes.count
    }

    func finish() throws {
      guard received == expected else { throw NativeStubFileError.changedFile }
      if !compressed { return }
      if !input.isEmpty { try block() }
      guard position <= UInt32.max else { throw NativeStubFileError.writeFailed }
      offsets.append(UInt32(position))
      var index = Data()
      for value in offsets {
        var little = value.littleEndian
        index.append(withUnsafeBytes(of: &little) { Data($0) })
      }
      try Self.write(resource, bytes: index, offset: 0)
      guard fsync(resource) == 0 else { throw NativeStubFileError.writeFailed }
      close(resource)
      resource = -1
      var attribute = Data([0x66, 0x70, 0x6d, 0x63, 12, 0, 0, 0])
      var size = UInt64(expected).littleEndian
      attribute.append(withUnsafeBytes(of: &size) { Data($0) })
      let status = attribute.withUnsafeBytes {
        fsetxattr(descriptor, "com.apple.decmpfs", $0.baseAddress, attribute.count, 0, XATTR_CREATE)
      }
      guard status == 0, fchflags(descriptor, UInt32(UF_COMPRESSED)) == 0 else {
        throw NativeStubFileError.writeFailed
      }
    }

    private func block() throws {
      var output = Data(count: 2 * 65536)
      let capacity = output.count
      let count = output.withUnsafeMutableBytes { target in
        input.withUnsafeBytes { source in
          compression_encode_buffer(
            target.bindMemory(to: UInt8.self).baseAddress!, capacity,
            source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
        }
      }
      guard count > 0, position <= Int(UInt32.max) - count else {
        throw NativeStubFileError.writeFailed
      }
      offsets.append(UInt32(position))
      try Self.write(resource, bytes: Data(output.prefix(count)), offset: position)
      position += count
      input.removeAll(keepingCapacity: true)
    }

    private static func write(_ descriptor: Int32, bytes: Data, offset: Int) throws {
      try bytes.withUnsafeBytes { buffer in
        var cursor = 0
        while cursor < bytes.count {
          let count = pwrite(
            descriptor, buffer.baseAddress!.advanced(by: cursor), bytes.count - cursor,
            off_t(offset + cursor))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NativeStubFileError.writeFailed }
          cursor += count
        }
      }
    }
  }
#endif
