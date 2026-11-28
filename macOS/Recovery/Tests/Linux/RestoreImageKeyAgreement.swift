import CommonCrypto
import Foundation

// Linux stand-in for Sources/RestoreImageKeyAgreement.swift (Security.framework
// doesn't exist there): the same ECDH on libcrypto through Tests/Linux/shim.c.
// Only Tests/Linux/run.sh compiles it; the app and macOS checks use the real one.
extension RestoreImageKey {
  static func agree(_ key: PrivateKey, peer: [UInt8]) throws -> [UInt8] {
    guard peer.count == 65 else { throw Failure.invalidPoint }
    var out = [UInt8](repeating: 0, count: 32)
    let status = aurora_test_ecdh(key.scalar, peer, &out)
    guard status == 0 else {
      throw status == 1
        ? Failure.invalidPrivateKey : status == 2 ? Failure.invalidPoint : Failure.cryptor
    }
    return out
  }
}
