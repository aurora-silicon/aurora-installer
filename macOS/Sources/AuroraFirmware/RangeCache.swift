// SPDX-License-Identifier: MIT
import Darwin
import Foundation

/// Private per-job storage for authenticated ciphertext, never an authority for
/// admission. Every reuse repeats the sealed recipe's length and digest checks.
/// A directory lock excludes a second extraction using the same checkpoint.
actor FirmwareRangeCache {
  private let descriptor: Int32
  private let admittedRecords: Set<RangeRecord>
  private let directory: URL

  init(directory: URL, records: [RangeRecord]) throws {
    try require(directory.isFileURL, "Firmware checkpoint must be local.")
    if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
      throw RestoreFailure("Cannot create firmware checkpoint.")
    }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "Cannot open firmware checkpoint safely.")
    var admitted = false
    defer { if !admitted { close(fd) } }
    var info = stat()
    try require(
      fstat(fd, &info) == 0 && info.st_uid == geteuid()
        && info.st_mode & 0o077 == 0 && info.st_mode & S_IFMT == S_IFDIR,
      "Firmware checkpoint is not a private owned directory.")
    try require(
      flock(fd, LOCK_EX | LOCK_NB) == 0,
      "Another extraction is using this firmware checkpoint.")
    try Self.reconcile(fd, names: Set(records.map(\.sha256)))
    descriptor = fd
    admittedRecords = Set(records)
    self.directory = directory
    admitted = true
  }

  deinit { close(descriptor) }

  func publicationWorkspace(beside output: URL) throws -> URL {
    var destination = stat()
    var checkpoint = stat()
    try require(
      stat(output.deletingLastPathComponent().path, &destination) == 0
        && fstat(descriptor, &checkpoint) == 0 && destination.st_dev == checkpoint.st_dev,
      "Firmware checkpoint and output must share a filesystem.")
    try require(mkdirat(descriptor, ".output", 0o700) == 0, "Cannot prepare firmware publication.")
    return directory.appendingPathComponent(".output", isDirectory: true)
  }

  func fetch(
    _ source: SourceRecord, record: RangeRecord, base: Int,
    download: @Sendable (SourceRecord, RangeRecord, Int) async throws -> Data = {
      try await fetchRange($0, record: $1, base: $2)
    }
  ) async throws -> Data {
    try require(
      admittedRecords.contains(record) && base >= 0 && base <= source.sizeBytes
        && record.valid(limit: source.sizeBytes - base, maximum: segmentBytes + 156),
      "Invalid firmware checkpoint range.")
    if let cached = try read(record) { return cached }
    let bytes = try await download(source, record, base)
    try Task.checkCancellation()
    try require(
      bytes.count == record.size && bytes.sha256 == record.sha256,
      "Downloaded firmware checkpoint does not match its recipe.")
    try publish(bytes, record: record)
    return bytes
  }

  /// Retire regenerable chunks only after the complete firmware tree was
  /// published. An interruption before that point retains verified ranges.
  func retire(_ records: [RangeRecord]) throws {
    for record in Set(records) {
      try require(admittedRecords.contains(record), "Invalid checkpoint identity.")
      if unlinkat(descriptor, record.sha256, 0) != 0 && errno != ENOENT {
        throw RestoreFailure("Cannot retire firmware checkpoint range.")
      }
    }
    try require(fsync(descriptor) == 0, "Cannot sync firmware checkpoint retirement.")
  }

  private func read(_ record: RangeRecord) throws -> Data? {
    let fd = openat(descriptor, record.sha256, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 && errno == ENOENT { return nil }
    try require(fd >= 0, "Cannot read firmware checkpoint safely.")
    defer { close(fd) }
    var info = stat()
    try require(
      fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        && info.st_uid == geteuid() && info.st_mode & 0o077 == 0 && info.st_nlink == 1,
      "Firmware checkpoint entry is unsuitable.")
    if info.st_size == record.size {
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      let bytes = try file.read(upToCount: record.size + 1) ?? Data()
      if bytes.count == record.size && bytes.sha256 == record.sha256 { return bytes }
    }
    // A corrupt regular cache entry is a missed download, not trusted state.
    try require(unlinkat(descriptor, record.sha256, 0) == 0, "Cannot discard corrupt checkpoint.")
    return nil
  }

  private func publish(_ bytes: Data, record: RangeRecord) throws {
    let temporary = "." + UUID().uuidString.lowercased() + ".partial"
    let fd = openat(
      descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try require(fd >= 0, "Cannot write firmware checkpoint.")
    defer {
      close(fd)
      unlinkat(descriptor, temporary, 0)
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    try file.write(contentsOf: bytes)
    try require(fsync(fd) == 0, "Cannot sync firmware checkpoint range.")
    // A second task may have published an identical chunk while this actor
    // awaited the network. Never replace an existing name without validation.
    if linkat(descriptor, temporary, descriptor, record.sha256, 0) != 0 {
      try require(errno == EEXIST, "Cannot publish firmware checkpoint range.")
      try require(try read(record) != nil, "Conflicting firmware checkpoint publication.")
    }
    try require(unlinkat(descriptor, temporary, 0) == 0, "Cannot retire checkpoint staging file.")
    try require(fsync(descriptor) == 0, "Cannot sync firmware checkpoint directory.")
  }

  private static func reconcile(_ fd: Int32, names: Set<String>) throws {
    try require(names.allSatisfy(validHash), "Invalid firmware checkpoint identities.")
    let copy = dup(fd)
    try require(copy >= 0, "Cannot inspect firmware checkpoint.")
    guard let directory = fdopendir(copy) else {
      close(copy)
      throw RestoreFailure("Cannot inspect firmware checkpoint directory.")
    }
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        try require(errno == 0, "Cannot enumerate firmware checkpoint.")
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." || names.contains(name) { continue }
      if name == ".output" {
        try removeStagingTree(fd, name: name)
        continue
      }
      let partial =
        name.hasPrefix(".") && name.hasSuffix(".partial") && name.count == 45
        && UUID(uuidString: String(name.dropFirst().dropLast(8))) != nil
      try require(partial, "Firmware checkpoint contains data from another job.")
      try require(unlinkat(fd, name, 0) == 0, "Cannot retire an interrupted range write.")
    }
  }

  /// Descriptor-relative cleanup never follows a path out of the leased job.
  private static func removeStagingTree(_ parent: Int32, name: String) throws {
    var info = stat()
    try require(
      fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_uid == geteuid(),
      "Interrupted firmware staging has an unexpected owner.")
    if info.st_mode & S_IFMT != S_IFDIR {
      try require(unlinkat(parent, name, 0) == 0, "Cannot retire interrupted firmware staging.")
      return
    }
    try require(info.st_mode & 0o077 == 0, "Interrupted firmware staging is not private.")
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "Cannot inspect interrupted firmware staging.")
    defer { close(fd) }
    let copy = dup(fd)
    try require(copy >= 0, "Cannot enumerate interrupted firmware staging.")
    guard let directory = fdopendir(copy) else {
      close(copy)
      throw RestoreFailure("Cannot inspect interrupted firmware staging.")
    }
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        try require(errno == 0, "Cannot enumerate interrupted firmware staging.")
        break
      }
      let child = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if child != "." && child != ".." { try removeStagingTree(fd, name: child) }
    }
    try require(unlinkat(parent, name, AT_REMOVEDIR) == 0, "Cannot retire staging directory.")
  }
}
