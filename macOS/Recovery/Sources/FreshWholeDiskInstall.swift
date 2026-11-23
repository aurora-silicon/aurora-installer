import Foundation

#if canImport(CommonCrypto)
  import CommonCrypto
#endif

/// Carries out a `FreshWholeDisk` plan with diskutil, newfs_msdos and raw
/// writes, one step at a time, re-reading the disk after every step. It is
/// the disk half of a fresh whole-disk installation from recoveryOS: macOS
/// goes, then the startup container, the EFI partition (formatted) and the
/// Boot and Root partitions (their images written and checked) are made in
/// the space it leaves. Filling the startup container is the next stage.
///
/// What the disk says decides the next partition step (`FreshWholeDisk.next`),
/// so an installation that stopped anywhere resumes without repeating a
/// deletion. What the disk can't say, whether a new partition's contents were
/// written, the journal records; a partition whose contents aren't recorded
/// is written again, which is safe because nothing uses it yet.
///
/// Only Foundation, so the same code runs against a stand-in diskutil on
/// disk images (tools/whole-disk/fresh-install-test.py).
struct FreshWholeDiskTools {
  var diskutil = "/usr/sbin/diskutil"
  var newfsMSDOS = "/sbin/newfs_msdos"
  var curl = "/usr/bin/curl"
  /// Where a partition's bytes are written: its raw device, from its start.
  var device: (WholeDiskPartition) -> (path: String, offset: UInt64) = {
    ("/dev/r" + $0.identifier, 0)
  }
}

/// One of the OS package's images, pinned by the release: where it comes from
/// (a file, or an https URL streamed with curl), its exact size and SHA-256.
struct FreshWholeDiskImage: Equatable {
  let source: String
  let size: UInt64
  let sha256: String
}

struct FreshWholeDiskInstallFailure: Error, LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// SHA-256 over a stream. CommonCrypto where it exists (every macOS and
/// recoveryOS); elsewhere a plain implementation for the disk-image tests.
struct FreshWholeDiskSHA256 {
  #if canImport(CommonCrypto)
    private var context = CC_SHA256_CTX()
    init() { precondition(CC_SHA256_Init(&context) == 1) }
    mutating func update(_ data: Data) {
      data.withUnsafeBytes { raw in
        precondition(CC_SHA256_Update(&context, raw.baseAddress, CC_LONG(raw.count)) == 1)
      }
    }
    mutating func finish() -> String {
      var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
      precondition(CC_SHA256_Final(&digest, &context) == 1)
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  #else
    private var h: [UInt32] = [
      0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab,
      0x5be0_cd19,
    ]
    private var pending = [UInt8]()
    private var length: UInt64 = 0
    private static let k: [UInt32] = [
      0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
      0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe,
      0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f,
      0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da, 0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
      0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc,
      0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
      0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070, 0x19a4_c116,
      0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
      0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
      0xc671_78f2,
    ]
    init() {}
    private mutating func block(_ b: ArraySlice<UInt8>) {
      func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
      var w = [UInt32](repeating: 0, count: 64)
      let s = b.startIndex
      for i in 0..<16 {
        w[i] =
          UInt32(b[s + 4 * i]) << 24 | UInt32(b[s + 4 * i + 1]) << 16 | UInt32(b[s + 4 * i + 2]) << 8
          | UInt32(b[s + 4 * i + 3])
      }
      for i in 16..<64 {
        let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
      }
      var (a, b2, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
      for i in 0..<64 {
        let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ Self.k[i]
          &+ w[i]
        let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b2) ^ (a & c) ^ (b2 & c))
        (hh, g, f, e, d, c, b2, a) = (g, f, e, d &+ t1, c, b2, a, t1 &+ t2)
      }
      h[0] &+= a
      h[1] &+= b2
      h[2] &+= c
      h[3] &+= d
      h[4] &+= e
      h[5] &+= f
      h[6] &+= g
      h[7] &+= hh
    }
    mutating func update(_ data: Data) {
      length += UInt64(data.count)
      pending.append(contentsOf: data)
      var i = 0
      while pending.count - i >= 64 {
        block(pending[i..<i + 64])
        i += 64
      }
      pending.removeFirst(i)
    }
    mutating func finish() -> String {
      let bits = length * 8
      var tail: [UInt8] = [0x80]
      while (pending.count + tail.count) % 64 != 56 { tail.append(0) }
      for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
      let saved = length
      update(Data(tail))
      length = saved
      return h.map { String(format: "%08x", $0) }.joined()
    }
  #endif
}

enum FreshWholeDiskInstall {
  static let chunk = 4 << 20

  static func failure(_ message: String) -> FreshWholeDiskInstallFailure {
    FreshWholeDiskInstallFailure(message: message)
  }

  /// Runs a command and returns its standard output; any other exit fails.
  static func run(_ path: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let message = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: message.isEmpty ? data : message, as: UTF8.self)
      throw failure(
        "\((path as NSString).lastPathComponent) \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    return data
  }

  static func plist(_ data: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any]
    else { throw failure("diskutil printed something other than a property list.") }
    return value
  }

  /// One reading of `disk`, from diskutil's own listings.
  static func read(_ disk: String, tools: FreshWholeDiskTools) throws -> WholeDiskLayout {
    let list = try plist(run(tools.diskutil, ["list", "-plist", disk]))
    let whole = try plist(run(tools.diskutil, ["info", "-plist", disk]))
    guard let size = (whole["Size"] as? NSNumber)?.uint64Value, size > 0 else {
      throw failure("diskutil didn’t report the size of \(disk).")
    }
    guard whole["Internal"] as? Bool == true else {
      throw FreshWholeDiskRefusal(message: "\(disk) isn’t this Mac’s internal disk. Nothing was changed.")
    }
    var infos = [String: [String: Any]]()
    let entries = (list["AllDisksAndPartitions"] as? [[String: Any]] ?? []).filter {
      $0["DeviceIdentifier"] as? String == disk
    }
    for p in entries.first?["Partitions"] as? [[String: Any]] ?? [] {
      guard let id = p["DeviceIdentifier"] as? String,
        id.hasPrefix(disk + "s"), id.dropFirst(disk.count + 1).allSatisfy(\.isNumber)
      else { throw failure("diskutil listed an unexpected partition of \(disk).") }
      infos[id] = try plist(run(tools.diskutil, ["info", "-plist", id]))
    }
    return try WholeDiskLayout.parse(
      disk: disk, diskSize: size, list: list, infos: infos,
      apfs: plist(run(tools.diskutil, ["apfs", "list", "-plist"])),
      groups: plist(run(tools.diskutil, ["apfs", "listVolumeGroups", "-plist"])))
  }

  // MARK: Journal

  /// `phase`, the planned rows and which contents are written. 0600, written
  /// whole with a rename, synced.
  struct Journal: Codable, Equatable {
    var schema = 1
    var disk: String
    var macOSPartitionUUID: String?
    var rows: [[UInt64]]
    var written: [String] = []
    /// The GPT UUID of each partition this installation made, by role. Only
    /// these partitions are ever formatted or written.
    var created: [String: String] = [:]
    /// The role whose `addPartition` is about to run, and the partition
    /// UUIDs on the disk just before it: the one new partition in that row
    /// afterwards is this installation's, even if Recovery stopped before
    /// recording it.
    var intent: String?
    var before: [String] = []
  }

  /// Takes ownership of the partition the recorded `addPartition` made, then
  /// requires every planned partition on the disk to be this installation's
  /// own. A partition the journal doesn't name (another installation, a
  /// finished one, or a lost journal) refuses: nothing is ever formatted or
  /// written that this installation didn't create.
  static func adopt(
    _ journal: inout Journal, plan: FreshWholeDiskPlan, layout: WholeDiskLayout
  ) throws {
    let parts = layout.partitions.sorted { $0.offset < $1.offset }
    let middle = parts.filter {
      $0.uuid != plan.isc.uuid && $0.uuid != plan.systemRecovery.uuid
        && $0.uuid != plan.macOSPartition?.uuid
    }
    for (made, row) in zip(middle, plan.rows) where made.offset == row.offset {
      let role = row.role.rawValue
      if journal.created[role] == made.uuid { continue }
      if journal.created[role] == nil, journal.intent == role, !journal.before.contains(made.uuid)
      {
        journal.created[role] = made.uuid
        journal.written.removeAll { $0 == role }
        continue
      }
      throw FreshWholeDiskRefusal(
        message:
          "\(made.identifier) is where this installation puts its \(role) partition, but this installation's journal didn't make it. Nothing was written to it. If an earlier run stopped and its journal is gone, erase the partitions Aurora made and start again."
      )
    }
  }

  static func rows(_ plan: FreshWholeDiskPlan) -> [[UInt64]] {
    plan.rows.map { [$0.offset, $0.size] }
  }

  static func save(_ journal: Journal, to url: URL) throws {
    let data = try JSONEncoder().encode(journal)
    let temp = url.appendingPathExtension("new")
    _ = FileManager.default.createFile(
      atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
    guard let handle = FileHandle(forWritingAtPath: temp.path) else {
      throw failure("The installation journal at \(url.path) can’t be written.")
    }
    handle.write(data)
    handle.synchronizeFile()
    handle.closeFile()
    guard rename(temp.path, url.path) == 0 else {
      throw failure("The installation journal at \(url.path) can’t be saved (errno \(errno)).")
    }
  }

  static func load(_ url: URL) throws -> Journal? {
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    guard let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.schema == 1
    else { throw failure("The installation journal at \(url.path) is unreadable. Nothing was changed.") }
    return journal
  }

  // MARK: Contents

  /// Writes all of `bytes` at `offset` with pwrite, retrying interrupted
  /// and partial writes.
  static func pwriteAll(_ fd: Int32, _ bytes: Data, at offset: UInt64) throws {
    try bytes.withUnsafeBytes { raw in
      var written = 0
      while written < raw.count {
        let n = pwrite(fd, raw.baseAddress!.advanced(by: written), raw.count - written,
          off_t(offset) + off_t(written))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw failure("Writing the disk failed (errno \(errno)).") }
        written += n
      }
    }
  }

  static func preadAll(_ fd: Int32, count: Int, at offset: UInt64) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { raw in
      var done = 0
      while done < count {
        let n = pread(fd, raw.baseAddress!.advanced(by: done), count - done,
          off_t(offset) + off_t(done))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw failure("Reading the disk back failed (errno \(errno)).") }
        done += n
      }
    }
    return data
  }

  /// Opens where `part`'s bytes go. A raw device must be exactly that
  /// partition: a character device whose block size times block count is the
  /// partition's size.
  static func openTarget(_ part: WholeDiskPartition, tools: FreshWholeDiskTools) throws -> (
    fd: Int32, base: UInt64
  ) {
    let (path, base) = tools.device(part)
    let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw failure("\(path) can’t be opened for writing (errno \(errno)).") }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      close(fd)
      throw failure("\(path) can’t be examined.")
    }
    if info.st_mode & S_IFMT == S_IFCHR {
      #if canImport(Darwin)
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        // DKIOCGETBLOCKSIZE, DKIOCGETBLOCKCOUNT
        guard ioctl(fd, 0x4004_6418, &blockSize) == 0, ioctl(fd, 0x4008_6419, &blockCount) == 0,
          blockSize > 0, base == 0
        else {
          close(fd)
          throw failure("\(path) can’t report its size. Nothing was written.")
        }
        let total = blockCount.multipliedReportingOverflow(by: UInt64(blockSize))
        guard !total.overflow, total.partialValue == part.size else {
          close(fd)
          throw failure("\(path) isn’t exactly \(part.identifier). Nothing was written.")
        }
      #else
        close(fd)
        throw failure("Raw devices are written only on macOS.")
      #endif
    } else if info.st_mode & S_IFMT != S_IFREG {
      close(fd)
      throw failure("\(path) is neither a raw device nor a disk image.")
    }
    return (fd, base)
  }

  /// Flushes the device's cache to the medium (DKIOCSYNCHRONIZE on a raw
  /// device), or fsyncs an image.
  static func flush(_ fd: Int32) throws {
    #if canImport(Darwin)
      var info = stat()
      if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR {
        var request = [UInt64](repeating: 0, count: 3)
        guard request.withUnsafeMutableBytes({ ioctl(fd, 0x8018_6416, $0.baseAddress!) }) == 0
        else { throw failure("The disk didn’t confirm the write (errno \(errno)).") }
        return
      }
    #endif
    guard fsync(fd) == 0 else { throw failure("The write didn’t reach the disk (errno \(errno)).") }
  }

  /// Streams `image` onto `part` in whole blocks, counting and hashing what
  /// it writes, flushes, then reads it back and hashes it again. Any
  /// difference fails; the journal isn't marked, so the next attempt writes
  /// it again.
  static func write(
    _ image: FreshWholeDiskImage, to part: WholeDiskPartition, tools: FreshWholeDiskTools,
    progress: (UInt64) -> Void
  ) throws {
    let block = FreshWholeDiskRequest.block
    guard image.size > 0, image.size % block == 0, image.size <= part.size,
      image.sha256.count == 64
    else {
      throw failure(
        "The release’s image (\(image.size) bytes) doesn’t fit \(part.identifier) (\(part.size) bytes) in whole 4 KiB blocks.")
    }
    let (fd, base) = try openTarget(part, tools: tools)
    defer { close(fd) }
    var process: Process?
    let input: FileHandle
    if image.source.hasPrefix("https://") {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: tools.curl)
      p.arguments = [
        "--fail", "--silent", "--show-error", "--location", "--proto", "=https", image.source,
      ]
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardInput = FileHandle.nullDevice
      try p.run()
      process = p
      input = pipe.fileHandleForReading
    } else {
      guard let file = FileHandle(forReadingAtPath: image.source) else {
        throw failure("\(image.source) can’t be read.")
      }
      input = file
    }
    defer { if process == nil { input.closeFile() } }
    var digest = FreshWholeDiskSHA256()
    var done: UInt64 = 0
    var pending = Data()
    // Pipes return what they have; the device takes whole chunks.
    func drain(final: Bool) throws {
      while pending.count >= chunk || (final && !pending.isEmpty) {
        let count = min(pending.count, chunk)
        let piece = pending.prefix(count)
        try pwriteAll(fd, Data(piece), at: base + done)
        done += UInt64(count)
        pending.removeFirst(count)
        progress(done)
      }
    }
    var received: UInt64 = 0
    while true {
      let data = input.readData(ofLength: chunk)
      if data.isEmpty { break }
      received += UInt64(data.count)
      guard received <= image.size else {
        process?.terminate()
        process?.waitUntilExit()
        throw failure("The image is longer than the release says. \(part.identifier) is unfinished.")
      }
      digest.update(data)
      pending.append(data)
      try drain(final: false)
    }
    if let process {
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw failure(
          "The download of the image stopped (curl \(process.terminationStatus)). \(part.identifier) is unfinished.")
      }
    }
    guard received == image.size else {
      throw failure("The image ended after \(received) of \(image.size) bytes. \(part.identifier) is unfinished.")
    }
    try drain(final: true)
    guard digest.finish() == image.sha256.lowercased() else {
      throw failure("The image’s SHA-256 doesn’t match the release. \(part.identifier) is unfinished.")
    }
    try flush(fd)
    // Read back what the disk now holds.
    var check = FreshWholeDiskSHA256()
    var at: UInt64 = 0
    while at < image.size {
      let count = Int(min(UInt64(chunk), image.size - at))
      check.update(try preadAll(fd, count: count, at: base + at))
      at += UInt64(count)
    }
    guard check.finish() == image.sha256.lowercased() else {
      throw failure("\(part.identifier) doesn’t read back as the image. It is unfinished.")
    }
  }

  /// macOS's own Recovery lives in the container this installation deletes.
  /// Refuse when the running system's root is in that container; run it from
  /// System Recovery instead.
  static func refuseFromMacOSRecovery(_ plan: FreshWholeDiskPlan, tools: FreshWholeDiskTools)
    throws
  {
    guard let macOS = plan.macOS else { return }
    let root = (try? plist(run(tools.diskutil, ["info", "-plist", "/"]))) ?? [:]
    let container = root["APFSContainerReference"] as? String
    let store = (root["APFSPhysicalStores"] as? [[String: Any]])?.compactMap {
      $0["APFSPhysicalStore"] as? String
    }
    if container == macOS.reference || store?.contains(plan.macOSPartition!.identifier) == true {
      throw FreshWholeDiskRefusal(
        message:
          "This Recovery runs from the macOS container that would be deleted. Start System Recovery instead: shut down, then press the power button twice and hold it. Nothing was changed."
      )
    }
  }

  // MARK: The installation

  /// Everything from the first reading to a laid-out disk. `confirmed` is
  /// whether the person typed the phrase for this plan; without it a disk
  /// that still holds macOS stops before anything changes. Returns the new
  /// partitions by role.
  @discardableResult
  static func install(
    disk: String, request: FreshWholeDiskRequest, boot: FreshWholeDiskImage,
    root: FreshWholeDiskImage, espLabel: String, espVolumeID: String?, journalURL: URL,
    confirmed: (FreshWholeDiskPlan) -> Bool, tools: FreshWholeDiskTools = FreshWholeDiskTools(),
    log: (String) -> Void
  ) throws -> [FreshWholeDiskRole: WholeDiskPartition] {
    var layout = try read(disk, tools: tools)
    let plan = try FreshWholeDisk.plan(layout, request: request)
    var journal: Journal
    if let saved = try load(journalURL) {
      // Only this disk and these rows; a plan made after macOS went has no
      // macOS, so the macOS partition is compared only when both have one.
      guard saved.disk == disk, saved.rows == rows(plan),
        plan.macOSPartition == nil || saved.macOSPartitionUUID == plan.macOSPartition?.uuid
      else {
        throw failure(
          "The installation journal at \(journalURL.path) is for another plan or disk. Nothing was changed.")
      }
      journal = saved
      log("Resuming the installation from its journal.")
    } else {
      journal = Journal(
        disk: disk, macOSPartitionUUID: plan.macOSPartition?.uuid, rows: rows(plan))
    }
    log(FreshWholeDisk.describe(plan))
    try adopt(&journal, plan: plan, layout: layout)
    try refuseFromMacOSRecovery(plan, tools: tools)
    var guardSteps = 0
    while true {
      guardSteps += 1
      guard guardSteps <= 8 else { throw failure("The installation doesn’t converge. Stopped.") }
      let step = try FreshWholeDisk.next(plan, now: layout)
      switch step {
      case .removeMacOS:
        guard confirmed(plan) else {
          throw failure("macOS was not removed: the confirmation wasn’t given. Nothing was changed.")
        }
        try save(journal, to: journalURL)
        let again = try read(disk, tools: tools)
        try FreshWholeDisk.requireUnchanged(plan, now: again, request: request)
        // By the partition's GPT UUID, as Remove macOS does: a BSD name or
        // container number could name something else after a disk appears.
        log("Deleting \(plan.macOSPartition!.identifier) (partition \(plan.macOSPartition!.uuid)).")
        _ = try run(tools.diskutil, ["apfs", "deleteContainer", plan.macOSPartition!.uuid])
      case .create(let role, let predecessor):
        journal.intent = role.rawValue
        journal.before = layout.partitions.map(\.uuid)
        try save(journal, to: journalURL)
        let arguments = FreshWholeDisk.createArguments(
          role, predecessor: predecessor, plan: plan, request: request)
        log("Creating the \(role.rawValue) partition: diskutil \(arguments.joined(separator: " "))")
        _ = try run(tools.diskutil, arguments)
      case .laidOut:
        let parts = try FreshWholeDisk.verifyLaidOut(plan, after: layout)
        // Contents not yet recorded as written are written now, in order.
        for role in [FreshWholeDiskRole.esp, .boot, .root]
        where !journal.written.contains(role.rawValue) {
          let part = parts[role]!
          guard journal.created[role.rawValue] == part.uuid else {
            throw FreshWholeDiskRefusal(
              message: "\(part.identifier) wasn’t made by this installation. Nothing was written to it.")
          }
          switch role {
          case .esp:
            var arguments = ["-F", "32", "-v", espLabel]
            if let id = espVolumeID { arguments += ["-I", id] }
            log("Formatting \(part.identifier) as the EFI partition.")
            _ = try run(tools.newfsMSDOS, arguments + ["/dev/r" + part.identifier])
          case .boot, .root:
            log("Writing \(role == .boot ? "boot.img" : "root.img") to \(part.identifier).")
            try write(role == .boot ? boot : root, to: part, tools: tools) { _ in }
          case .stub:
            break
          }
          journal.written.append(role.rawValue)
          try save(journal, to: journalURL)
        }
        // The table must still be exactly as laid out after the writes.
        let final = try read(disk, tools: tools)
        let check = try FreshWholeDisk.verifyLaidOut(plan, after: final)
        guard check.mapValues(\.uuid) == parts.mapValues(\.uuid) else {
          throw failure("The partitions changed while their contents were written.")
        }
        log("Laid out: \(FreshWholeDiskRole.allCases.map { "\($0.rawValue) \(check[$0]!.identifier)" }.joined(separator: ", ")).")
        return check
      }
      layout = try read(disk, tools: tools)
      // Each step must have moved the disk forward exactly one step.
      let after = try FreshWholeDisk.next(plan, now: layout)
      guard after != step else {
        throw failure("diskutil reported success but the disk didn’t change. Stopped; nothing more was changed.")
      }
      if case .create = step {
        try adopt(&journal, plan: plan, layout: layout)
        journal.intent = nil
        journal.before = []
        try save(journal, to: journalURL)
      }
    }
  }
}
