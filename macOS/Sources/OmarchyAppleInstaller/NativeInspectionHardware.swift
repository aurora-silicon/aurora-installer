#if os(macOS)
  import Foundation
  import IOKit

  extension NativeInspectionHardware {
    static func live() throws -> Self {
      let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
      guard entry != 0 else { throw NativeInspectionError.invalidPolicy }
      defer { IOObjectRelease(entry) }
      func bytes(_ name: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
      }
      guard let chip = bytes("chip-id"), [4, 8].contains(chip.count) else {
        throw NativeInspectionError.invalidPolicy
      }
      let chipID = chip.enumerated().reduce(UInt64(0)) { value, item in
        value | (UInt64(item.element) << (8 * item.offset))
      }
      let boot = bytes("system-firmware-version").flatMap {
        String(data: Data($0.prefix { $0 != 0 }), encoding: .utf8)
      }
      func version(_ path: String, _ key: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 65_536,
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else { return nil }
        return plist[key] as? String
      }
      return Self(chipID: chipID, bootVersion: boot,
        macOSVersion: version("/System/Library/CoreServices/SystemVersion.plist", "ProductVersion"),
        recoveryVersion: version("/System/Volumes/iSCPreboot/SFR/current/RestoreVersion.plist", "RestoreLongVersion"))
    }
  }
#endif
