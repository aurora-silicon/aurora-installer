#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation

  /// FAT authenticates files by their mounted volume, relative descriptor and
  /// content. Its synthesized POSIX metadata is not an ownership credential.
  /// The caller holds the protected installation journal lease throughout use.
  struct NativeESPFileStore: Sendable {
    let tree: NativeHandoffFileTree
    private let device: dev_t
    private let namespace: String

    init(root: URL, volumeDevice: String, namespace: String,
      verifyMount: @Sendable (Int32, URL, String) throws -> Void = NativeHandoffFileTree.verifyVolumeRoot,
      admitFilesystem: @Sendable (Int32) throws -> Void = NativeESPFileStore.requireFAT) throws {
      let tree = try NativeHandoffFileTree(root, protected: false, volumeRoot: true,
        volumeDevice: volumeDevice, verifyMount: verifyMount)
      let (descriptor, _) = try tree.writableParent(".volume-admission")
      defer { close(descriptor) }
      try admitFilesystem(descriptor)
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw NativeHandoffValidationError.unsafePath
      }
      self.tree = tree
      device = info.st_dev
      self.namespace = namespace
    }

    static func requireFAT(_ descriptor: Int32) throws {
      var filesystem = statfs()
      guard fstatfs(descriptor, &filesystem) == 0 else { throw NativeHandoffValidationError.invalidTarget }
      let kind = withUnsafeBytes(of: filesystem.f_fstypename) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      guard kind == "msdos" else { throw NativeHandoffValidationError.invalidTarget }
    }

    func data(_ bytes: Data, at path: String) async throws -> NativeStubFileIdentity {
      try await publish(path, bytes: bytes.count) { consume in
        var offset = 0
        while offset < bytes.count {
          let end = min(offset + (4 << 20), bytes.count)
          try consume(bytes.subdata(in: offset..<end))
          offset = end
        }
        return NativeStubFileStore.hash(bytes)
      }
    }

    func member(_ member: IPSWArchiveMember, archive: IPSWArchive, at path: String) async throws -> NativeStubFileIdentity {
      try await publish(path, bytes: member.sizeBytes) { consume in
        try await archive.stream(member, maximumBytes: 64 << 20,
          maximumCompressedBytes: 64 << 20, consume: consume)
      }
    }

    func identity(_ path: String, maximum: Int = 64 << 20) throws -> NativeStubFileIdentity {
      let descriptor = try tree.fileDescriptor(path)
      defer { close(descriptor) }
      return try identity(descriptor, maximum: maximum)
    }

    private func publish(_ path: String, bytes: Int,
      produce: ((Data) throws -> Void) async throws -> String) async throws -> NativeStubFileIdentity {
      guard NativeESPPayloadPlan.safeFATPath(path), (0...(64 << 20)).contains(bytes) else {
        throw NativeHandoffValidationError.unsafePath
      }
      try Task.checkCancellation()
      let (parent, leaf) = try tree.writableParent(path)
      defer { close(parent) }
      var directory = stat()
      guard fstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
        directory.st_dev == device else { throw NativeHandoffValidationError.unsafePath }
      let temporary = ".aurora-esp-" + NativeStubFileStore.hash(Data((namespace + ":" + path).utf8))
      var stale = stat()
      if fstatat(parent, temporary, &stale, AT_SYMLINK_NOFOLLOW) == 0 {
        guard stale.st_mode & S_IFMT == S_IFREG, stale.st_dev == device,
          unlinkat(parent, temporary, 0) == 0 else { throw NativeHandoffValidationError.unsafePath }
      } else if errno != ENOENT { throw NativeHandoffValidationError.unsafePath }
      let descriptor = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw NativeStubFileError.writeFailed }
      defer { close(descriptor); unlinkat(parent, temporary, 0) }
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
        opened.st_dev == device else { throw NativeHandoffValidationError.unsafePath }
      var copied = 0
      let digest = try await produce { chunk in
        guard chunk.count <= 4 << 20, chunk.count <= bytes - copied else { throw NativeStubFileError.changedFile }
        try NativeRawImagePlatform.write(descriptor, chunk, UInt64(copied))
        copied += chunk.count
      }
      let expected = NativeStubFileIdentity(bytes: bytes, sha256: digest)
      guard copied == bytes, fsync(descriptor) == 0,
        try identity(descriptor, maximum: bytes) == expected else { throw NativeStubFileError.changedFile }
      try Task.checkCancellation()
      if renameatx_np(parent, temporary, parent, leaf, UInt32(RENAME_EXCL)) != 0 {
        guard errno == EEXIST else { throw NativeStubFileError.writeFailed }
        let existing = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard existing >= 0 else { throw NativeHandoffValidationError.unsafePath }
        defer { close(existing) }
        guard try identity(existing, maximum: bytes) == expected else { throw NativeStubFileError.changedFile }
      }
      guard fsync(parent) == 0 else { throw NativeStubFileError.writeFailed }
      return expected
    }

    private func identity(_ descriptor: Int32, maximum: Int) throws -> NativeStubFileIdentity {
      var before = stat()
      guard (0...(64 << 20)).contains(maximum), fstat(descriptor, &before) == 0,
        before.st_mode & S_IFMT == S_IFREG, before.st_dev == device,
        before.st_size >= 0, before.st_size <= maximum else { throw NativeHandoffValidationError.unsafePath }
      var digest = SHA256()
      var offset = 0
      while offset < before.st_size {
        try Task.checkCancellation()
        let requested = min(4 << 20, Int(before.st_size) - offset)
        var bytes = Data(count: requested)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, requested, off_t(offset)) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw NativeStubFileError.changedFile }
        bytes.count = count
        digest.update(data: bytes)
        offset += count
      }
      var after = stat()
      guard fstat(descriptor, &after) == 0, after.st_dev == before.st_dev,
        after.st_ino == before.st_ino, after.st_size == before.st_size,
        after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
        after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw NativeStubFileError.changedFile }
      return NativeStubFileIdentity(bytes: offset, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
  }
#endif
