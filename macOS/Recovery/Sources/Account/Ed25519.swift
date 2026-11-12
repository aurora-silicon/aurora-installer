import CommonCrypto
import Foundation
import Security

/// Ed25519 key generation (RFC 8032 section 5.1.5) for the Recovery app,
/// whose oldest Recovery OS has no CryptoKit. A key is its 32-byte seed; the
/// public key is the encoded point [s]B, where s is the clamped first half of
/// SHA-512(seed). Field elements are sixteen signed 16-bit limbs modulo
/// 2^255 - 19, and the scalar multiplication is a constant-time ladder.
public enum Ed25519 {
  public struct RandomFailure: Error, LocalizedError {
    public var errorDescription: String? { "This Mac couldn't make a random signing key." }
  }

  typealias Field = [Int64]

  /// A new random seed.
  public static func newSeed() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw RandomFailure()
    }
    return Data(bytes)
  }

  /// The 32-byte public key of a 32-byte seed.
  public static func publicKey(seed: Data) -> Data {
    precondition(seed.count == 32, "an Ed25519 seed is 32 bytes")
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    Data(seed).withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(seed.count), &digest) }
    var scalar = Array(digest.prefix(32))
    scalar[0] &= 248
    scalar[31] &= 127
    scalar[31] |= 64
    let base = [baseX, baseY, one, multiply(baseX, baseY)]
    return Data(encode(scalarMultiply(base, scalar)))
  }

  // Constants: 2d, where d = -121665/121666 is the curve constant, and the base point B.
  static let zero = Field(repeating: 0, count: 16)
  static let one = [1] + Field(repeating: 0, count: 15)
  static let twiceD: Field = [
    0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
    0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
  ]
  static let baseX: Field = [
    0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
    0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
  ]
  static let baseY: Field = [0x6658] + Field(repeating: 0x6666, count: 15)

  static func carry(_ o: inout Field) {
    for i in 0..<16 {
      o[i] += 1 << 16
      let c = o[i] >> 16
      if i < 15 { o[i + 1] += c - 1 } else { o[0] += 38 * (c - 1) }
      o[i] -= c << 16
    }
  }

  /// Swaps p and q when bit is 1, without a branch on it.
  static func select(_ p: inout Field, _ q: inout Field, _ bit: Int64) {
    let mask = ~(bit - 1)
    for i in 0..<16 {
      let t = mask & (p[i] ^ q[i])
      p[i] ^= t
      q[i] ^= t
    }
  }

  /// The canonical little-endian encoding.
  static func pack(_ n: Field) -> [UInt8] {
    var t = n
    carry(&t)
    carry(&t)
    carry(&t)
    var m = zero
    for _ in 0..<2 {
      m[0] = t[0] - 0xffed
      for i in 1..<15 {
        m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
        m[i - 1] &= 0xffff
      }
      m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
      let borrow = (m[15] >> 16) & 1
      m[14] &= 0xffff
      select(&t, &m, 1 - borrow)
    }
    var out = [UInt8](repeating: 0, count: 32)
    for i in 0..<16 {
      out[2 * i] = UInt8(t[i] & 0xff)
      out[2 * i + 1] = UInt8((t[i] >> 8) & 0xff)
    }
    return out
  }

  static func add(_ a: Field, _ b: Field) -> Field { (0..<16).map { a[$0] + b[$0] } }
  static func subtract(_ a: Field, _ b: Field) -> Field { (0..<16).map { a[$0] - b[$0] } }

  static func multiply(_ a: Field, _ b: Field) -> Field {
    var t = [Int64](repeating: 0, count: 31)
    for i in 0..<16 {
      for j in 0..<16 { t[i + j] += a[i] * b[j] }
    }
    for i in 0..<15 { t[i] += 38 * t[i + 16] }
    var o = Array(t.prefix(16))
    carry(&o)
    carry(&o)
    return o
  }

  /// a^(p-2), the inverse of a.
  static func invert(_ a: Field) -> Field {
    var c = a
    for bit in stride(from: 253, through: 0, by: -1) {
      c = multiply(c, c)
      if bit != 2 && bit != 4 { c = multiply(c, a) }
    }
    return c
  }

  /// Adds q to p in extended coordinates (X, Y, Z, T).
  static func addPoint(_ p: inout [Field], _ q: [Field]) {
    let a = multiply(subtract(p[1], p[0]), subtract(q[1], q[0]))
    let b = multiply(add(p[0], p[1]), add(q[0], q[1]))
    let c = multiply(multiply(p[3], q[3]), twiceD)
    var d = multiply(p[2], q[2])
    d = add(d, d)
    let e = subtract(b, a)
    let f = subtract(d, c)
    let g = add(d, c)
    let h = add(b, a)
    p = [multiply(e, f), multiply(h, g), multiply(g, f), multiply(e, h)]
  }

  static func scalarMultiply(_ point: [Field], _ scalar: [UInt8]) -> [Field] {
    var p = [zero, one, one, zero]
    var q = point
    for i in stride(from: 255, through: 0, by: -1) {
      let bit = Int64((scalar[i / 8] >> (i & 7)) & 1)
      for k in 0..<4 { select(&p[k], &q[k], bit) }
      addPoint(&q, p)
      addPoint(&p, p)
      for k in 0..<4 { select(&p[k], &q[k], bit) }
    }
    return p
  }

  /// y with the sign of x in the top bit.
  static func encode(_ p: [Field]) -> [UInt8] {
    let zInverse = invert(p[2])
    var out = pack(multiply(p[1], zInverse))
    out[31] ^= (pack(multiply(p[0], zInverse))[0] & 1) << 7
    return out
  }
}
