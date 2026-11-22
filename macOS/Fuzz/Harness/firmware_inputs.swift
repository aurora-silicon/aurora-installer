// SPDX-License-Identifier: MIT
// Readers that take a set of named firmware files: Broadcom Wi-Fi and
// Bluetooth selection and the vendor firmware package builder.
//
// Input: a selector byte, then records of name size (1), name, data size (2), data.
import Foundation

@testable import AuroraFirmware

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzFirmwareInputs(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  var fields = FuzzFields(fuzzData(bytes, count))
  let selector = fields.int(1)
  var inputs: [String: Data] = [:]
  var ordered: [FirmwarePackageInput] = []
  while fields.cursor < fields.data.count {
    let name = String(decoding: fields.bytes(fields.int(1)), as: UTF8.self)
    let body = fields.bytes(fields.int(2))
    inputs[name] = body
    ordered.append(FirmwarePackageInput(name: name, bytes: body))
  }
  switch selector % 3 {
  case 0:
    _ = try? BroadcomFirmware.wifi(inputs)
    _ = BroadcomFirmware.carriesWiFi(inputs, board: "j314s")
  case 1: _ = try? BroadcomFirmware.bluetooth(inputs)
  default: _ = try? FirmwarePackageBuilder.build(ordered)
  }
  return 0
}
