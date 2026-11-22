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
/// the AEA's `com.apple.wkms.fcs-key-url`, which anyone can fetch. Because
/// that key isn't a secret of this Mac or its owner, the curve arithmetic
/// below is plain (not constant time). HMAC-SHA256 and the AES block
/// function come from CommonCrypto in libSystem.
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

  /// The metadata of an AEA (profile 1) from the first bytes of the file.
  public static func metadata(_ data: Data) throws -> [String: Data] {
    let bytes = [UInt8](data)
    func little(_ at: Int) throws -> Int {
      guard at >= 0, at + 4 <= bytes.count else { throw Failure.invalidArchive }
      return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16
        | Int(bytes[at + 3]) << 24
    }
    guard bytes.count >= 12, Array(bytes[0..<4]) == Array("AEA1".utf8), try little(4) == 1
    else { throw Failure.invalidArchive }
    let length = try little(8)
    guard length > 0, length <= 1024 * 1024, 12 + length <= bytes.count else {
      throw Failure.invalidArchive
    }
    var offset = 12
    let end = 12 + length
    var result: [String: Data] = [:]
    while offset < end {
      let size = try little(offset)
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
  public static func authenticateRoot(_ head: Data, archiveKey: Data) throws {
    let bytes = [UInt8](head)
    guard bytes.count >= 12, archiveKey.count == 32 else { throw Failure.invalidArchive }
    let length =
      Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
    guard length > 0, length <= 1024 * 1024, bytes.count >= 12 + length + 32 + 112 else {
      throw Failure.invalidArchive
    }
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

    public init(scalar: [UInt8]) throws {
      guard scalar.count == 32, let d = P256.scalar(scalar) else {
        throw Failure.invalidPrivateKey
      }
      self.scalar = scalar
      publicKey = P256.encode(P256.multiply(P256.generator, d))
    }

    /// PKCS#8 (RFC 5208) PEM holding an RFC 5915 ECPrivateKey on P-256.
    /// The embedded public key, if present, must be the scalar's.
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
      try self.init(scalar: scalar)
      if let embedded, embedded != publicKey { throw Failure.invalidPrivateKey }
    }

    public var publicKeyRepresentation: Data { Data(publicKey) }
  }

  /// RFC 9180 single-shot open, base mode, empty AAD.
  static func open(
    _ key: PrivateKey, encapsulated enc: [UInt8], ciphertext: [UInt8], info: [UInt8]
  ) throws -> [UInt8] {
    guard ciphertext.count >= 16 else { throw Failure.authentication }
    guard let point = P256.decode(enc) else { throw Failure.invalidPoint }
    guard let d = P256.scalar(key.scalar) else { throw Failure.invalidPrivateKey }
    let shared = P256.multiply(point, d)
    guard let affine = P256.affine(shared) else { throw Failure.invalidPoint }
    let dh = P256.bytes(affine.x)

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
    return try GCM.open(key: aeadKey, nonce: nonce, sealed: ciphertext)
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

    static func open(key: [UInt8], nonce: [UInt8], sealed: [UInt8]) throws -> [UInt8] {
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
      var offset = 0
      while offset < ciphertext.count {
        y = (y ^ Element(ciphertext[offset..<min(offset + 16, ciphertext.count)])).times(h)
        offset += 16
      }
      y = (y ^ Element(0, UInt64(ciphertext.count) * 8)).times(h)
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

  // MARK: P-256 (SEC 2), Montgomery field arithmetic on four 64-bit limbs

  enum P256 {
    typealias Limbs = [UInt64]  // little-endian, four limbs

    struct Field {
      let modulus: Limbs
      let inverse: UInt64  // -modulus^-1 mod 2^64
      let rSquared: Limbs

      init(_ modulus: Limbs) {
        self.modulus = modulus
        var inv: UInt64 = 1
        for _ in 0..<6 { inv = inv &* (2 &- modulus[0] &* inv) }
        inverse = 0 &- inv
        // R mod m = 2^256 - m for a modulus above 2^255; double it 256 times for R^2.
        var r = P256.subtract([0, 0, 0, 0], modulus).0
        for _ in 0..<256 { r = Field.addMod(r, r, modulus) }
        rSquared = r
      }

      static func addMod(_ a: Limbs, _ b: Limbs, _ m: Limbs) -> Limbs {
        let (sum, carry) = P256.add(a, b)
        let (reduced, borrow) = P256.subtract(sum, m)
        return carry || !borrow ? reduced : sum
      }
      func add(_ a: Limbs, _ b: Limbs) -> Limbs { Field.addMod(a, b, modulus) }
      func sub(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (difference, borrow) = P256.subtract(a, b)
        return borrow ? P256.add(difference, modulus).0 : difference
      }
      func mul(_ a: Limbs, _ b: Limbs) -> Limbs {
        var t = [UInt64](repeating: 0, count: 6)
        for i in 0..<4 {
          var carry: UInt64 = 0
          for j in 0..<4 { (t[j], carry) = P256.mac(t[j], a[j], b[i], carry) }
          let (top, overflow) = t[4].addingReportingOverflow(carry)
          t[4] = top
          t[5] = overflow ? 1 : 0
          let q = t[0] &* inverse
          (_, carry) = P256.mac(t[0], q, modulus[0], 0)
          for j in 1..<4 { (t[j - 1], carry) = P256.mac(t[j], q, modulus[j], carry) }
          let (next, overflow2) = t[4].addingReportingOverflow(carry)
          t[3] = next
          t[4] = t[5] + (overflow2 ? 1 : 0)
        }
        let result = Array(t[0..<4])
        let (reduced, borrow) = P256.subtract(result, modulus)
        return t[4] != 0 || !borrow ? reduced : result
      }
      func square(_ a: Limbs) -> Limbs { mul(a, a) }
      func enter(_ a: Limbs) -> Limbs { mul(a, rSquared) }
      func leave(_ a: Limbs) -> Limbs { mul(a, [1, 0, 0, 0]) }
      /// a^(m-2), the inverse for a prime modulus.
      func invert(_ a: Limbs) -> Limbs {
        let exponent = P256.subtract(modulus, [2, 0, 0, 0]).0
        var result = enter([1, 0, 0, 0])
        for bit in (0..<256).reversed() {
          result = square(result)
          if (exponent[bit / 64] >> UInt64(bit % 64)) & 1 == 1 { result = mul(result, a) }
        }
        return result
      }
    }

    static func mac(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ carry: UInt64) -> (UInt64, UInt64) {
      var (high, low) = b.multipliedFullWidth(by: c)
      var overflow: Bool
      (low, overflow) = low.addingReportingOverflow(a)
      if overflow { high &+= 1 }
      (low, overflow) = low.addingReportingOverflow(carry)
      if overflow { high &+= 1 }
      return (low, high)
    }
    static func add(_ a: Limbs, _ b: Limbs) -> (Limbs, Bool) {
      var out = Limbs(repeating: 0, count: 4)
      var carry = false
      for i in 0..<4 {
        let (s1, o1) = a[i].addingReportingOverflow(b[i])
        let (s2, o2) = s1.addingReportingOverflow(carry ? 1 : 0)
        out[i] = s2
        carry = o1 || o2
      }
      return (out, carry)
    }
    static func subtract(_ a: Limbs, _ b: Limbs) -> (Limbs, Bool) {
      var out = Limbs(repeating: 0, count: 4)
      var borrow = false
      for i in 0..<4 {
        let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
        let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
        out[i] = d2
        borrow = o1 || o2
      }
      return (out, borrow)
    }
    static func limbs(_ bytes: ArraySlice<UInt8>) -> Limbs {
      let b = Array(bytes)
      return (0..<4).map { limb in
        b[(24 - 8 * limb)..<(32 - 8 * limb)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      }
    }
    static func bytes(_ limbs: Limbs) -> [UInt8] {
      (0..<32).map { i in UInt8(truncatingIfNeeded: limbs[3 - i / 8] >> UInt64(56 - 8 * (i % 8))) }
    }
    static func less(_ a: Limbs, _ b: Limbs) -> Bool { subtract(a, b).1 }
    static func isZero(_ a: Limbs) -> Bool { a.allSatisfy { $0 == 0 } }

    static let p = Field([
      0xffff_ffff_ffff_ffff, 0x0000_0000_ffff_ffff, 0x0000_0000_0000_0000, 0xffff_ffff_0000_0001,
    ])
    static let order: Limbs = [
      0xf3b9_cac2_fc63_2551, 0xbce6_faad_a717_9e84, 0xffff_ffff_ffff_ffff, 0xffff_ffff_0000_0000,
    ]
    static let b: Limbs = [
      0x3bce_3c3e_27d2_604b, 0x651d_06b0_cc53_b0f6, 0xb3eb_bd55_7698_86bc, 0x5ac6_35d8_aa3a_93e7,
    ]
    static let gx: Limbs = [
      0xf4a1_3945_d898_c296, 0x7703_7d81_2deb_33a0, 0xf8bc_e6e5_63a4_40f2, 0x6b17_d1f2_e12c_4247,
    ]
    static let gy: Limbs = [
      0xcbb6_4068_37bf_51f5, 0x2bce_3357_6b31_5ece, 0x8ee7_eb4a_7c0f_9e16, 0x4fe3_42e2_fe1a_7f9b,
    ]

    /// Jacobian coordinates in Montgomery form; z == 0 is the point at infinity.
    struct Point {
      var x: Limbs
      var y: Limbs
      var z: Limbs
      static let infinity = Point(x: [0, 0, 0, 0], y: [0, 0, 0, 0], z: [0, 0, 0, 0])
      var isInfinity: Bool { P256.isZero(z) }
    }

    static var generator: Point { Point(x: p.enter(gx), y: p.enter(gy), z: p.enter([1, 0, 0, 0])) }

    /// A scalar in [1, n-1], or nil.
    static func scalar(_ bytes: [UInt8]) -> Limbs? {
      guard bytes.count == 32 else { return nil }
      let value = limbs(bytes[...])
      return !isZero(value) && less(value, order) ? value : nil
    }

    static func onCurve(_ x: Limbs, _ y: Limbs) -> Bool {
      guard less(x, p.modulus), less(y, p.modulus) else { return false }
      let mx = p.enter(x)
      let my = p.enter(y)
      let three = p.enter([3, 0, 0, 0])
      let right = p.add(p.sub(p.mul(p.square(mx), mx), p.mul(three, mx)), p.enter(b))
      return p.square(my) == right
    }

    /// An uncompressed SEC1 point (0x04 || X || Y) on the curve, or nil.
    static func decode(_ encoded: [UInt8]) -> Point? {
      guard encoded.count == 65, encoded[0] == 0x04 else { return nil }
      let x = limbs(encoded[1..<33])
      let y = limbs(encoded[33..<65])
      guard onCurve(x, y) else { return nil }
      return Point(x: p.enter(x), y: p.enter(y), z: p.enter([1, 0, 0, 0]))
    }

    static func affine(_ point: Point) -> (x: Limbs, y: Limbs)? {
      guard !point.isInfinity else { return nil }
      let zInverse = p.invert(point.z)
      let z2 = p.square(zInverse)
      return (p.leave(p.mul(point.x, z2)), p.leave(p.mul(point.y, p.mul(z2, zInverse))))
    }

    static func encode(_ point: Point) -> [UInt8] {
      guard let a = affine(point) else { return [] }
      return [0x04] + bytes(a.x) + bytes(a.y)
    }

    /// dbl-2001-b (a = -3).
    static func double(_ q: Point) -> Point {
      guard !q.isInfinity, !isZero(q.y) else { return .infinity }
      let delta = p.square(q.z)
      let gamma = p.square(q.y)
      let beta = p.mul(q.x, gamma)
      let t = p.mul(p.sub(q.x, delta), p.add(q.x, delta))
      let alpha = p.add(p.add(t, t), t)
      let beta4 = p.add(p.add(beta, beta), p.add(beta, beta))
      let x3 = p.sub(p.square(alpha), p.add(beta4, beta4))
      let z3 = p.sub(p.sub(p.square(p.add(q.y, q.z)), gamma), delta)
      let gamma2 = p.square(gamma)
      let gamma2x2 = p.add(gamma2, gamma2)
      let gamma2x4 = p.add(gamma2x2, gamma2x2)
      let gamma8 = p.add(gamma2x4, gamma2x4)
      let y3 = p.sub(p.mul(alpha, p.sub(beta4, x3)), gamma8)
      return Point(x: x3, y: y3, z: z3)
    }

    /// add-2007-bl, with the equal and opposite cases.
    static func add(_ a: Point, _ c: Point) -> Point {
      if a.isInfinity { return c }
      if c.isInfinity { return a }
      let z1z1 = p.square(a.z)
      let z2z2 = p.square(c.z)
      let u1 = p.mul(a.x, z2z2)
      let u2 = p.mul(c.x, z1z1)
      let s1 = p.mul(p.mul(a.y, c.z), z2z2)
      let s2 = p.mul(p.mul(c.y, a.z), z1z1)
      let h = p.sub(u2, u1)
      let rHalf = p.sub(s2, s1)
      if isZero(h) { return isZero(rHalf) ? double(a) : .infinity }
      let i = p.square(p.add(h, h))
      let j = p.mul(h, i)
      let r = p.add(rHalf, rHalf)
      let v = p.mul(u1, i)
      let x3 = p.sub(p.sub(p.square(r), j), p.add(v, v))
      let s1j = p.mul(s1, j)
      let y3 = p.sub(p.mul(r, p.sub(v, x3)), p.add(s1j, s1j))
      let z3 = p.mul(p.sub(p.sub(p.square(p.add(a.z, c.z)), z1z1), z2z2), h)
      return Point(x: x3, y: y3, z: z3)
    }

    static func multiply(_ point: Point, _ k: Limbs) -> Point {
      var result = Point.infinity
      for bit in (0..<256).reversed() {
        result = double(result)
        if (k[bit / 64] >> UInt64(bit % 64)) & 1 == 1 { result = add(result, point) }
      }
      return result
    }
  }
}
