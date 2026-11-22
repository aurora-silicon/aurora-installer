import Foundation
import Security

extension RestoreImageKey {
  /// P-256 ECDH from Security.framework (`SecKeyCopyKeyExchangeResult`,
  /// public since macOS 10.12): the x-coordinate of scalar * peer (SEC 1
  /// 3.3.1), which DHKEM(P-256) takes as its DH output. Security refuses a
  /// peer that isn't a point on the curve.
  static func agree(_ key: PrivateKey, peer: [UInt8]) throws -> [UInt8] {
    func create(_ bytes: [UInt8], _ keyClass: CFString) -> SecKey? {
      let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: keyClass,
        kSecAttrKeySizeInBits: 256,
      ]
      return SecKeyCreateWithData(Data(bytes) as CFData, attributes as CFDictionary, nil)
    }
    guard let privateKey = create(key.x963, kSecAttrKeyClassPrivate) else {
      throw Failure.invalidPrivateKey
    }
    guard let publicKey = create(peer, kSecAttrKeyClassPublic) else { throw Failure.invalidPoint }
    var error: Unmanaged<CFError>?
    let shared = SecKeyCopyKeyExchangeResult(
      privateKey, .ecdhKeyExchangeStandard, publicKey, [:] as CFDictionary, &error)
    _ = error?.takeRetainedValue()
    guard let shared = shared as Data?, shared.count == 32 else { throw Failure.invalidPoint }
    return [UInt8](shared)
  }
}
