#if os(macOS)
  import Foundation
  import IOKit

  enum NativeAmbientLightInputs {
    /// Absence is valid on Macs without an onboard sensor. An advertised
    /// sensor with missing, ambiguous or malformed calibration is an error.
    static func live() throws -> Data? {
      var iterator: io_iterator_t = 0
      guard
        IOServiceGetMatchingServices(
          kIOMainPortDefault, IOServiceNameMatching("als"), &iterator) == KERN_SUCCESS
      else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(iterator) }
      let sensor = IOIteratorNext(iterator)
      guard sensor != 0 else { return nil }
      defer { IOObjectRelease(sensor) }
      let other = IOIteratorNext(iterator)
      if other != 0 {
        IOObjectRelease(other)
        throw NativePeripheralInputError.localInput
      }
      var visited = 0
      var records = [Data]()
      func visit(_ entry: io_registry_entry_t, depth: Int) throws {
        visited += 1
        guard depth <= 8, visited <= 256 else { throw NativePeripheralInputError.localInput }
        if let value = IORegistryEntryCreateCFProperty(
          entry, "CalibrationData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        {
          guard let data = value as? Data, !data.isEmpty, data.count <= 1 << 20,
            records.isEmpty
          else { throw NativePeripheralInputError.localInput }
          records.append(data)
        }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS
        else { throw NativePeripheralInputError.localInput }
        defer { IOObjectRelease(children) }
        while true {
          let child = IOIteratorNext(children)
          if child == 0 { break }
          defer { IOObjectRelease(child) }
          try visit(child, depth: depth + 1)
        }
      }
      try visit(sensor, depth: 0)
      guard let calibration = records.first else { throw NativePeripheralInputError.localInput }
      return calibration
    }

    static func files(calibration: Data?, factory: [String: Data]) throws -> [String: Data] {
      guard let calibration else { return [:] }
      guard !calibration.isEmpty, calibration.count <= 1 << 20 else {
        throw NativePeripheralInputError.localInput
      }
      var result = ["apple/aop-als-cal.bin": calibration]
      var total = calibration.count
      for (name, data) in factory where name.hasPrefix("HmCA") {
        guard NativeHandoffEvidence.safeRelative(name), !name.contains("/"),
          !data.isEmpty, data.count <= 32 << 20, data.count <= (64 << 20) - total,
          result.count < 64
        else { throw NativePeripheralInputError.localInput }
        result["apple/" + name] = data
        total += data.count
      }
      return result
    }
  }
#endif
