import CommonCrypto
import Foundation

enum RecoveryDigest {
  static func sha256(_ data: Data) -> String {
    var context = CC_SHA256_CTX()
    precondition(CC_SHA256_Init(&context) == 1)
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = min(bytes.count - offset, Int(CC_LONG.max))
        precondition(
          CC_SHA256_Update(&context, bytes.baseAddress!.advanced(by: offset), CC_LONG(count)) == 1)
        offset += count
      }
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    precondition(CC_SHA256_Final(&digest, &context) == 1)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
