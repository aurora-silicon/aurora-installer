// SPDX-License-Identifier: MIT
// An OTA update archive's BXDIFF50/PBZX whole image, decoded as its bytes
// arrive. The first input byte picks how the member is split into reads.
import Foundation

@testable import AuroraFirmware

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzUpdateImage(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  guard count > 1 else { return 0 }
  let split = Int(bytes[0]) + 1
  let member = fuzzData(bytes + 1, count - 1)
  do {
    let header = try UpdateArchiveFullImage.Header(
      member.prefix(UpdateArchiveFullImage.headerBytes), memberBytes: member.count)
    let decoder = UpdateArchiveFullImage.Decoder(header: header)
    var offset = 0
    while offset < member.count {
      let end = min(member.count, offset + split)
      try decoder.consume(member.subdata(in: offset..<end)) { _ in }
      offset = end
    }
    try decoder.finish()
  } catch {}
  return 0
}
