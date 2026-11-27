import CryptoKit
import Foundation

// RestoreImageKey against CryptoKit, the restore image helper's own crypto,
// on fresh random keys: what CryptoKit's HPKE seals, RestoreImageKey opens;
// public keys, AES-256-GCM and HKDF-SHA256 agree. Only this check links
// CryptoKit; the Recovery app never does.
@main struct Check {
  static func main() throws {
    guard #available(macOS 14, *) else {
      print("restore-image-key-cryptokit: skipped (HPKE needs macOS 14)")
      return
    }
    for round in 0..<64 {
      let recipient = P256.KeyAgreement.PrivateKey()
      let key = try RestoreImageKey.PrivateKey(pem: Data(recipient.pemRepresentation.utf8))
      precondition(
        key.publicKeyRepresentation == recipient.publicKey.x963Representation, "\(round)")
      let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      var sender = try HPKE.Sender(
        recipientKey: recipient.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data())
      let wrapped = try sender.seal(secret)
      let response = try JSONSerialization.data(withJSONObject: [
        "enc-request": sender.encapsulatedKey.base64EncodedString(),
        "wrapped-key": wrapped.base64EncodedString(),
      ])
      let unwrapped = try RestoreImageKey.unwrap(
        fcsResponse: response, releaseKey: Data(recipient.pemRepresentation.utf8))
      precondition(unwrapped == secret, "unwrap \(round)")

      let aes = SymmetricKey(size: .bits256)
      let plain = Data((0..<(round * 7 % 97)).map { _ in UInt8.random(in: 0...255) })
      let box = try AES.GCM.seal(plain, using: aes)
      let opened = try RestoreImageKey.GCM.open(
        key: aes.withUnsafeBytes { [UInt8]($0) }, nonce: box.nonce.withUnsafeBytes { [UInt8]($0) },
        sealed: [UInt8](box.ciphertext + box.tag))
      precondition(Data(opened) == plain, "gcm \(round)")

      let salt = Data((0..<(round % 40)).map { _ in UInt8.random(in: 0...255) })
      let info = Data("AEA_AMK".utf8) + Data([UInt8(round)])
      let size = 1 + round * 5
      let expected = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info, outputByteCount: size
      ).withUnsafeBytes { Data($0) }
      let derived = try RestoreImageKey.derive(secret, salt: salt, info: info, size: size)
      precondition(derived == expected, "hkdf \(round)")
    }
    print("restore-image-key-cryptokit: all checks passed (64 rounds)")
  }
}
