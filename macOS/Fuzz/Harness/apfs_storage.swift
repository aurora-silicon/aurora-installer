// SPDX-License-Identifier: MIT
// APFS transparent-compression storage (decmpfs attribute and resource fork)
// and the LZFSE/LZVN block walkers. The fuzz build's Compression shim stands
// in for Apple's LZFSE decoder; zlib is real.
//
// Input: a selector byte, then for storage: attribute size (2), attribute, fork.
import Foundation

@testable import AuroraFirmware

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzAPFSStorage(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  var fields = FuzzFields(fuzzData(bytes, count))
  let selector = fields.int(1)
  switch selector % 3 {
  case 0:
    let attribute = fields.bytes(fields.int(2))
    let fork = fields.rest()
    _ = try? decompressStorage(selector & 4 == 0 ? [attribute] : [attribute, fork])
  case 1:
    let maximum = fields.int(3)
    _ = try? boundedLZFSE(fields.rest(), maximum: maximum)
  default:
    let expected = fields.int(3)
    _ = try? lzvnPayload(fields.rest(), expected: expected)
  }
  return 0
}
