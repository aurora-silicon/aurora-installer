#if os(macOS)
  import Foundation

  enum NativeFirmwareSelectionError: Error, Equatable {
    case deviceChanged
    case unsupportedDevice
    case unavailableVersion
    case noCompatibleFirmware
    /// The release allows OS firmware for this Mac, but its boot firmware,
    /// macOS or recovery version is older than every such entry needs.
    /// Updating macOS to `version` makes the lowest of them installable.
    case macOSUpdateRequired(version: String)
    case invalidSource
    /// The selected firmware comes only as an OTA update archive whose
    /// Recovery image patches an earlier one. Only whole-image update
    /// archives, such as macOS 14.8.3's, have a native decoder.
    case updateArchiveOnly(version: String)
    /// The restore image isn't the build the policy pins: its size,
    /// manifest or build number differs.
    case pinnedSourceMismatch(build: String)
  }

  struct NativeFirmwareSelection: Equatable, Sendable {
    struct Facts: Sendable {
      let deviceIdentifier: String
      let hardware: NativeInspectionHardware

      static func live() throws -> Self {
        Self(
          deviceIdentifier: try AppleSiliconHostInspector().inspectIdentity().deviceIdentifier,
          hardware: try NativeInspectionHardware.live())
      }
    }

    let version: String
    let sourceURL: URL
    let stubBytes: UInt64
    /// Set when the policy names one exact build for this version.
    var pin: NativeFirmwarePin? = nil

    /// The image the server offers must be the pinned one, byte count first:
    /// it is known before any member is read.
    func requirePinnedSource(bytes: Int) throws {
      guard let pin else { return }
      guard bytes >= 0, UInt64(bytes) == pin.sourceBytes else {
        throw NativeFirmwareSelectionError.pinnedSourceMismatch(build: pin.build)
      }
    }

    /// The selected manifest and build identity must be the pinned ones.
    func requirePinnedManifest(_ manifest: Data, buildNumber: String) throws {
      guard let pin else { return }
      guard SHA256Digest(hashing: manifest).rawValue == pin.manifestSHA256,
        buildNumber == pin.build
      else { throw NativeFirmwareSelectionError.pinnedSourceMismatch(build: pin.build) }
    }

    /// Execution requires usable versions. Inspection's conservative size
    /// fallback is intentionally not an installation admission rule.
    static func choose(
      deviceIdentifier: String, facts: Facts, metadata: NativeInstallationMetadata,
      policy: NativeInspectionPolicy
    ) throws -> Self {
      guard facts.deviceIdentifier == deviceIdentifier else {
        throw NativeFirmwareSelectionError.deviceChanged
      }
      guard policy.supports(deviceIdentifier, hardware: facts.hardware),
        let chip = policy.chipMinimum[String(facts.hardware.chipID)],
        let device = policy.devices[String(deviceIdentifier.dropFirst(6))]
      else { throw NativeFirmwareSelectionError.unsupportedDevice }
      guard let boot = facts.hardware.bootVersion, let macOS = facts.hardware.macOSVersion,
        let recovery = facts.hardware.recoveryVersion,
        !boot.isEmpty, !macOS.isEmpty, !recovery.isEmpty
      else { throw NativeFirmwareSelectionError.unavailableVersion }
      let target = try metadata.target()
      let minimum =
        try NativeInspectionPolicy.Version.atLeast(chip, device.minimum)
        ? chip : device.minimum
      var selected: NativeInspectionPolicy.Firmware?
      var lowest: NativeInspectionPolicy.Firmware?
      // Preserve source order: the backend chooses the last compatible entry,
      // not the entry with the numerically highest version.
      for entry in policy.firmware {
        guard try NativeInspectionPolicy.Version.atLeast(entry.version, minimum),
          target.supportedFirmware?.contains(entry.version) ?? true,
          entry.models?.contains(String(deviceIdentifier.dropFirst(6))) ?? true,
          !entry.expert
        else { continue }
        // The lowest version this Mac and release may use at all names the
        // macOS update that makes one installable, as the backend's message does.
        if try lowest.map({ try entry.isOlder(than: $0) }) ?? true { lowest = entry }
        if try NativeInspectionPolicy.Version.atLeast(boot, entry.minimumBoot),
          try NativeInspectionPolicy.Version.atLeast(macOS, entry.minimumMacOS),
          try NativeInspectionPolicy.Version.atLeast(recovery, entry.minimumRecovery)
        {
          selected = entry
        }
      }
      guard let selected else {
        guard let lowest else { throw NativeFirmwareSelectionError.noCompatibleFirmware }
        throw NativeFirmwareSelectionError.macOSUpdateRequired(version: lowest.version)
      }
      guard let components = URLComponents(string: selected.sourceURL),
        components.scheme == "https", components.host == "updates.cdn-apple.com",
        components.user == nil, components.password == nil, components.port == nil,
        components.query == nil, components.fragment == nil,
        !components.path.isEmpty, let url = components.url
      else { throw NativeFirmwareSelectionError.invalidSource }
      try selected.pin?.validate(sourceURL: url)
      return Self(
        version: selected.version, sourceURL: url,
        stubBytes: try NativeInspectionPolicy.Version.atLeast(selected.version, "26.0")
          ? 5_999_951_872 : 2_499_805_184,
        pin: selected.pin)
    }
  }

  extension NativeInspectionPolicy.Firmware {
    fileprivate func isOlder(than other: Self) throws -> Bool {
      try !NativeInspectionPolicy.Version.atLeast(version, other.version)
    }
  }
#endif
