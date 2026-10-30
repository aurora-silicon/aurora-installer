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

    /// Execution requires usable versions. Inspection's conservative size
    /// fallback is intentionally not an installation admission rule.
    static func choose(
      deviceIdentifier: String, facts: Facts, metadata: NativeInstallationMetadata,
      policy: NativeInspectionPolicy, experimental: Bool = false
    ) throws -> Self {
      guard facts.deviceIdentifier == deviceIdentifier else {
        throw NativeFirmwareSelectionError.deviceChanged
      }
      // An experimental installation passes the policy its assessment widened
      // for this one Mac; the explicit refusal list is what it overrides.
      guard experimental || !AppleSiliconHostInspector.isExplicitlyUnsupported(deviceIdentifier),
        policy.supports(deviceIdentifier, hardware: facts.hardware),
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
      return Self(
        version: selected.version, sourceURL: url,
        stubBytes: try NativeInspectionPolicy.Version.atLeast(selected.version, "26.0")
          ? 5_999_951_872 : 2_499_805_184)
    }
  }

  extension NativeInspectionPolicy.Firmware {
    fileprivate func isOlder(than other: Self) throws -> Bool {
      try !NativeInspectionPolicy.Version.atLeast(version, other.version)
    }
  }
#endif
