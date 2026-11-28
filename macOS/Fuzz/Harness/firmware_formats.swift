// SPDX-License-Identifier: MIT
// Single-blob firmware readers: IMG4/IM4P DER, the ordered XML plist, kernel
// Mach-O scans, Neo camera/radio/calibration records and signed sensor
// records. The first input byte picks the reader.
import Foundation

@testable import AuroraFirmware

func fuzzDERWalk(_ data: Data, _ element: FirmwareDER.Element, depth: Int) {
  guard depth < 32, let children = try? FirmwareDER.children(data, element) else { return }
  for child in children { fuzzDERWalk(data, child, depth: depth + 1) }
}

/// swift-corelibs-foundation's XMLParser dereferences a null pointer on a
/// processing instruction with no data (`<?pi?>`); Darwin's does not. Such
/// inputs are skipped so the Linux run exercises the installer's own reader.
func fuzzLinuxXMLParserCrashes(_ data: Data) -> Bool {
  #if os(Linux)
    let text = String(decoding: data, as: UTF8.self)
    return text.range(of: #"<\?[^?\s]*\s*\?>"#, options: .regularExpression) != nil
  #else
    return false
  #endif
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzFirmwareFormats(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  guard count > 0 else { return 0 }
  let data = fuzzData(bytes + 1, count - 1)
  if fuzzLinuxXMLParserCrashes(data) { return 0 }
  switch bytes[0] % 20 {
  case 0: _ = try? FirmwareImage.decode(data)
  case 1: _ = try? FirmwareImage.controllerFirmware(in: data)
  case 2: _ = try? ProResInitFirmware.extract(from: data)
  case 3: _ = try? MultitouchFirmware.convert(data, machine: "j314s")
  case 4: _ = try? FirmwarePlist.decode(data)
  case 5:
    _ = try? NeoFirmwareConversions.camera(data, requireNeoSet: false)
    _ = try? NeoFirmwareConversions.camera(data)
  case 6: _ = try? NeoFirmwareConversions.alsCalibration(data)
  case 7: _ = try? NeoFirmwareConversions.bluetoothAddress(data)
  case 8: _ = try? NeoFirmwareConversions.configuration(data)
  case 9: _ = try? NeoFirmwareConversions.factoryFields(data)
  case 10: _ = try? NeoFirmwareConversions.validateOCA2(data)
  case 11: _ = try? NeoFirmwareConversions.validateBluetooth(data)
  case 12: _ = try? NeoFirmwareConversions.validatePTX(data)
  case 13: _ = try? NeoFirmwareConversions.policy(data, country: "US")
  case 14: _ = try? SignedSensorInputs.rootKey(data)
  case 15: _ = try? SignedSensorInputs.sealedCalibration(data)
  case 16: _ = try? SignedSensorInputs.preparedCalibration(data)
  case 17: _ = try? SignedSensorInputs.calibration(in: data)
  case 18:
    var fields = FuzzFields(data)
    let record = fields.bytes(fields.int(2))
    let seal = fields.bytes(fields.int(2))
    let trust = fields.rest()
    _ = try? SignedSensorInputs.loadableCalibration(record, seal: seal, trust: trust)
    _ = try? SignedSensorInputs.reseal(record, seal: seal, trust: trust)
  default:
    if let outer = try? FirmwareDER.element(data, at: 0, limit: data.count) {
      fuzzDERWalk(data, outer, depth: 0)
    }
  }
  return 0
}
