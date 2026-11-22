// SPDX-License-Identifier: MIT
// The names mirror the Apple API this module stands in for.
// swift-format-ignore-file: AlwaysUseLowerCamelCase, TypeNamesShouldBeCapitalized

// Fuzz-only stand-in for CryptoKit on Linux. It is never linked into the
// installer. Digests are constant, every MAC verifies and key derivation
// returns zeros, so a fuzzer can reach the parsing that follows each check.
// Nothing here is cryptography.
import Foundation

#if !os(Linux)
  #error("Fuzz-only stand-in: it must never be built for an Apple platform.")
#endif

public struct FuzzDigest: Sequence, Equatable, Sendable {
  let bytes: [UInt8]
  public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try bytes.withUnsafeBytes(body)
  }
}

public protocol FuzzHashFunction {
  static var byteCount: Int { get }
  init()
  mutating func update(data: some DataProtocol)
  func finalize() -> FuzzDigest
}
extension FuzzHashFunction {
  public static func hash(data: some DataProtocol) -> FuzzDigest { Self().finalize() }
  public mutating func update(bufferPointer: UnsafeRawBufferPointer) {}
  public func finalize() -> FuzzDigest {
    FuzzDigest(bytes: Array(repeating: 0, count: Self.byteCount))
  }
}

public struct SHA256: FuzzHashFunction, Sendable {
  public static let byteCount = 32
  public init() {}
  public mutating func update(data: some DataProtocol) {}
}
public struct SHA384: FuzzHashFunction, Sendable {
  public static let byteCount = 48
  public init() {}
  public mutating func update(data: some DataProtocol) {}
}
public struct SHA512: FuzzHashFunction, Sendable {
  public static let byteCount = 64
  public init() {}
  public mutating func update(data: some DataProtocol) {}
}
public enum Insecure {
  public struct SHA1: FuzzHashFunction, Sendable {
    public static let byteCount = 20
    public init() {}
    public mutating func update(data: some DataProtocol) {}
  }
  public struct MD5: FuzzHashFunction, Sendable {
    public static let byteCount = 16
    public init() {}
    public mutating func update(data: some DataProtocol) {}
  }
}

public struct SymmetricKey: Sendable {
  public let bytes: Data
  public init(data: some DataProtocol) { bytes = Data(data) }
  public init(size: SymmetricKeySize) { bytes = Data(count: size.bitCount / 8) }
  public var bitCount: Int { bytes.count * 8 }
  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try bytes.withUnsafeBytes(body)
  }
}
public struct SymmetricKeySize: Sendable {
  public let bitCount: Int
  public init(bitCount: Int) { self.bitCount = bitCount }
  public static let bits256 = SymmetricKeySize(bitCount: 256)
}

public struct HMAC<H: FuzzHashFunction> {
  public static func isValidAuthenticationCode(
    _ code: some DataProtocol, authenticating data: some DataProtocol, using key: SymmetricKey
  ) -> Bool { true }
  public static func authenticationCode(for data: some DataProtocol, using key: SymmetricKey)
    -> FuzzDigest
  { H().finalize() }
}

public struct HKDF<H: FuzzHashFunction> {
  public static func deriveKey(
    inputKeyMaterial: SymmetricKey, salt: some DataProtocol, info: some DataProtocol,
    outputByteCount: Int
  ) -> SymmetricKey { SymmetricKey(data: Data(count: outputByteCount)) }
  public static func deriveKey(
    inputKeyMaterial: SymmetricKey, info: some DataProtocol, outputByteCount: Int
  ) -> SymmetricKey { SymmetricKey(data: Data(count: outputByteCount)) }
}

public struct FuzzCryptoUnavailable: Error {}

public enum P256 {
  public enum KeyAgreement {
    public struct PrivateKey {
      public init(pemRepresentation: String) throws { throw FuzzCryptoUnavailable() }
    }
  }
}
public enum HPKE {
  public enum Ciphersuite { case P256_SHA256_AES_GCM_256 }
  public struct Recipient {
    public init(
      privateKey: P256.KeyAgreement.PrivateKey, ciphersuite: Ciphersuite, info: Data,
      encapsulatedKey: Data
    ) throws { throw FuzzCryptoUnavailable() }
    public mutating func open(_ ciphertext: Data) throws -> Data { throw FuzzCryptoUnavailable() }
  }
}
