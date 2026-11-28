// SPDX-License-Identifier: MIT
// The unmounted FAT32 reader that removal and the preserved-ESP capacity
// check use on an EFI partition: boot sector geometry, FAT chains, 8.3 and
// VFAT long-name directory records. The input is the partition.
import Foundation

@testable import AuroraFirmware

/// What the FAT source names from the rest of the installer target.
struct RemovalFailure: Error {
  let message: String
}
struct RemovalFileTree {
  func read(_ components: [String], limit: Int) throws -> Data? { nil }
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzFATVolume(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  let partition = fuzzData(bytes, count)
  do {
    let volume = try RemovalFATVolume(size: UInt64(partition.count)) { offset, length in
      guard offset <= UInt64(partition.count) else { throw RemovalFailure(message: "range") }
      return try partition.part(Int(offset), length)
    }
    _ = try? volume.freeBytes()
    for path in [
      ["m1n1", "boot.bin"], ["asahi", "stub_info.json"], ["asahi", "installer.log"],
      ["omarchy", "install.conf"], ["EFI", "BOOT", "BOOTAA64.EFI"],
    ] {
      do {
        if let data = try volume.read(path, limit: 1 << 20), path.last == "install.conf" {
          _ = try? InstallConf.parse(data)
        }
      } catch { fuzzNote("read \(path)", error) }
    }
  } catch {
    fuzzNote("volume", error)
  }
  return 0
}
