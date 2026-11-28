import CommonCrypto
import Foundation
import RecoveryCompression

/// The plain image inside a restore image's Apple Encrypted Archive (profile
/// 1: HKDF-SHA256, AES-256-CTR, HMAC-SHA256, no signature), decoded as the
/// archive streams in, for recoveryOS. The main installer has macOS decode
/// these; this is the same authenticated decode as its restore image helper's
/// range path (macOS/RestoreImage, Ranges.swift) and asahi_firmware/aea_ro.py,
/// read front to back instead of by range:
///
/// - the root header's HMAC, keyed from the archive key, over the metadata,
///   the encrypted root and the first cluster header's MAC;
/// - each cluster header's HMAC, which the root (for the first) or the cluster
///   before it names, so the headers form one chain from the root;
/// - each segment's HMAC, which its cluster header names, before its bytes are
///   decrypted;
/// - each decoded segment's length and SHA-256, also from its cluster header,
///   before a byte of it is handed on.
///
/// The root must carry the restore image's parameters (1 MiB segments, 256 per
/// cluster, LZFSE, SHA-256), the archive's own length, and a plain length no
/// larger than the caller admits; every segment's lengths must be the ones the
/// plain length implies. What follows the last segment, up to the archive
/// length the authenticated root names, is padding (Apple's 26B123 Recovery
/// image has 13.9 MB of it): it is read and dropped, not authenticated and
/// never handed on, as the references never read it.
/// Memory is bounded by one segment plus one input chunk. Anything that fails
/// stops the decode with nothing more handed on; what was handed on is
/// verified, but only `finish` says the image is whole. Nothing here logs or
/// keeps the key beyond the decoder's life.
public enum RestoreImageArchive {
  public enum Failure: Error, Equatable {
    /// The header, the root's parameters, a length or the framing is wrong.
    case invalidArchive
    /// A MAC didn't match: wrong key, or changed bytes.
    case authentication
    /// A decoded segment's length or SHA-256 isn't what its header says.
    case segmentDigest
    /// CommonCrypto refused an operation.
    case cryptor
  }

  /// Segment and cluster sizes. The restore image's are the only ones a
  /// caller outside this file gets; the checks build smaller archives to
  /// cover many clusters in a few KiB.
  struct Profile: Equatable {
    let segmentBytes: Int
    let clusterWidth: Int
    static let restoreImage = Profile(segmentBytes: 1 << 20, clusterWidth: 256)
    var clusterHeaderBytes: Int { clusterWidth * 72 + 32 }
  }

  /// The header, metadata, salt and root header's length, from the first 12
  /// bytes (magic, profile 1, metadata length up to 1 MiB).
  public static func prefixLength(_ head: Data) throws -> Int {
    guard let length = try? RestoreImageKey.metadataLength([UInt8](head.prefix(12))) else {
      throw Failure.invalidArchive
    }
    return 12 + length + 32 + 112
  }

  /// The authenticated root header of an archive whose length is `archiveSize`.
  struct Root {
    let main: [UInt8]
    let plainSize: Int
    let prefixSize: Int
    let firstClusterMAC: [UInt8]

    init(
      _ prefix: [UInt8], archiveKey: [UInt8], archiveSize: Int, maximumOutput: Int,
      profile: Profile
    ) throws {
      guard archiveKey.count == 32, prefix.count >= 12 else { throw Failure.invalidArchive }
      prefixSize = try RestoreImageArchive.prefixLength(Data(prefix[0..<12]))
      guard prefix.count == prefixSize else { throw Failure.invalidArchive }
      let length = prefixSize - 156
      let auth = Array(prefix[12..<(12 + length)])
      let salt = Array(prefix[(12 + length)..<(44 + length)])
      let root = Array(prefix[(44 + length)..<(156 + length)])
      main = try derive(archiveKey, salt: salt, info: Array("AEA_AMK".utf8) + prefix[4..<8], 32)
      let material = try derive(main, info: Array("AEA_RHEK".utf8), 80)
      try authenticate(
        material, Array(root[32..<80]), salt: Array(root[80..<112]) + auth,
        expected: Array(root[0..<32]))
      let plain = try ctr(material, Array(root[32..<80]))
      func little(_ at: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 | UInt64(plain[at + $1]) << (8 * UInt64($1)) }
      }
      guard little(0, 8) > 0, little(0, 8) <= UInt64(maximumOutput),
        little(8, 8) == UInt64(archiveSize), little(16, 4) == UInt64(profile.segmentBytes),
        little(20, 4) == UInt64(profile.clusterWidth), plain[24] == UInt8(ascii: "e"),
        plain[25] == 2
      else { throw Failure.invalidArchive }
      plainSize = Int(little(0, 8))
      firstClusterMAC = Array(root[80..<112])
    }
  }

  /// The plain image's length, once `prefix` (the archive's first
  /// `prefixLength` bytes) authenticates under `archiveKey`: what a writer
  /// must know before the first segment arrives.
  public static func plainSize(
    _ prefix: Data, archiveKey: Data, archiveSize: Int,
    maximumOutput: Int = RestoreImageDirectory.maximumMember
  ) throws -> Int {
    try Root(
      [UInt8](prefix), archiveKey: [UInt8](archiveKey), archiveSize: archiveSize,
      maximumOutput: maximumOutput, profile: .restoreImage
    ).plainSize
  }

  /// Takes the archive's bytes in order, in pieces of any size, and hands on
  /// the plain image one verified segment at a time.
  public final class Decoder {
    struct Segment {
      let size: Int
      let plainSize: Int
      let digest: [UInt8]
      let mac: [UInt8]
    }
    enum Stage {
      case prefix
      case cluster(Int)
      case segment(cluster: Int, index: Int)
      case done
    }

    let key: [UInt8]
    let archiveSize: Int
    let maximumOutput: Int
    let profile: Profile
    var stage = Stage.prefix
    var root: Root?
    var clusterKey: [UInt8] = []
    var segments: [Segment] = []
    var nextMAC: [UInt8] = []
    var buffer: [UInt8] = []
    var cursor = 0
    var consumed = 0
    var produced = 0
    var hash = RecoveryDigest.Stream()

    public convenience init(
      archiveKey: Data, archiveSize: Int, maximumOutput: Int = RestoreImageDirectory.maximumMember
    ) throws {
      try self.init(
        archiveKey: archiveKey, archiveSize: archiveSize, maximumOutput: maximumOutput,
        profile: .restoreImage)
    }

    init(
      archiveKey: Data, archiveSize: Int,
      maximumOutput: Int = RestoreImageDirectory.maximumMember, profile: Profile
    ) throws {
      guard archiveKey.count == 32, archiveSize > 0, maximumOutput > 0 else {
        throw Failure.invalidArchive
      }
      key = [UInt8](archiveKey)
      self.archiveSize = archiveSize
      self.maximumOutput = maximumOutput
      self.profile = profile
    }

    /// The plain length, once the root header has authenticated.
    public var plainSize: Int? { root?.plainSize }

    /// The next `count` buffered bytes, or nil until that many have arrived.
    func take(_ count: Int) -> [UInt8]? {
      guard buffer.count - cursor >= count else { return nil }
      defer { cursor += count }
      return Array(buffer[cursor..<(cursor + count)])
    }

    public func consume(_ data: Data, output: (Data) throws -> Void) throws {
      guard data.count <= archiveSize - consumed else { throw Failure.invalidArchive }
      consumed += data.count
      if cursor > 0 {
        buffer.removeFirst(cursor)
        cursor = 0
      }
      buffer += data
      while try step(output) {}
    }

    /// One unit (the prefix, a cluster header or a segment) if all of it is here.
    func step(_ output: (Data) throws -> Void) throws -> Bool {
      switch stage {
      case .prefix:
        guard buffer.count - cursor >= 12 else { return false }
        let length = try RestoreImageArchive.prefixLength(Data(buffer[cursor..<(cursor + 12)]))
        guard let prefix = take(length) else { return false }
        let root = try Root(
          prefix, archiveKey: key, archiveSize: archiveSize, maximumOutput: maximumOutput,
          profile: profile)
        self.root = root
        nextMAC = root.firstClusterMAC
        stage = .cluster(0)
      case .cluster(let index):
        guard let header = take(profile.clusterHeaderBytes) else { return false }
        try openCluster(index, header)
        stage = .segment(cluster: index, index: 0)
      case .segment(let cluster, let index):
        guard index < segments.count, segments[index].plainSize > 0 else {
          let total = (root!.plainSize + profile.segmentBytes - 1) / profile.segmentBytes
          stage =
            (cluster + 1) * profile.clusterWidth < total ? .cluster(cluster + 1) : .done
          return true
        }
        let segment = segments[index]
        guard let body = take(segment.size) else { return false }
        let material = try derive(clusterKey, info: indexed("AEA_SK", index), 80)
        try authenticate(material, body, salt: [], expected: segment.mac)
        var plain = try ctr(material, body)
        if segment.size != segment.plainSize {
          plain = try boundedLZFSE(plain, maximum: segment.plainSize, profile: profile)
        }
        guard plain.count == segment.plainSize, sha256(plain) == segment.digest else {
          throw Failure.segmentDigest
        }
        let data = Data(plain)
        hash.update(data)
        produced += plain.count
        stage = .segment(cluster: cluster, index: index + 1)
        try output(data)
      case .done:
        // Padding up to the archive length the root names: never authenticated
        // (the references never read it) and never handed on.
        buffer.removeAll()
        cursor = 0
        return false
      }
      return true
    }

    /// Authenticates cluster header `index` against the MAC the chain names
    /// for it and reads its segments' lengths, digests and MACs.
    func openCluster(_ index: Int, _ header: [UInt8]) throws {
      guard let root else { throw Failure.invalidArchive }
      let width = profile.clusterWidth
      let split = width * 40
      clusterKey = try derive(root.main, info: indexed("AEA_CK", index), 32)
      let material = try derive(clusterKey, info: Array("AEA_CHEK".utf8), 80)
      try authenticate(
        material, Array(header[0..<split]), salt: Array(header[split...]), expected: nextMAC)
      let plain = try ctr(material, Array(header[0..<split]))
      // Where this cluster's first segment starts in the archive.
      var offset = consumed - (buffer.count - cursor)
      segments = []
      for slot in 0..<width {
        let entry = Array(plain[(slot * 40)..<(slot * 40 + 40)])
        let plainSize = entry[0..<4].reversed().reduce(0) { $0 << 8 | Int($1) }
        let size = entry[4..<8].reversed().reduce(0) { $0 << 8 | Int($1) }
        let id = index * width + slot
        let wanted = min(profile.segmentBytes, max(0, root.plainSize - id * profile.segmentBytes))
        guard plainSize == wanted, size <= plainSize, plainSize == 0 || size > 0,
          offset <= archiveSize - size
        else { throw Failure.invalidArchive }
        let mac = Array(header[(split + 32 + slot * 32)..<(split + 64 + slot * 32)])
        segments.append(
          Segment(size: size, plainSize: plainSize, digest: Array(entry[8..<40]), mac: mac))
        offset += size
      }
      nextMAC = Array(header[split..<(split + 32)])
    }

    /// The plain image's length and SHA-256, once the whole archive has been
    /// consumed and every segment verified.
    public func finish() throws -> (bytes: Int, sha256: String) {
      guard case .done = stage, cursor == buffer.count, consumed == archiveSize,
        let root, produced == root.plainSize
      else { throw Failure.invalidArchive }
      return (produced, hash.finish())
    }
  }

  // MARK: Primitives (the reference's deriveRange, rangeMAC, rangeCTR)

  static func derive(_ key: [UInt8], salt: [UInt8] = [], info: [UInt8], _ size: Int) throws
    -> [UInt8]
  {
    do {
      return try RestoreImageKey.expand(
        prk: RestoreImageKey.extract(salt: salt, ikm: key), info: info, length: size)
    } catch { throw Failure.cryptor }
  }

  static func indexed(_ name: String, _ index: Int) -> [UInt8] {
    Array(name.utf8) + (0..<4).map { UInt8(truncatingIfNeeded: UInt32(index) >> (8 * $0)) }
  }

  /// HMAC-SHA256 under the material's first 32 bytes over salt, data and the
  /// salt's length (64-bit little-endian), compared without an early exit.
  static func authenticate(_ material: [UInt8], _ data: [UInt8], salt: [UInt8], expected: [UInt8])
    throws
  {
    let count = UInt64(salt.count)
    let size = (0..<8).map { UInt8(truncatingIfNeeded: count >> (8 * UInt64($0))) }
    let mac = RestoreImageKey.hmac(Array(material[0..<32]), salt + data + size)
    var difference = UInt8(expected.count == 32 ? 0 : 1)
    for (a, b) in zip(mac, expected) { difference |= a ^ b }
    guard difference == 0 else { throw Failure.authentication }
  }

  /// AES-256-CTR with key material[32..<64] and a 128-bit big-endian counter
  /// starting at material[64..<80].
  static func ctr(_ material: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
    guard material.count == 80 else { throw Failure.cryptor }
    if data.isEmpty { return [] }
    let key = Array(material[32..<64])
    let iv = Array(material[64..<80])
    var cryptor: CCCryptorRef?
    let created = key.withUnsafeBytes { k in
      iv.withUnsafeBytes { i in
        CCCryptorCreateWithMode(
          CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
          CCPadding(ccNoPadding), i.baseAddress, k.baseAddress, key.count, nil, 0, 0,
          CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
      }
    }
    guard created == CCCryptorStatus(kCCSuccess), let cryptor else { throw Failure.cryptor }
    defer { CCCryptorRelease(cryptor) }
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    let status = data.withUnsafeBytes { d in
      out.withUnsafeMutableBytes { o in
        CCCryptorUpdate(cryptor, d.baseAddress, data.count, o.baseAddress, data.count, &moved)
      }
    }
    guard status == CCCryptorStatus(kCCSuccess), moved == data.count else {
      throw Failure.cryptor
    }
    return out
  }

  static func sha256(_ bytes: [UInt8]) -> [UInt8] {
    var context = CC_SHA256_CTX()
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    guard CC_SHA256_Init(&context) == 1 else { return [] }
    var offset = 0
    let ok = bytes.withUnsafeBytes { buffer -> Bool in
      while offset < buffer.count {
        let count = min(buffer.count - offset, 1 << 30)
        guard
          CC_SHA256_Update(&context, buffer.baseAddress!.advanced(by: offset), CC_LONG(count))
            == 1
        else { return false }
        offset += count
      }
      return true
    }
    guard ok, CC_SHA256_Final(&digest, &context) == 1 else { return [] }
    return digest
  }

  // MARK: LZFSE (the reference's boundedLZFSE)

  /// An LZFSE stream that must decode to exactly `maximum` bytes: its block
  /// headers are walked first, so a stream that claims more output, more
  /// matches than a segment can hold, or bytes past its end-of-stream block
  /// is refused before libcompression sees it.
  static func boundedLZFSE(_ data: [UInt8], maximum: Int, profile: Profile = .restoreImage) throws
    -> [UInt8]
  {
    func u32(_ at: Int) throws -> Int {
      guard at >= 0, at <= data.count - 4 else { throw Failure.segmentDigest }
      return data[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | Int($1) }
    }
    func u64(_ at: Int) throws -> UInt64 {
      guard at >= 0, at <= data.count - 8 else { throw Failure.segmentDigest }
      return data[at..<(at + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    var offset = 0
    var total = 0
    var expansion = 0
    while true {
      guard offset <= data.count - 4 else { throw Failure.segmentDigest }
      let magic = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
      if magic == "bvx$" {
        guard offset + 4 == data.count, total == maximum else { throw Failure.segmentDigest }
        break
      }
      let raw = try u32(offset + 4)
      total += raw
      guard raw <= maximum, total <= maximum else { throw Failure.segmentDigest }
      var header: Int
      var payload: Int
      var matches = 0
      switch magic {
      case "bvx-":
        header = 8
        payload = raw
      case "bvxn":
        header = 12
        payload = try u32(offset + 8)
      case "bvx1":
        guard offset <= data.count - 772, try u32(offset + 12) <= profile.segmentBytes + 4 else {
          throw Failure.segmentDigest
        }
        matches = try u32(offset + 16)
        header = 772
        payload = try u32(offset + 20) + u32(offset + 24)
      case "bvx2":
        guard offset <= data.count - 32 else { throw Failure.segmentDigest }
        let v0 = try u64(offset + 8)
        let v1 = try u64(offset + 16)
        matches = Int((v0 >> 40) & 0xfffff)
        header = try u32(offset + 24)
        payload = Int((v0 >> 20) & 0xfffff) + Int((v1 >> 40) & 0xfffff)
        guard header >= 32 else { throw Failure.segmentDigest }
      default:
        throw Failure.segmentDigest
      }
      expansion += raw + matches * (315 + 2359)
      guard expansion <= 512 << 20, header + payload <= data.count - offset else {
        throw Failure.segmentDigest
      }
      offset += header + payload
    }
    // One byte more than the stream declares shows one that decodes to more.
    var out = [UInt8](repeating: 0, count: maximum + 1)
    let count = data.withUnsafeBufferPointer { source in
      out.withUnsafeMutableBufferPointer { target in
        aurora_lzfse_decode(target.baseAddress!, target.count, source.baseAddress!, source.count)
      }
    }
    guard count == maximum else { throw Failure.segmentDigest }
    return Array(out.prefix(maximum))
  }
}

extension RestoreImageDirectory {
  /// The first `count` bytes of a member's body, from at most 8 MiB of input
  /// when it is deflated.
  public func prefix(_ entry: Entry, count: Int, read: Read) throws -> Data {
    guard count > 0, count <= entry.size else { throw Failure.invalidArchive }
    struct Enough: Error {}
    var prefix = Data()
    do {
      try stream(
        entry, chunkBytes: min(max(count, 65536), 2 << 20), maximumInput: max(count, 8 << 20),
        read: read
      ) { bytes in
        prefix += bytes.prefix(count - prefix.count)
        if prefix.count == count { throw Enough() }
      }
    } catch is Enough {}
    guard prefix.count == count else { throw Failure.invalidArchive }
    return prefix
  }

  /// An Apple Encrypted Archive member's header, metadata, salt and root
  /// header: what its key and plain length are read from.
  public func appleEncryptedPrefix(_ entry: Entry, read: Read) throws -> Data {
    let length = try RestoreImageArchive.prefixLength(prefix(entry, count: 12, read: read))
    return try prefix(entry, count: length, read: read)
  }
}
