import Foundation

@main struct RecoveryDigestCheck {
  static func main() {
    let vectors: [(Data, String)] = [
      (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
      (
        Data(repeating: 0x61, count: 1_000_000),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
      ),
    ]
    for (data, expected) in vectors {
      precondition(RecoveryDigest.sha256(data) == expected)
    }
    print("PASS Recovery SHA-256 known vectors")
  }
}
