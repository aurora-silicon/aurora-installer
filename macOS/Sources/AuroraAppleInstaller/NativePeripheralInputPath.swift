#if os(macOS)
  import AuroraFirmware

  /// Which way a Mac's camera, radio, ambient-light and trackpad firmware
  /// reaches its ESP.
  ///
  /// A Mac with a sealed restore-image recipe in this build has those files
  /// extracted from the pinned image and converted natively
  /// (`NativeNeoPeripheralPreparer`, `NeoFirmwareConversions`) before
  /// installation, and they arrive as prepared peripheral inputs. Every other
  /// Mac collects Broadcom radio, camera and ambient-light firmware from its
  /// own macOS while the package is built. The recipe decides, so every step
  /// agrees on the same answer.
  enum NativePeripheralInputPath {
    static func needsPreparation(deviceIdentifier: String) -> Bool {
      FirmwareExtractionPlan.hasBundledRecipe(for: deviceIdentifier)
    }

    /// For a restore manifest's machine name (`j700`), as the source plans use.
    static func needsPreparation(machine: String) -> Bool {
      needsPreparation(deviceIdentifier: "apple," + machine)
    }
  }
#endif
