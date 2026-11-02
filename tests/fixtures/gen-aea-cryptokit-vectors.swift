// SPDX-License-Identifier: MIT
// Regenerates aea-cryptokit-vectors.json: swiftc -O -o gen gen-aea-cryptokit-vectors.swift && ./gen > aea-cryptokit-vectors.json
import CryptoKit
import Foundation
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data { var d = Data(); var i = s.startIndex
  while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }
var out: [[String: String]] = []
do {
// HPKE base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, empty info/aad.
for seed in ["01", "a5", "3c"] {
  let skBytes = Data(SHA256.hash(data: unhex(seed)))
  let sk = try P256.KeyAgreement.PrivateKey(rawRepresentation: skBytes)
  let pt = Data(SHA256.hash(data: unhex(seed + "ff")))   // a 32-byte "archive key"
  var sender = try HPKE.Sender(recipientKey: sk.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data())
  let ct = try sender.seal(pt)
  out.append(["kind": "hpke", "sk": hex(skBytes), "pk": hex(sk.publicKey.x963Representation),
              "enc": hex(sender.encapsulatedKey), "ct": hex(ct), "pt": hex(pt)])
}
// AES-256-GCM with AAD and a non-block-multiple length.
let key = SymmetricKey(data: Data(SHA256.hash(data: unhex("42"))))
let nonce = try AES.GCM.Nonce(data: unhex("cafebabefacedbaddecaf888"))
let pt = Data((0..<61).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
let aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
let box = try AES.GCM.seal(pt, using: key, nonce: nonce, authenticating: aad)
out.append(["kind": "gcm", "key": hex(key.withUnsafeBytes { Data($0) }), "nonce": "cafebabefacedbaddecaf888",
            "pt": hex(pt), "aad": hex(aad), "ct": hex(box.ciphertext), "tag": hex(box.tag)])
let json = try JSONSerialization.data(withJSONObject: ["generator": "CryptoKit (macOS)", "vectors": out], options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
} catch { FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!); exit(1) }
