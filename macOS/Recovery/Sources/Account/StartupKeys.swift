import CommonCrypto
import Foundation

/// Who holds the key that signs this Mac's Stage 2, chosen at setup. Stage 1
/// accepts a Stage 2 signed by any key in its key block.
public enum StartupKeyOwner: String, CaseIterable, Codable {
  /// Aurora signs the startup software it ships. The Mac holds no private key.
  case aurora
  /// Setup makes a key for this Mac and its owner signs updates with it.
  case owner
  /// Stage 1 accepts Aurora's keys and the owner's.
  case both

  public var title: String {
    switch self {
    case .aurora: return "Aurora-managed"
    case .owner: return "My own key"
    case .both: return "Both"
    }
  }
}

/// Aurora's Stage 2 signing keys, as raw 32-byte Ed25519 public keys.
public enum AuroraStage2Keys {
  /// `aurora-lab-20261111` (key id ac020765a9ed5164). This is the lab key
  /// that signs test builds; the release key replaces it once it exists.
  public static let lab20261111 = Data([
    0xdb, 0x81, 0xb5, 0x28, 0x32, 0x4a, 0xc8, 0x17, 0xe1, 0xc9, 0x1e, 0x62, 0x79, 0xe8, 0x3f, 0x5b,
    0xc0, 0x4d, 0xef, 0x2c, 0x51, 0xb8, 0xb5, 0x8d, 0x4e, 0xbc, 0x53, 0x21, 0x06, 0x7a, 0xe6, 0x2b,
  ])

  /// The keys an Aurora-managed Stage 1 accepts.
  public static let current = [lab20261111]
}

/// The keys one setup puts in Stage 1's key block. A set made at setup also
/// holds the owner key's seed for the startup partition; a set rebuilt from a
/// record holds only public keys.
public struct StartupKeys {
  /// Stage 1 refuses Stage 2 signatures below this security version.
  public static let minimumSecurityVersion: UInt32 = 1

  public let owner: StartupKeyOwner
  public let auroraKeys: [Data]
  public let ownerPublicKey: Data?
  /// The owner key's 32-byte RFC 8032 seed. It goes only to the startup
  /// partition, never to a log or record.
  let ownerSeed: Data?

  /// Makes a set for `owner`, with a new owner key unless Aurora alone
  /// signs. `seed` makes the owner key's 32-byte seed.
  public static func make(
    _ owner: StartupKeyOwner, aurora: [Data] = AuroraStage2Keys.current,
    seed: () throws -> Data = Ed25519.newSeed
  ) throws -> StartupKeys {
    guard owner != .aurora else {
      return StartupKeys(owner: owner, auroraKeys: aurora, ownerPublicKey: nil, ownerSeed: nil)
    }
    let made = try seed()
    return StartupKeys(
      owner: owner, auroraKeys: aurora, ownerPublicKey: Ed25519.publicKey(seed: made),
      ownerSeed: made)
  }

  /// Rebuilds a recorded set. Its owner key, if any, is public only.
  public static func recorded(
    _ owner: StartupKeyOwner, ownerPublicKey: Data?, aurora: [Data] = AuroraStage2Keys.current
  ) throws -> StartupKeys {
    guard (owner == .aurora) == (ownerPublicKey == nil),
      ownerPublicKey.map({ $0.count == Stage1KeyBlock.keyBytes }) ?? true
    else { throw Stage1KeyBlock.Invalid(reason: "the recorded owner key doesn't match its choice") }
    return StartupKeys(
      owner: owner, auroraKeys: aurora, ownerPublicKey: ownerPublicKey, ownerSeed: nil)
  }

  /// The set a setup receipt records, nil for a setup made before the choice existed.
  public static func recorded(receipt: [String: Any]) throws -> StartupKeys? {
    guard let value = receipt["startupKeys"] else { return nil }
    guard let name = value as? String, let owner = StartupKeyOwner(rawValue: name) else {
      throw Stage1KeyBlock.Invalid(reason: "the recorded key owner is unknown")
    }
    return try recorded(
      owner, ownerPublicKey: (receipt["ownerStage2PublicKey"] as? String).flatMap(bytes(hex:)))
  }

  /// What a setup receipt records so a later Stage 1 update fills the same
  /// keys: the choice and the owner's public key, never its seed.
  public var receiptFields: [String: String] {
    var fields = ["startupKeys": owner.rawValue]
    if let ownerPublicKey { fields["ownerStage2PublicKey"] = Self.hex(ownerPublicKey) }
    return fields
  }

  /// The keys in Stage 1's key block: Aurora's first, then the owner's.
  public var stage1Keys: [Data] {
    switch owner {
    case .aurora: return auroraKeys
    case .owner: return ownerPublicKey.map { [$0] } ?? []
    case .both: return auroraKeys + (ownerPublicKey.map { [$0] } ?? [])
    }
  }

  /// `stage1` with these keys filled in, at the minimum security version, checking without enforcing.
  public func filled(_ stage1: Data) throws -> Data {
    try Stage1KeyBlock.filled(
      stage1, keys: stage1Keys, minimumSecurityVersion: Self.minimumSecurityVersion)
  }

  /// One line for the installer log: the choice and key ids, never key bytes.
  public var summary: String {
    "Startup security keys: \(owner.title.lowercased()) (\(owner.rawValue)); Stage 1 key ids "
      + stage1Keys.map(Self.keyID).joined(separator: ", ")
      + "; minimum security version \(Self.minimumSecurityVersion); signatures checked, not enforced."
  }

  /// aura's key id: the first 8 bytes of the public key's SHA-256, in hex.
  public static func keyID(_ publicKey: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    Data(publicKey).withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(publicKey.count), &digest)
    }
    return hex(Data(digest.prefix(8)))
  }

  public static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func bytes(hex: String) -> Data? {
    guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
    var result = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }
}

/// The owner key hand-off on the startup partition. Linux's first boot moves
/// the key into its encrypted root and wipes these copies.
public enum StartupKeyFiles {
  /// The 32-byte owner key seed.
  public static let privateKey = "aurora/secboot/stage2.key"
  /// The owner key's 32-byte public key.
  public static let publicKey = "aurora/secboot/stage2.pub"
  /// `KEY_OWNER=aurora|owner|both`.
  public static let ownerRecord = "aurora/secboot/owner"

  public struct Changed: Error, LocalizedError {
    public var errorDescription: String? {
      "The startup partition's security key files changed; the setup record was kept."
    }
  }

  public static func ownerRecordBytes(_ owner: StartupKeyOwner) -> Data {
    Data("KEY_OWNER=\(owner.rawValue)\n".utf8)
  }

  /// The files a set leaves on the startup partition, relative to its root.
  /// An Aurora-managed set leaves only the owner record.
  public static func contents(_ keys: StartupKeys) throws -> [(path: String, bytes: Data)] {
    let record = (ownerRecord, ownerRecordBytes(keys.owner))
    guard keys.owner != .aurora else { return [record] }
    guard let seed = keys.ownerSeed, let pub = keys.ownerPublicKey,
      seed.count == Stage1KeyBlock.keyBytes, pub.count == Stage1KeyBlock.keyBytes
    else { throw Stage1KeyBlock.Invalid(reason: "the owner key is missing") }
    return [(publicKey, pub), (privateKey, seed), record]
  }

  /// Writes the set's files with `save` and removes an earlier owner key that
  /// an Aurora-managed set no longer uses.
  public static func write(
    _ keys: StartupKeys, esp: URL, save: (Data, URL) throws -> Void
  ) throws {
    let files = try contents(keys)
    if keys.owner == .aurora {
      for path in [privateKey, publicKey] {
        try removeIfPresent(esp.appendingPathComponent(path))
      }
    }
    for file in files { try save(file.bytes, esp.appendingPathComponent(file.path)) }
  }

  /// Removes every hand-off file, as when setup is rolled back.
  public static func remove(esp: URL) throws {
    for path in [privateKey, publicKey, ownerRecord] {
      try removeIfPresent(esp.appendingPathComponent(path))
    }
  }

  /// Checks the owner record and public key on the partition against `keys`.
  public static func verify(_ keys: StartupKeys, esp: URL) throws {
    let record = try? Data(contentsOf: esp.appendingPathComponent(ownerRecord))
    let pub = try? Data(contentsOf: esp.appendingPathComponent(publicKey))
    guard record == ownerRecordBytes(keys.owner),
      keys.owner == .aurora || (pub != nil && pub == keys.ownerPublicKey)
    else { throw Changed() }
  }

  private static func removeIfPresent(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    {}
  }
}
