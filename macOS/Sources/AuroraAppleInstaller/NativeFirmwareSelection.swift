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
      let board = String(deviceIdentifier.dropFirst(6))
      var selected: (index: Int, entry: NativeInspectionPolicy.Firmware)?
      var lowest: NativeInspectionPolicy.Firmware?
      var shortfall: NativeFirmwareShortfall?
      // The last pinned build that names this board, and what this Mac lacks
      // for it when it already runs that build's macOS.
      var pinned: (index: Int, entry: NativeInspectionPolicy.Firmware)?
      var pinnedShortfall: NativeFirmwareShortfall?
      var verdicts = [String]()
      // Preserve source order: the backend chooses the last compatible entry,
      // not the entry with the numerically highest version.
      for (index, entry) in policy.firmware.enumerated() {
        guard try NativeInspectionPolicy.Version.atLeast(entry.version, minimum),
          target.supportedFirmware?.contains(entry.version) ?? true,
          entry.models?.contains(board) ?? true,
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
        var entryShortfall: NativeFirmwareShortfall?
        if bootOK, macOSOK, recoveryOK {
          selected = (index, entry)
        } else if macOSOK, try NativeInspectionPolicy.Version.atLeast(macOS, entry.version) {
          // This Mac already runs this entry's macOS, so updating to it can't
          // help: say which of its other minimums is short. Below the entry's
          // version, installing that macOS brings its firmware and Recovery.
          entryShortfall =
            bootOK
            ? NativeFirmwareShortfall(
              version: entry.version, check: .recovery, detected: recovery,
              required: entry.minimumRecovery)
            : NativeFirmwareShortfall(
              version: entry.version, check: .boot, detected: boot, required: entry.minimumBoot)
          shortfall = entryShortfall
        }
        // A pinned build that names this board is the startup firmware the
        // board is admitted to.
        if entry.pin != nil, entry.models?.contains(board) == true {
          pinned = (index, entry)
          pinnedShortfall = entryShortfall
        }
      }
      // A board admitted to a pinned build doesn't fall back to an older entry
      // because this Mac is below the build's minimums: below its macOS, the
      // owner updates macOS first; already on it, the message names the short
      // boot firmware or Recovery. A release that leaves the build out of
      // `supported_fw`, and every board the build doesn't name, keeps its
      // older entry.
      if let pinned, (selected?.index ?? -1) < pinned.index {
        InstallerLog.error(
          "This Mac is below the pinned boot firmware it is admitted to. "
            + verdicts.joined(separator: "; "))
        if let pinnedShortfall {
          throw NativeFirmwareSelectionError.firmwareBelowRelease(pinnedShortfall)
        }
        throw NativeFirmwareSelectionError.macOSUpdateRequired(version: pinned.entry.version)
      }
      guard let selected = selected?.entry else {
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
