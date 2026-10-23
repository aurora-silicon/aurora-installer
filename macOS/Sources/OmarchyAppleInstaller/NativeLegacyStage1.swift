#if os(macOS)
  import Foundation

  enum NativeLegacyStage1 {
    struct Receipt: Codable, Equatable, Sendable {
      let configuration: String
      let base: NativeStubFileIdentity
    }

    static func validate(_ base: Data) throws {
      guard base.startIndex == 0, base.count >= 8, base.count <= (4 << 20) - 1024,
        base.suffix(8) == Data("STACKBOT".utf8),
        base.range(of: Data("AURORA-S1-CFG01\0".utf8)) == nil
      else { throw NativeBootChainError.invalidStage1 }
    }

    static func fill(_ base: Data, uuid: String, path: String) throws -> Data {
      try validate(base)
      guard
        uuid.range(
          of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#,
          options: .regularExpression) != nil,
        uuid != "00000000-0000-0000-0000-000000000000",
        NativeHandoffEvidence.safeRelative(path), path.utf8.count < 192,
        path.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f && $0 != 0x3b })
      else { throw NativeBootChainError.invalidStage1 }
      return base
        + Data("chosen.asahi,efi-system-partition=\(uuid)\nchainload=\(uuid);\(path)\n".utf8)
        + Data(repeating: 0, count: 4)
    }

    static func verify(_ configured: Data, receipt: Receipt, uuid: String, path: String) throws {
      guard receipt.configuration == "legacy-text-v1", receipt.base.bytes > 0,
        receipt.base.bytes < configured.count, receipt.base.bytes <= (4 << 20) - 1024
      else { throw NativeBootChainError.invalidStage1 }
      let base = Data(configured.prefix(receipt.base.bytes))
      guard NativeStubFileStore.hash(base) == receipt.base.sha256,
        try fill(base, uuid: uuid, path: path) == configured
      else { throw NativeBootChainError.invalidStage1 }
    }
  }
#endif
