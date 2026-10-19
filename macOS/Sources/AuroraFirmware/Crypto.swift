// SPDX-License-Identifier: MIT
import CommonCrypto
import CryptoKit
import Darwin
import Foundation

func metadata(_ data: Data) throws -> [String: Data] {
  try require(
    try data.part(0, 4) == Data("AEA1".utf8) && data.little(4, 4) == 1,
    "Unsupported AEA header/profile.")
  let length = try data.little(8, 4)
  try require(length > 0 && length <= 1024 * 1024, "Invalid AEA metadata length.")
  let body = try data.part(12, length)
  var offset = 0
  var result: [String: Data] = [:]
  while offset < body.count {
    let size = try body.little(offset, 4)
    try require(size >= 6 && size <= body.count - offset, "Invalid AEA metadata entry.")
    let entry = try body.part(offset + 4, size - 4)
    guard let zero = entry.firstIndex(of: 0), zero > entry.startIndex,
      let key = String(data: entry.prefix(upTo: zero), encoding: .utf8), result[key] == nil
    else { throw RestoreFailure("Missing or duplicate AEA metadata key.") }
    result[key] = Data(entry.suffix(from: entry.index(after: zero)))
    offset += size
  }
  return result
}

func unwrap(_ md: [String: Data], releaseKey: Data) throws -> Data {
  guard let pem = String(data: releaseKey, encoding: .utf8),
    pem.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----BEGIN PRIVATE KEY-----"),
    pem.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-----END PRIVATE KEY-----")
  else { throw RestoreFailure("Invalid FCS PKCS#8 release key.") }
  let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: pem)
  guard let response = md["com.apple.wkms.fcs-response"],
    let object = try JSONSerialization.jsonObject(with: response) as? [String: String],
    let encoded = object["enc-request"], let sealed = object["wrapped-key"],
    let enc = Data(base64Encoded: encoded), enc.count == 65, enc.base64EncodedString() == encoded,
    let wrapped = Data(base64Encoded: sealed), wrapped.count == 48,
    wrapped.base64EncodedString() == sealed
  else { throw RestoreFailure("Invalid FCS encapsulation or wrapped key.") }
  var recipient = try HPKE.Recipient(
    privateKey: privateKey, ciphersuite: .P256_SHA256_AES_GCM_256,
    info: Data(), encapsulatedKey: enc)
  let key = try recipient.open(wrapped)
  try require(key.count == 32, "FCS key authentication failed.")
  return key
}

func derive(_ key: Data, salt: Data = Data(), info: Data, size: Int) -> Data {
  let derived = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: info, outputByteCount: size)
  return derived.withUnsafeBytes { Data($0) }
}
func indexedInfo(_ name: String, _ index: Int) -> Data {
  Data(name.utf8) + littleBytes(index, count: 4)
}
func authenticate(_ material: Data, data: Data, salt: Data = Data(), expected: Data) throws {
  let message = salt + data + littleBytes(salt.count, count: 8)
  try require(
    HMAC<SHA256>.isValidAuthenticationCode(
      expected, authenticating: message, using: SymmetricKey(data: material.prefix(32))),
    "AEA range authentication failed.")
}
func ctr(_ material: Data, data: Data) throws -> Data {
  try require(material.count == 80, "Invalid AEA key material.")
  let key = try material.part(32, 32)
  let iv = try material.part(64, 16)
  var cryptor: CCCryptorRef?
  let status = key.withUnsafeBytes { keyBytes in
    iv.withUnsafeBytes { ivBytes in
      CCCryptorCreateWithMode(
        CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
        CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
    }
  }
  try require(status == kCCSuccess && cryptor != nil, "Cannot initialize AEA cipher.")
  defer { CCCryptorRelease(cryptor) }
  var output = Data(count: data.count + 16)
  var used = 0
  let capacity = output.count
  let update = output.withUnsafeMutableBytes { out in
    data.withUnsafeBytes { bytes in
      CCCryptorUpdate(cryptor, bytes.baseAddress, data.count, out.baseAddress, capacity, &used)
    }
  }
  try require(update == kCCSuccess && used == data.count, "Cannot decode AEA ciphertext.")
  return Data(output.prefix(used))
}

