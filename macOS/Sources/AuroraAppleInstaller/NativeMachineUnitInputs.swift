#if os(macOS)
  import Darwin
  import Foundation
  import IOKit

  /// The allow-list of what firmware collection reads from this Mac itself.
  ///
  /// Per-model data (speaker tunings, the AudioDSP component, the MacBook
  /// Neo's regulatory tables and other firmware-like files) comes only from
  /// Apple's pinned restore images, through sealed range recipes
  /// (`SpeakerTuningRestoreImages`, `FirmwareExtractionPlan`), never from
  /// the running macOS and never with a fallback to it. Only values that
  /// belong to this one unit, not to its model, are read from the machine,
  /// read only, and only here and in the factory-data readers listed below:
  ///
  /// - `acoustic-id` (device tree audio node): names this unit's tuning
  ///   folder. The board's restore image must name the same AID for the
  ///   board in its own device tree, or there is no tuning.
  /// - `speaker-thiele-small` (same node): the factory calibration of this
  ///   unit's speakers (driver resistance and calibration temperature).
  /// - `speakerID` of the built-in `Speaker` device (IORegistry service
  ///   plane): the strap of the speaker assembly fitted to this unit, which
  ///   selects among the tuning's speaker vendor variants.
  /// - `serial-number` (device tree root): reduced at once to the unit ID
  ///   that binds the calibration to this unit; never stored or logged.
  /// - `target-type` (device tree root): which board this unit is; selects
  ///   the restore image whose BuildManifest carries it.
  /// - the `wlan` node's `module-instance` (device tree,
  ///   `NativeSystemWiFiFirmware.board`): the Wi-Fi module fitted to this
  ///   unit. The stub's restore image must name the same board for the
  ///   model; the firmware itself comes from that image.
  ///
  /// Factory data, per unit, with their own admission (unchanged):
  /// ambient-light LSCI (`NativeAmbientLightInputs`), Touch ID FSC2/FSCl and
  /// the MSRk root key (`NativeFactoryCalibrationInput`,
  /// `NativeSensorInputCollector`), and the MacBook Neo's BWC2 radio
  /// calibration and Bluetooth address (`NativeNeoLocalInputs`).
  enum NativeMachineUnitInputs {
    /// This unit's speaker identity, or nil on a Mac without an audio node
    /// that carries an `acoustic-id`. `build` is left empty: it is the
    /// restore image's, not the running macOS's.
    static func audio() throws -> NativeAudioTuningInputs.Device? {
      guard let (acoustic, thieleSmall) = try audioNode(),
        let acousticID = NativeAudioTuningInputs.acousticID(acoustic)
      else { return nil }
      let (board, unit) = identity()
      return NativeAudioTuningInputs.Device(
        acousticID: acousticID, thieleSmall: thieleSmall, build: "",
        speakerID: NativeAudioTuningInputs.liveSpeakerID(speakerServices), board: board,
        unitID: unit)
    }

    /// `(board, unit ID)` from the device tree root, read only; either is
    /// nil when unknown.
    static func identity() -> (String?, String?) {
      let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
      guard root != 0 else { return (nil, nil) }
      defer { IOObjectRelease(root) }
      func data(_ key: String) -> Data? {
        IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
      }
      return (
        data("target-type").flatMap(NativeAudioTuningInputs.board),
        data("serial-number").flatMap(NativeAudioTuningInputs.unitID)
      )
    }

    /// `device UID` and `speakerID` of every `AppleEmbeddedAudioDevice` in
    /// the service plane. Read only: no user client is opened and nothing
    /// is written. Empty on any failure.
    static func speakerServices() -> [[String: Any]] {
      guard let matching = IOServiceMatching(NativeAudioTuningInputs.speakerServiceClass) else {
        return []
      }
      var iterator: io_iterator_t = 0
      guard
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
      else { return [] }
      defer { IOObjectRelease(iterator) }
      var services = [[String: Any]]()
      while true {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        guard services.count < 256 else { return [] }
        var properties = [String: Any]()
        for key in ["device UID", "speakerID"] {
          if let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          {
            properties[key] = value
          }
        }
        services.append(properties)
      }
      return services
    }

    /// `acoustic-id` and `speaker-thiele-small` of the one device-tree audio
    /// node that carries an acoustic ID. Nil when there is none; two such
    /// nodes leave the folder ambiguous, as for the Python collector
    /// (`ioreg -n audio -k acoustic-id` must list exactly one).
    static func audioNode() throws -> (Data, Data?)? {
      func read(_ entry: io_registry_entry_t) -> (Data, Data?)? {
        guard
          let acoustic = IORegistryEntryCreateCFProperty(
            entry, "acoustic-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? Data
        else { return nil }
        let spts =
          IORegistryEntryCreateCFProperty(
            entry, "speaker-thiele-small" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
        return (acoustic, spts)
      }
      var iterator: io_iterator_t = 0
      guard
        IORegistryCreateIterator(
          kIOMainPortDefault, kIODeviceTreePlane, IOOptionBits(kIORegistryIterateRecursively),
          &iterator) == KERN_SUCCESS
      else { return nil }
      defer { IOObjectRelease(iterator) }
      var found: (Data, Data?)?
      var count = 0
      while true {
        try Task.checkCancellation()
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        count += 1
        guard count <= 65_536 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(entry, kIODeviceTreePlane, &name) == KERN_SUCCESS,
          String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == "audio",
          let properties = read(entry)
        else { continue }
        // Two audio nodes with acoustic IDs leave the folder ambiguous.
        guard found == nil else { throw NativePeripheralInputError.localInput }
        found = properties
      }
      return found
    }
  }
#endif
