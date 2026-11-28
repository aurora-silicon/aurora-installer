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
    /// This Mac already runs the macOS the release needs, but its boot
    /// firmware or Recovery is older than the entry asks. Updating macOS to
    /// the same version would not help, so this names what is short.
    case firmwareBelowRelease(NativeFirmwareShortfall)
    case invalidSource
    /// The selected firmware comes only as an OTA update archive whose
    /// Recovery image patches an earlier one. Only whole-image update
    /// archives, such as macOS 14.8.3's, have a native decoder.
    case updateArchiveOnly(version: String)
    /// The restore image isn't the build the policy pins: its size,
    /// manifest or build number differs.
    case pinnedSourceMismatch(build: String)
    /// A developer's stub override names no entry this Mac may use, or one
    /// the release doesn't list.
    case stubOverride(NativeStubOverrideError)
  }

  /// Which minimum of a firmware entry this Mac missed, with both values.
  struct NativeFirmwareShortfall: Equatable, Sendable {
    enum Check: String, Equatable, Sendable {
      case boot = "boot firmware"
      case macOS
      case recovery = "Recovery"
    }
    let version: String
    let check: Check
    let detected: String
    let required: String

    var summary: String {
      "macOS \(version) needs \(check.rawValue) \(required) or later; this Mac has \(detected)."
    }
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
    ///
    /// `stubOverride` (Developer mode or `--stub-version`) limits the choice
    /// to that one known entry. It still has to pass the same release and
    /// boot firmware, macOS and Recovery checks, and an override that names
    /// no entry for this Mac is refused, never made up. `nil` is the default
    /// choice, unchanged.
    static func choose(
      deviceIdentifier: String, facts: Facts, metadata: NativeInstallationMetadata,
      policy: NativeInspectionPolicy, stubOverride: StubOverrideChoice? = nil
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
      var shortfall: NativeFirmwareShortfall?
      var verdicts = [String]()
      var overrideKnown = false
      // Preserve source order: the backend chooses the last compatible entry,
      // not the entry with the numerically highest version.
      for entry in policy.firmware {
        if let stubOverride {
          guard entry.stubChoice == stubOverride,
            try NativeInspectionPolicy.Version.atLeast(entry.version, minimum),
            entry.models?.contains(String(deviceIdentifier.dropFirst(6))) ?? true,
            !entry.expert
          else { continue }
          overrideKnown = true
        }
        guard try NativeInspectionPolicy.Version.atLeast(entry.version, minimum),
          target.supportedFirmware?.contains(entry.version) ?? true,
          entry.models?.contains(String(deviceIdentifier.dropFirst(6))) ?? true,
          !entry.expert
        else { continue }
        // The lowest version this Mac and release may use at all names the
        // macOS update that makes one installable, as the backend's message does.
        if try lowest.map({ try entry.isOlder(than: $0) }) ?? true { lowest = entry }
        let bootOK = try NativeInspectionPolicy.Version.bootAtLeast(boot, entry.minimumBoot)
        let macOSOK = try NativeInspectionPolicy.Version.atLeast(macOS, entry.minimumMacOS)
        let recoveryOK = try NativeInspectionPolicy.Version.atLeast(
          recovery, entry.minimumRecovery)
        verdicts.append(
          "Firmware \(entry.version)\(entry.pin.map { " (\($0.build))" } ?? ""): boot \(boot) >= "
            + "\(entry.minimumBoot) \(bootOK), macOS \(macOS) >= \(entry.minimumMacOS) \(macOSOK), "
            + "Recovery \(recovery) >= \(entry.minimumRecovery) \(recoveryOK)")
        if bootOK, macOSOK, recoveryOK {
          selected = entry
        } else if macOSOK, try NativeInspectionPolicy.Version.atLeast(macOS, entry.version) {
          // This Mac already runs this entry's macOS, so updating to it can't
          // help: say which of its other minimums is short. Below the entry's
          // version, installing that macOS brings its firmware and Recovery.
          shortfall =
            bootOK
            ? NativeFirmwareShortfall(
              version: entry.version, check: .recovery, detected: recovery,
              required: entry.minimumRecovery)
            : NativeFirmwareShortfall(
              version: entry.version, check: .boot, detected: boot, required: entry.minimumBoot)
        }
      }
      if let stubOverride, lowest == nil {
        guard overrideKnown else {
          let known =
            (try? NativeStubOverride.candidates(
              deviceIdentifier: deviceIdentifier, hardware: facts.hardware, policy: policy)) ?? []
          throw NativeFirmwareSelectionError.stubOverride(
            .unknown(requested: stubOverride.title, known: known.map(\.title)))
        }
        throw NativeFirmwareSelectionError.stubOverride(.notInRelease(stubOverride.title))
      }
      guard let selected else {
        // Named once, only when nothing fits: each entry's three checks.
        if !verdicts.isEmpty {
          InstallerLog.error("No boot firmware fits this Mac. " + verdicts.joined(separator: "; "))
        }
        guard let lowest else { throw NativeFirmwareSelectionError.noCompatibleFirmware }
        // Only a Mac below the macOS an entry needs is told to update macOS.
        if let shortfall { throw NativeFirmwareSelectionError.firmwareBelowRelease(shortfall) }
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
