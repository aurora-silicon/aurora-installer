import Foundation
import Security

extension RestoreImageKey {
  /// P-256 ECDH from Security.framework (`SecKeyCopyKeyExchangeResult`,
  /// public since macOS 10.12): the x-coordinate of scalar * peer (SEC 1
  /// 3.3.1), which DHKEM(P-256) takes as its DH output. Security refuses a
  /// peer that isn't a point on the curve.
  ///
  /// Only toll-free casts to and from CF types here: a CF type used as a
  /// Swift dictionary key or bridged to a Swift value pulls in the Swift
  /// CoreFoundation library, which an older recoveryOS lacks (build-app.sh).
  static func agree(_ key: PrivateKey, peer: [UInt8]) throws -> [UInt8] {
    func create(_ bytes: [UInt8], _ keyClass: CFString) -> SecKey? {
      let attributes = NSDictionary(
        objects: [kSecAttrKeyTypeECSECPrimeRandom, keyClass, NSNumber(value: 256)],
        forKeys: [
          kSecAttrKeyType as NSString, kSecAttrKeyClass as NSString,
          kSecAttrKeySizeInBits as NSString,
        ])
      return SecKeyCreateWithData(
        NSData(bytes: bytes, length: bytes.count) as CFData, attributes as CFDictionary, nil)
    }
    guard let privateKey = create(key.x963, kSecAttrKeyClassPrivate) else {
      throw Failure.invalidPrivateKey
    }
    guard let publicKey = create(peer, kSecAttrKeyClassPublic) else { throw Failure.invalidPoint }
    var error: Unmanaged<CFError>?
    let shared = SecKeyCopyKeyExchangeResult(
      privateKey, .ecdhKeyExchangeStandard, publicKey, NSDictionary() as CFDictionary, &error)
    error?.release()
    guard let shared = shared as NSData?, shared.length == 32 else { throw Failure.invalidPoint }
    return [UInt8](shared as Data)
  }
}
