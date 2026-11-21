#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// The M3 and M4 Macs' device tree carries no Taurus calibration for their
  /// BCM4388: macOS reads it from the factory data, the BTBF field of the
  /// BWCl record. Linux's hci_bcm4377 loads it from the vendor firmware.
  enum NativeBluetoothCalibrationInputs {
    static let name = "apple/bluetooth-taurus-calibration-bf.bin"

    /// Absence is valid: older Macs keep the calibration in the device tree.
    /// A record that cannot be read leaves Bluetooth as it was without it.
    static func files(factory: [String: Data]) -> [String: Data] {
      let records = factory.filter { $0.key.hasPrefix("BWCl-") && !$0.key.contains("/") }
      guard records.count == 1, let record = records.first?.value,
        let fields = try? NeoFirmwareConversions.factoryFields(record, type: "BWCl"),
        let blob = fields["BTBF"], blob.count >= 16, blob.count <= 1 << 20,
        blob.prefix(4) == Data("BLOB".utf8)
      else { return [:] }
      return [name: Data(blob)]
    }
  }
#endif
