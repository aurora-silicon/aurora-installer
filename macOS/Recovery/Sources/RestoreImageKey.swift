import CommonCrypto
import Foundation

/// The archive key of a restore image's Apple Encrypted Archive, opened with
/// what every recoveryOS has. The main installer's restore image helper opens
/// it with CryptoKit; the Recovery app may run where CryptoKit doesn't exist
/// (see README), so this file carries the one HPKE suite the key uses:
/// RFC 9180 base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM.
///
/// The AEA's `com.apple.wkms.fcs-response` holds the HPKE encapsulation and
/// the wrapped 32-byte archive key; the private key is the PKCS#8 file at
/// the AEA's `com.apple.wkms.fcs-key-url`, which anyone can fetch. P-256 ECDH
/// is Security.framework's (RestoreImageKeyAgreement.swift); HMAC-SHA256 and
/// the AES block function come from CommonCrypto in libSystem. Only the HPKE
/// key schedule, GHASH and the PKCS#8 reader are here. The release key isn't a
/// secret of this Mac or its owner, so none of it needs to be constant time.
public enum RestoreImageKey {
  public enum Failure: Error, Equatable {
    /// The PEM isn't a PKCS#8 P-256 private key, or its public key doesn't match.
    case invalidPrivateKey
    /// The FCS response isn't the JSON the key needs, or its fields have the wrong size.
    case invalidResponse
    /// The encapsulated key isn't a point on P-256.
    case invalidPoint
    /// The wrapped key didn't authenticate under this private key.
    case authentication
    /// The archive header or its metadata is malformed.
    case invalidArchive
    /// CommonCrypto refused an operation.
    case cryptor
  }

  // MARK: AEA metadata

  static func little(_ bytes: [UInt8], _ at: Int) throws -> Int {
    guard at >= 0, at + 4 <= bytes.count else { throw Failure.invalidArchive }
    return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16
      | Int(bytes[at + 3]) << 24
  }

  /// The metadata length of an AEA1 header with profile 1 (HKDF-SHA256,
  /// AES-256-CTR, HMAC-SHA256, no signature), the only profile the restore
  /// image uses, after checking the magic and profile.
  static func metadataLength(_ bytes: [UInt8]) throws -> Int {
    guard bytes.count >= 12, Array(bytes[0..<4]) == Array("AEA1".utf8), try little(bytes, 4) == 1
    else { throw Failure.invalidArchive }
    let length = try little(bytes, 8)
    guard length > 0, length <= 1024 * 1024 else { throw Failure.invalidArchive }
    return length
  }

  /// The metadata of an AEA (profile 1) from the first bytes of the file.
  public static func metadata(_ data: Data) throws -> [String: Data] {
    let bytes = [UInt8](data)
    let length = try metadataLength(bytes)
    guard 12 + length <= bytes.count else { throw Failure.invalidArchive }
    var offset = 12
    let end = 12 + length
    var result: [String: Data] = [:]
    while offset < end {
      let size = try little(bytes, offset)
      guard size >= 6, size <= end - offset else { throw Failure.invalidArchive }
      let entry = bytes[(offset + 4)..<(offset + size)]
      guard let zero = entry.firstIndex(of: 0), zero > entry.startIndex,
        let key = String(bytes: entry[entry.startIndex..<zero], encoding: .utf8),
        result[key] == nil
      else { throw Failure.invalidArchive }
      result[key] = Data(entry[(zero + 1)...])
      offset += size
    }
    return result
  }

  /// The fetch URL of the archive's private key: Apple's public FCS key
  /// service only, as the restore image helper admits it.
  public static func keyURL(_ metadata: [String: Data]) throws -> URL {
    let pattern =
      #"^https://(wkms-public\.apple\.com|fcs-keys-pub-prod\.cdn-apple\.com)/fcs-keys/[A-Za-z0-9_-]{43}=\z"#
    guard let raw = metadata["com.apple.wkms.fcs-key-url"],
      let text = String(data: raw, encoding: .utf8),
      text.range(of: pattern, options: .regularExpression) != nil, let url = URL(string: text)
    else { throw Failure.invalidArchive }
    return url
  }

  /// Checks that `archiveKey` opens this archive: the root header's HMAC
  /// under the key schedule AEA derives from it (the restore image helper's
  /// range decoder does the same before it reads a byte of the image).
  /// This proves the key and the archive belong together, not that Apple
  /// made the archive: the release key is public, so anyone can wrap a key
  /// for it. The archive's origin comes from the pinned restore image and
  /// member digests the caller checks, as the helper's recipe does.
  /// `head` must start at the archive's first byte; its magic and profile
  /// are checked here as in `metadata`.
  public static func authenticateRoot(_ head: Data, archiveKey: Data) throws {
    let bytes = [UInt8](head)
    guard archiveKey.count == 32 else { throw Failure.invalidArchive }
    let length = try metadataLength(bytes)
    guard bytes.count >= 12 + length + 32 + 112 else { throw Failure.invalidArchive }
    let auth = Array(bytes[12..<(12 + length)])
    let salt = Array(bytes[(12 + length)..<(44 + length)])
    let root = Array(bytes[(44 + length)..<(156 + length)])
    let main = try expand(
      prk: extract(salt: salt, ikm: [UInt8](archiveKey)),
      info: Array("AEA_AMK".utf8) + bytes[4..<8], length: 32)
    let material = try expand(
      prk: extract(salt: [], ikm: main), info: Array("AEA_RHEK".utf8), length: 80)
    let macSalt = Array(root[80..<112]) + auth
    let count = UInt64(macSalt.count)
    let size: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: count >> (8 * UInt64($0))) }
    let mac = hmac(Array(material[0..<32]), macSalt + Array(root[32..<80]) + size)
    var difference: UInt8 = 0
    for (a, b) in zip(mac, root[0..<32]) { difference |= a ^ b }
    guard difference == 0 else { throw Failure.authentication }
  }

  // MARK: Key unwrap

  /// The 32-byte archive key: the AEA's FCS response opened with the
  /// PKCS#8 PEM private key fetched from its key URL.
  public static func unwrap(_ metadata: [String: Data], releaseKey: Data) throws -> Data {
    guard let response = metadata["com.apple.wkms.fcs-response"] else {
      throw Failure.invalidResponse
    }
    return try unwrap(fcsResponse: response, releaseKey: releaseKey)
  }

  public static func unwrap(fcsResponse: Data, releaseKey: Data) throws -> Data {
    let key = try PrivateKey(pem: releaseKey)
    guard let object = try? JSONSerialization.jsonObject(with: fcsResponse) as? [String: String],
      let encoded = object["enc-request"], let sealed = object["wrapped-key"],
      let enc = Data(base64Encoded: encoded), enc.count == 65,
      enc.base64EncodedString() == encoded,
      let wrapped = Data(base64Encoded: sealed), wrapped.count == 48,
      wrapped.base64EncodedString() == sealed
    else { throw Failure.invalidResponse }
    let opened = try open(
      key, encapsulated: [UInt8](enc), ciphertext: [UInt8](wrapped), info: [])
    guard opened.count == 32 else { throw Failure.authentication }
    return Data(opened)
  }

  /// A P-256 private key with its public point.
  public struct PrivateKey {
    let scalar: [UInt8]
    let publicKey: [UInt8]

    /// The group order n of P-256, big-endian.
    static let order: [UInt8] = [
      0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff, 0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63,
      0x25, 0x51,
    ]
    /// The P-256 base point G, uncompressed (SEC 2 2.4.2).
    static let generator: [UInt8] = [
      0x04, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4,
      0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8,
      0x98, 0xc2, 0x96, 0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a,
      0x7c, 0x0f, 0x9e, 0x16, 0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40,
      0x68, 0x37, 0xbf, 0x51, 0xf5,
    ]

    /// A scalar in [1, n-1] and its uncompressed public point, which must be
    /// on the curve (Security imports it as an ECDH peer) and have the
    /// x-coordinate of scalar*G (ECDH of the scalar with G). ECDH yields x
    /// only, so the point -(scalar*G) is admitted here; HPKE binds the full
    /// point into its key schedule, so `open` then fails to authenticate.
    init(scalar: [UInt8], publicKey: [UInt8]) throws {
      guard scalar.count == 32, scalar.contains(where: { $0 != 0 }),
        scalar.lexicographicallyPrecedes(Self.order), publicKey.count == 65, publicKey[0] == 0x04
      else { throw Failure.invalidPrivateKey }
      self.scalar = scalar
      self.publicKey = publicKey
      guard (try? RestoreImageKey.agree(self, peer: publicKey)) != nil,
        (try? RestoreImageKey.agree(self, peer: Self.generator)) == Array(publicKey[1..<33])
      else { throw Failure.invalidPrivateKey }
    }

    /// PKCS#8 (RFC 5208) PEM holding an RFC 5915 ECPrivateKey on P-256 with
    /// its public key, as Apple's FCS release keys and CryptoKit's
    /// `pemRepresentation` carry it. Without the curve arithmetic here, a key
    /// that omits the public key is refused rather than completed.
    public init(pem: Data) throws {
      guard let text = String(data: pem, encoding: .utf8) else { throw Failure.invalidPrivateKey }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let head = "-----BEGIN PRIVATE KEY-----"
      let tail = "-----END PRIVATE KEY-----"
      guard trimmed.hasPrefix(head), trimmed.hasSuffix(tail),
        trimmed.count > head.count + tail.count
      else { throw Failure.invalidPrivateKey }
      let body = trimmed.dropFirst(head.count).dropLast(tail.count)
        .filter { !$0.isWhitespace }
      guard let der = Data(base64Encoded: String(body)) else { throw Failure.invalidPrivateKey }
      let (scalar, embedded) = try DER.pkcs8(der: [UInt8](der))
      guard let embedded else { throw Failure.invalidPrivateKey }
      try self.init(scalar: scalar, publicKey: embedded)
    }

    public var publicKeyRepresentation: Data { Data(publicKey) }

    /// SEC 1 2.3.3 uncompressed point followed by the scalar, the form
    /// `SecKeyCreateWithData` takes for an EC private key.
    var x963: [UInt8] { publicKey + scalar }
  }

  /// RFC 9180 single-shot open (sequence 0), base mode. The FCS response
  /// uses empty info and AAD; the published test vectors don't.
  static func open(
    _ key: PrivateKey, encapsulated enc: [UInt8], ciphertext: [UInt8], info: [UInt8],
    aad: [UInt8] = []
  ) throws -> [UInt8] {
    guard ciphertext.count >= 16 else { throw Failure.authentication }
    guard enc.count == 65, enc[0] == 0x04 else { throw Failure.invalidPoint }
    let dh = try agree(key, peer: enc)

    let kemSuite = Array("KEM".utf8) + [0x00, 0x10]
    let hpkeSuite = Array("HPKE".utf8) + [0x00, 0x10, 0x00, 0x01, 0x00, 0x02]
    let eaePRK = try labeledExtract(kemSuite, salt: [], label: "eae_prk", ikm: dh)
    let sharedSecret = try labeledExpand(
      kemSuite, prk: eaePRK, label: "shared_secret", info: enc + key.publicKey, length: 32)
    let pskIDHash = try labeledExtract(hpkeSuite, salt: [], label: "psk_id_hash", ikm: [])
    let infoHash = try labeledExtract(hpkeSuite, salt: [], label: "info_hash", ikm: info)
    let context = [0x00] + pskIDHash + infoHash
    let secret = try labeledExtract(hpkeSuite, salt: sharedSecret, label: "secret", ikm: [])
    let aeadKey = try labeledExpand(hpkeSuite, prk: secret, label: "key", info: context, length: 32)
    let nonce = try labeledExpand(
      hpkeSuite, prk: secret, label: "base_nonce", info: context, length: 12)
    return try GCM.open(key: aeadKey, nonce: nonce, sealed: ciphertext, aad: aad)
  }

  // MARK: HKDF-SHA256 (RFC 5869) on CommonCrypto's HMAC

  static func hmac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    key.withUnsafeBytes { k in
      message.withUnsafeBytes { m in
        CCHmac(
          CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, m.baseAddress,
          message.count, &out)
      }
    }
    return out
  }

  static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
    hmac(salt.isEmpty ? [UInt8](repeating: 0, count: 32) : salt, ikm)
  }

  static func expand(prk: [UInt8], info: [UInt8], length: Int) throws -> [UInt8] {
    guard length > 0, length <= 255 * 32 else { throw Failure.cryptor }
    var out: [UInt8] = []
    var block: [UInt8] = []
    var counter: UInt8 = 1
    while out.count < length {
      block = hmac(prk, block + info + [counter])
      out += block
      counter &+= 1
    }
    return Array(out.prefix(length))
  }

  /// HKDF-SHA256 extract then expand, as AEA derives its key schedule.
  public static func derive(_ key: Data, salt: Data = Data(), info: Data, size: Int) throws -> Data
  {
    Data(
      try expand(
        prk: extract(salt: [UInt8](salt), ikm: [UInt8](key)), info: [UInt8](info), length: size))
  }

  static func labeledExtract(_ suite: [UInt8], salt: [UInt8], label: String, ikm: [UInt8])
    throws -> [UInt8]
  {
    extract(salt: salt, ikm: Array("HPKE-v1".utf8) + suite + Array(label.utf8) + ikm)
  }

  static func labeledExpand(
    _ suite: [UInt8], prk: [UInt8], label: String, info: [UInt8], length: Int
  ) throws -> [UInt8] {
    let labeled =
      [UInt8(length >> 8), UInt8(length & 0xff)] + Array("HPKE-v1".utf8) + suite
      + Array(label.utf8) + info
    return try expand(prk: prk, info: labeled, length: length)
  }

  // MARK: AES-256-GCM open (NIST SP 800-38D), AES from CommonCrypto

  enum GCM {
    static func blocks(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
      var out = [UInt8](repeating: 0, count: input.count)
      var moved = 0
      let status = key.withUnsafeBytes { k in
        input.withUnsafeBytes { i in
          out.withUnsafeMutableBytes { o in
            CCCrypt(
              CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionECBMode), k.baseAddress, key.count, nil, i.baseAddress,
              input.count, o.baseAddress, input.count, &moved)
          }
        }
      }
      guard status == CCCryptorStatus(kCCSuccess), moved == input.count else {
        throw Failure.cryptor
      }
      return out
    }

    struct Element: Equatable {
      var hi: UInt64
      var lo: UInt64
      init(_ hi: UInt64, _ lo: UInt64) {
        self.hi = hi
        self.lo = lo
      }
      init(_ bytes: ArraySlice<UInt8>) {
        var padded = Array(bytes)
        padded += [UInt8](repeating: 0, count: 16 - padded.count)
        hi = padded[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
        lo = padded[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
      }
      var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: hi >> (56 - 8 * $0)) }
          + (0..<8).map { UInt8(truncatingIfNeeded: lo >> (56 - 8 * $0)) }
      }
      static func ^ (a: Element, b: Element) -> Element { Element(a.hi ^ b.hi, a.lo ^ b.lo) }

      /// Multiplication in GCM's GF(2^128), bit-reflected (SP 800-38D 6.3).
      func times(_ y: Element) -> Element {
        var z = Element(0, 0)
        var v = y
        for i in 0..<128 {
          let bit = i < 64 ? (hi >> (63 - UInt64(i))) & 1 : (lo >> (127 - UInt64(i))) & 1
          if bit == 1 { z = z ^ v }
          let carry = v.lo & 1
          v.lo = v.lo >> 1 | v.hi << 63
          v.hi >>= 1
          if carry == 1 { v.hi ^= 0xe100_0000_0000_0000 }
        }
        return z
      }
    }

    static func open(key: [UInt8], nonce: [UInt8], sealed: [UInt8], aad: [UInt8] = []) throws
      -> [UInt8]
    {
      guard key.count == 32, nonce.count == 12, sealed.count >= 16 else { throw Failure.cryptor }
      let ciphertext = Array(sealed.dropLast(16))
      let tag = Array(sealed.suffix(16))
      let count = (ciphertext.count + 15) / 16
      // Counter blocks J0, inc32(J0), ...: block 0 masks the tag, the rest the data.
      var counters: [UInt8] = []
      for index in 0...count {
        let value = UInt32(1) &+ UInt32(index)
        counters += nonce + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
      }
      let stream = try blocks(key: key, [UInt8](repeating: 0, count: 16) + counters)
      let h = Element(stream[0..<16])
      var y = Element(0, 0)
      for data in [aad, ciphertext] {
        var offset = 0
        while offset < data.count {
          y = (y ^ Element(data[offset..<min(offset + 16, data.count)])).times(h)
          offset += 16
        }
      }
      y = (y ^ Element(UInt64(aad.count) * 8, UInt64(ciphertext.count) * 8)).times(h)
      let expected = zip((y ^ Element(stream[16..<32])).bytes, tag).reduce(UInt8(0)) {
        $0 | ($1.0 ^ $1.1)
      }
      guard expected == 0 else { throw Failure.authentication }
      return ciphertext.enumerated().map { $0.element ^ stream[32 + $0.offset] }
    }
  }

  // MARK: DER (PKCS#8 / RFC 5915), strict for the one shape the key has

  enum DER {
    struct Reader {
      let bytes: [UInt8]
      var at: Int
      let end: Int
      init(_ bytes: [UInt8], at: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.at = at
        self.end = end ?? bytes.count
      }
      var done: Bool { at == end }
      mutating func element(_ tag: UInt8) throws -> Reader {
        guard at + 2 <= end, bytes[at] == tag else { throw Failure.invalidPrivateKey }
        var length = Int(bytes[at + 1])
        var start = at + 2
        if length & 0x80 != 0 {
          let size = length & 0x7f
          guard size >= 1, size <= 2, start + size <= end else { throw Failure.invalidPrivateKey }
          length = bytes[start..<(start + size)].reduce(0) { $0 << 8 | Int($1) }
          guard length >= 0x80, size == 1 || length > 0xff else { throw Failure.invalidPrivateKey }
          start += size
        }
        guard start + length <= end else { throw Failure.invalidPrivateKey }
        at = start + length
        return Reader(bytes, at: start, end: start + length)
      }
      var contents: [UInt8] { Array(bytes[at..<end]) }
      func peek(_ tag: UInt8) -> Bool { at < end && bytes[at] == tag }
    }

    static let ecPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    static let prime256v1: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

    /// The scalar and, if present, the public key of a PKCS#8 P-256 key.
    static func pkcs8(der: [UInt8]) throws -> ([UInt8], [UInt8]?) {
      var outer = Reader(der)
      var info = try outer.element(0x30)
      guard outer.done, try info.element(0x02).contents == [0x00] else {
        throw Failure.invalidPrivateKey
      }
      var algorithm = try info.element(0x30)
      guard try algorithm.element(0x06).contents == ecPublicKey,
        try algorithm.element(0x06).contents == prime256v1, algorithm.done
      else { throw Failure.invalidPrivateKey }
      var octets = try info.element(0x04)
      // Optional PKCS#8 attributes [0] may follow; nothing else.
      if info.peek(0xa0) { _ = try info.element(0xa0) }
      guard info.done else { throw Failure.invalidPrivateKey }
      var key = try octets.element(0x30)
      guard octets.done, try key.element(0x02).contents == [0x01] else {
        throw Failure.invalidPrivateKey
      }
      let scalar = try key.element(0x04).contents
      guard scalar.count == 32 else { throw Failure.invalidPrivateKey }
      if key.peek(0xa0) {
        var parameters = try key.element(0xa0)
        guard try parameters.element(0x06).contents == prime256v1, parameters.done else {
          throw Failure.invalidPrivateKey
        }
      }
      var publicKey: [UInt8]?
      if key.peek(0xa1) {
        var wrapper = try key.element(0xa1)
        let bits = try wrapper.element(0x03).contents
        guard wrapper.done, bits.count == 66, bits[0] == 0 else { throw Failure.invalidPrivateKey }
        publicKey = Array(bits.dropFirst())
      }
      guard key.done else { throw Failure.invalidPrivateKey }
      return (scalar, publicKey)
    }
  }
}
