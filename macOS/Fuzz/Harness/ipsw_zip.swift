// SPDX-License-Identifier: MIT
// IPSW (ZIP/ZIP64) directory admission and member reads from an untrusted archive.
import Foundation

@testable import AuroraFirmware

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzIPSWZip(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  let source = FuzzMemorySource(bytes: fuzzData(bytes, count))
  _ = fuzzBlocking {
    let archive = try await IPSWArchive.open(source)
    try? await archive.validateEntries()
    for member in archive.members {
      _ = try? await archive.dataOffset(for: member)
      _ = try? await archive.readPrefix(member, maximumBytes: 4096)
      _ = try? await archive.readPrefix(
        member, maximumBytes: 1 << 20, maximumCompressedBytes: 1 << 20)
      _ = try? await archive.read(member, maximumBytes: 1 << 20)
      if member.isSymbolicLink { _ = try? await archive.symbolicLinkTarget(member) }
      _ = try? await archive.streamPipelined(
        member, maximumBytes: 1 << 20, maximumCompressedBytes: 1 << 20, consume: { _ in })
    }
    return true
  }
  return 0
}
