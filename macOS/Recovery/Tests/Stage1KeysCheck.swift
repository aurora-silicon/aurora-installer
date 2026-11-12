import CryptoKit
import Foundation

/// Stage 1 key block and owner key hand-off. The fixtures were written by aura's
/// `tools/secboot_sign.py` (see Fixtures/Stage1Keys/README.md); the Swift fill
/// must match them byte for byte.
@main struct Stage1KeysCheck {
  static let fixtures = URL(fileURLWithPath: "Tests/Fixtures/Stage1Keys")

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
  }

  static func fails(_ what: String, _ body: () throws -> Void) {
    do {
      try body()
      preconditionFailure("accepted " + what)
    } catch {}
  }

  static func main() throws {
    let unfilled = try fixture("stage1-unfilled.bin")
    let auroraFilled = try fixture("stage1-aurora.bin")
    let lab = try fixture("aurora-lab-20261111.pub")
    let seed = try fixture("owner-test.key")
    let ownerPub = try fixture("owner-test.pub")
    let ownerKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

    // CryptoKit's raw representation is the RFC 8032 seed: it derives the same
    // public key as aura's tool, and RFC 8032 test 1's.
    precondition(ownerKey.rawRepresentation == seed)
    precondition(ownerKey.publicKey.rawRepresentation == ownerPub, "CryptoKit and aura disagree")
    let rfc = try Curve25519.Signing.PrivateKey(
      rawRepresentation: StartupKeys.bytes(
        hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!)
    precondition(
      StartupKeys.hex(rfc.publicKey.rawRepresentation)
        == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")

    // Recovery derives public keys without CryptoKit; it must agree with
    // CryptoKit and aura on the fixture seed, RFC 8032's vectors and random seeds.
    precondition(Ed25519.publicKey(seed: seed) == ownerPub, "Recovery and aura disagree")
    for (secret, expected) in [
      (
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
      ),
      (
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
      ),
      (
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"
      ),
    ] {
      precondition(
        StartupKeys.hex(Ed25519.publicKey(seed: StartupKeys.bytes(hex: secret)!)) == expected)
    }
    for _ in 0..<16 {
      let random = try Ed25519.newSeed()
      let reference = try Curve25519.Signing.PrivateKey(rawRepresentation: random)
      precondition(
        Ed25519.publicKey(seed: random) == reference.publicKey.rawRepresentation,
        "Recovery and CryptoKit disagree")
    }

    // The shipped Aurora key is the lab key, with aura's key id.
    precondition(AuroraStage2Keys.lab20261111 == lab)
    precondition(AuroraStage2Keys.current == [lab])
    precondition(StartupKeys.keyID(lab) == "ac020765a9ed5164")
    precondition(StartupKeys.keyID(ownerPub) == "8f73cefd62612f1f")

    // The block matches `fill-keys` for every field.
    for (keys, floor, enforce, name) in [
      ([lab], UInt32(1), false, "stage1-aurora.bin"),
      ([ownerPub], 1, false, "stage1-owner.bin"),
      ([lab, ownerPub], 1, false, "stage1-both.bin"),
      ([ownerPub, lab, ownerPub, lab], 7, true, "stage1-four-enforce.bin"),
    ] {
      let expected = try fixture(name)
      let filled = try Stage1KeyBlock.filled(
        unfilled, keys: keys, minimumSecurityVersion: floor, enforce: enforce)
      precondition(filled == expected, "\(name) differs from aura's fill-keys")
      precondition(filled.count == unfilled.count && filled.suffix(8) == Data("STACKBOT".utf8))
      let read = try Stage1KeyBlock.read(expected)
      precondition(
        read == Stage1KeyBlock.Contents(keys: keys, minimumSecurityVersion: floor, enforce: enforce)
      )
      // Filling again replaces the keys; nothing else moves.
      let refilled = try Stage1KeyBlock.filled(expected, keys: [lab], minimumSecurityVersion: 1)
      precondition(refilled == auroraFilled)
    }
    let empty = try Stage1KeyBlock.read(unfilled)
    precondition(empty == nil, "an unfilled block holds no keys")
    precondition(Stage1KeyBlock.isPresent(in: unfilled))
    // The block is found wherever it sits, also in a slice of a larger buffer.
    let wrapped = Data([0x55] + unfilled + [0x66]).dropFirst()
    precondition(Stage1KeyBlock.isPresent(in: wrapped))

    // Each choice fills the keys the contract names, at floor 1 without enforcing.
    let generate = { seed }
    for (owner, name) in [
      (StartupKeyOwner.aurora, "stage1-aurora.bin"), (.owner, "stage1-owner.bin"),
      (.both, "stage1-both.bin"),
    ] {
      let keys = try StartupKeys.make(owner, seed: generate)
      let filled = try keys.filled(unfilled)
      let expected = try fixture(name)
      precondition(filled == expected, "\(owner) fill")
      precondition((keys.ownerSeed != nil) == (owner != .aurora))
      let summary = keys.summary
      for secret in [seed, ownerPub] {
        precondition(!summary.contains(StartupKeys.hex(secret)), "the log line carries key bytes")
      }
      precondition(summary.contains(owner == .owner ? "8f73cefd62612f1f" : "ac020765a9ed5164"))
      // A record rebuilds the same block without the seed.
      let recorded = try StartupKeys.recorded(owner, ownerPublicKey: keys.ownerPublicKey)
      precondition(recorded.ownerSeed == nil && recorded.stage1Keys == keys.stage1Keys)
    }
    // A receipt keeps the choice and public key, and a Stage 1 update rebuilds the set from it.
    for owner in StartupKeyOwner.allCases {
      let keys = try StartupKeys.make(owner, seed: generate)
      let fields = keys.receiptFields
      precondition(!fields.values.contains(StartupKeys.hex(seed)), "a receipt carries the seed")
      precondition(fields["startupKeys"] == owner.rawValue)
      let receipt: [String: Any] = fields.merging(["status": "installed"]) { a, _ in a }
      let rebuilt = try StartupKeys.recorded(receipt: receipt)
      precondition(rebuilt?.stage1Keys == keys.stage1Keys && rebuilt?.owner == owner)
    }
    let older = try StartupKeys.recorded(receipt: ["status": "installed"])
    precondition(older == nil, "a setup made before the choice has no recorded keys")
    for bad in [
      ["startupKeys": "mine"], ["startupKeys": 1], ["startupKeys": "owner"],
      ["startupKeys": "both", "ownerStage2PublicKey": "zz"],
      ["startupKeys": "aurora", "ownerStage2PublicKey": StartupKeys.hex(ownerPub)],
    ] as [[String: Any]] {
      fails("receipt \(bad)") { _ = try StartupKeys.recorded(receipt: bad) }
    }
    let fresh = try StartupKeys.make(.owner)
    precondition(fresh.ownerSeed?.count == 32 && fresh.ownerPublicKey?.count == 32)
    let another = try StartupKeys.make(.owner)
    precondition(fresh.ownerSeed != another.ownerSeed, "each setup makes a new key")
    fails("an Aurora record with an owner key") {
      _ = try StartupKeys.recorded(.aurora, ownerPublicKey: ownerPub)
    }
    fails("an owner record without its key") {
      _ = try StartupKeys.recorded(.both, ownerPublicKey: nil)
    }
    fails("a short owner key") {
      _ = try StartupKeys.recorded(.owner, ownerPublicKey: ownerPub.prefix(31))
    }

    // fill-keys' limits.
    fails("no keys") {
      _ = try Stage1KeyBlock.filled(unfilled, keys: [], minimumSecurityVersion: 1)
    }
    fails("five keys") {
      _ = try Stage1KeyBlock.filled(
        unfilled, keys: Array(repeating: lab, count: 5), minimumSecurityVersion: 1)
    }
    fails("a 31-byte key") {
      _ = try Stage1KeyBlock.filled(unfilled, keys: [lab.prefix(31)], minimumSecurityVersion: 1)
    }
    fails("an image without a block") {
      _ = try Stage1KeyBlock.filled(
        Data("no block here".utf8), keys: [lab], minimumSecurityVersion: 1)
    }
    precondition(!Stage1KeyBlock.isPresent(in: Data("no block here".utf8)))
    fails("two blocks") {
      _ = try Stage1KeyBlock.filled(unfilled + unfilled, keys: [lab], minimumSecurityVersion: 1)
    }
    fails("a truncated block") {
      _ = try Stage1KeyBlock.filled(
        unfilled.prefix(4 + 16 + 147), keys: [lab], minimumSecurityVersion: 1)
    }
    var version2 = unfilled
    version2[4 + 16] = 2
    fails("block version 2") {
      _ = try Stage1KeyBlock.filled(version2, keys: [lab], minimumSecurityVersion: 1)
    }
    // A damaged block reads as an error, as aura reports it.
    let both = try fixture("stage1-both.bin")
    for (offset, value) in [
      (4 + 16 + 4, UInt8(5)), (4 + 16 + 12, 2), (4 + 16 + 40, 0xFF), (4 + 16 + 144, 0),
    ] {
      var damaged = both
      damaged[offset] ^= value == 0 ? 0xFF : value
      fails("a damaged block at \(offset)") { _ = try Stage1KeyBlock.read(damaged) }
    }

    // The startup partition hand-off.
    let esp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stage1-keys-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: esp) }
    func save(_ bytes: Data, _ url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url, options: .atomic)
    }
    func file(_ path: String) -> Data? { try? Data(contentsOf: esp.appendingPathComponent(path)) }
    let owned = try StartupKeys.make(.both, seed: generate)
    try StartupKeyFiles.write(owned, esp: esp, save: save)
    precondition(file("aurora/secboot/stage2.key") == seed)
    precondition(file("aurora/secboot/stage2.pub") == ownerPub)
    precondition(file("aurora/secboot/owner") == Data("KEY_OWNER=both\n".utf8))
    try StartupKeyFiles.verify(owned, esp: esp)
    try StartupKeyFiles.verify(try StartupKeys.recorded(.both, ownerPublicKey: ownerPub), esp: esp)
    fails("a hand-off for another choice") {
      try StartupKeyFiles.verify(try StartupKeys.make(.owner, seed: generate), esp: esp)
    }
    fails("a hand-off with another key") {
      try StartupKeyFiles.verify(try StartupKeys.make(.both), esp: esp)
    }
    fails("a recorded owner set without its seed") {
      try StartupKeyFiles.write(
        try StartupKeys.recorded(.owner, ownerPublicKey: ownerPub), esp: esp, save: save)
    }
    // Aurora-managed leaves no owner key behind.
    let managed = try StartupKeys.make(.aurora)
    try StartupKeyFiles.write(managed, esp: esp, save: save)
    precondition(
      file("aurora/secboot/stage2.key") == nil && file("aurora/secboot/stage2.pub") == nil)
    precondition(file("aurora/secboot/owner") == Data("KEY_OWNER=aurora\n".utf8))
    try StartupKeyFiles.verify(managed, esp: esp)
    try StartupKeyFiles.write(try StartupKeys.make(.owner, seed: generate), esp: esp, save: save)
    precondition(file("aurora/secboot/owner") == Data("KEY_OWNER=owner\n".utf8))
    try StartupKeyFiles.remove(esp: esp)
    try StartupKeyFiles.remove(esp: esp)
    for path in [
      StartupKeyFiles.privateKey, StartupKeyFiles.publicKey, StartupKeyFiles.ownerRecord,
    ] {
      precondition(file(path) == nil)
    }
    print(
      "PASS Stage 1 key block: byte-identical to aura fill-keys for 1, 2 and 4 keys, floor and enforce; Recovery's Ed25519 matches CryptoKit, aura and RFC 8032; refill, limits and damaged blocks; choice to keys; startup partition hand-off"
    )
  }
}
