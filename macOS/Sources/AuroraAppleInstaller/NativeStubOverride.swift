#if os(macOS)
  import Foundation

  /// A macOS stub picked instead of the default the policy chooses for this
  /// Mac. It names one firmware entry the sealed policy already lists for
  /// this Mac, by version and build; the engine never makes up an entry.
  /// The picked entry must still pass its own boot firmware, macOS and
  /// Recovery minimums, and the restore image is still checked against the
  /// entry's pin like any other.
  public struct StubOverrideChoice: Hashable, Sendable, Identifiable, Codable {
    /// The macOS version, for example "26.6".
    public let version: String
    /// The macOS build, for example "25G83". Empty only for an entry whose
    /// source names no build (an update archive).
    public let build: String

    public init(version: String, build: String) {
      self.version = version
      self.build = build
    }

    public var id: String { version + " " + build }
    public var title: String { build.isEmpty ? "macOS \(version)" : "macOS \(version) (\(build))" }

    /// A version or build string that can be one of the policy's: short,
    /// ASCII letters, digits and dots.
    static func isWellFormed(_ value: String, allowsEmpty: Bool) -> Bool {
      (allowsEmpty || !value.isEmpty) && value.utf8.count <= 32
        && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
    }

    var isWellFormed: Bool {
      Self.isWellFormed(version, allowsEmpty: false) && Self.isWellFormed(build, allowsEmpty: true)
    }
  }

  /// Why a requested stub override can't be used. Nothing is installed.
  public enum NativeStubOverrideError: Error, Equatable, Sendable {
    /// The request names no firmware entry the policy lists for this Mac.
    case unknown(requested: String, known: [String])
    /// The version names more than one entry for this Mac; name the build.
    case ambiguous(requested: String, builds: [String])
    /// The entry is known for this Mac, but the signed release doesn't list
    /// its version as firmware for its images.
    case notInRelease(String)

    public var message: String {
      switch self {
      case .unknown(let requested, let known):
        return "macOS stub \(requested) is not one this Mac’s policy knows. "
          + (known.isEmpty
            ? "The policy lists no stub for this Mac."
            : "Choose one of: \(known.joined(separator: ", ")).")
      case .ambiguous(let requested, let builds):
        return "macOS stub \(requested) names more than one build for this Mac. "
          + "Name the build instead: \(builds.joined(separator: ", "))."
      case .notInRelease(let title):
        return "This release doesn’t list \(title) as firmware for this Mac."
      }
    }
  }

  extension NativeInspectionPolicy.Firmware {
    /// The build this entry installs: its pin's, else the one its restore
    /// image's file name carries. An update archive's name has none.
    var build: String { pin?.build ?? NativeStubOverride.build(inSourceURL: sourceURL) }

    var stubChoice: StubOverrideChoice { StubOverrideChoice(version: version, build: build) }
  }

  extension NativeFirmwareSelection {
    /// The policy entry this selection came from, as an override would name it.
    var stubChoice: StubOverrideChoice {
      StubOverrideChoice(
        version: version,
        build: pin?.build ?? NativeStubOverride.build(inSourceURL: sourceURL.absoluteString))
    }
  }

  public enum NativeStubOverride {
    /// The stubs the sealed policy knows for this Mac, in policy order.
    /// Empty when this Mac has fewer than two, so there is nothing to pick,
    /// or when its facts can't be read.
    public static func candidates(deviceIdentifier: String) -> [StubOverrideChoice] {
      guard let hardware = try? NativeInspectionHardware.live(),
        let policy = try? NativeInspectionPolicy.sealed(),
        let known = try? candidates(
          deviceIdentifier: deviceIdentifier, hardware: hardware, policy: policy),
        known.count > 1
      else { return [] }
      return known
    }

    /// `candidates(deviceIdentifier:)` for the Mac this runs on.
    public static func candidatesForThisMac() -> [StubOverrideChoice] {
      guard let identity = try? AppleSiliconHostInspector().inspectIdentity() else { return [] }
      return candidates(deviceIdentifier: identity.deviceIdentifier)
    }

    /// Every firmware entry this Mac may use at all: at or above its chip's
    /// and model's minimum, listed for its model, and not expert-only. The
    /// release and this Mac's own versions are checked when one is chosen.
    static func candidates(
      deviceIdentifier: String, hardware: NativeInspectionHardware, policy: NativeInspectionPolicy
    ) throws -> [StubOverrideChoice] {
      try knownEntries(deviceIdentifier: deviceIdentifier, hardware: hardware, policy: policy)
        .map(\.stubChoice)
    }

    /// The known entry a version or build names, as `--stub-version` and the
    /// Developer mode menu ask for it. A build matches exactly (ignoring
    /// case); a version must name a single entry for this Mac.
    public static func resolve(_ requested: String, deviceIdentifier: String) throws
      -> StubOverrideChoice
    {
      try resolve(
        requested, deviceIdentifier: deviceIdentifier, hardware: NativeInspectionHardware.live(),
        policy: NativeInspectionPolicy.sealed())
    }

    static func resolve(
      _ requested: String, deviceIdentifier: String, hardware: NativeInspectionHardware,
      policy: NativeInspectionPolicy
    ) throws -> StubOverrideChoice {
      let known = try candidates(
        deviceIdentifier: deviceIdentifier, hardware: hardware, policy: policy)
      let wanted = requested.trimmingCharacters(in: .whitespaces)
      let byBuild = known.filter {
        !$0.build.isEmpty && $0.build.caseInsensitiveCompare(wanted) == .orderedSame
      }
      if let choice = byBuild.first { return choice }
      let byVersion = known.filter { $0.version == wanted }
      guard let choice = byVersion.first else {
        throw NativeStubOverrideError.unknown(requested: wanted, known: known.map(\.title))
      }
      guard byVersion.count == 1 else {
        throw NativeStubOverrideError.ambiguous(requested: wanted, builds: byVersion.map(\.build))
      }
      return choice
    }

    /// The stub this Mac gets with no override, for the release's signed
    /// metadata; `nil` when none fits this Mac.
    public static func defaultChoice(
      deviceIdentifier: String, metadata: StagedInstallerArtifact
    ) -> StubOverrideChoice? {
      guard let facts = try? NativeFirmwareSelection.Facts.live(),
        let installation = try? NativeInstallationMetadata.authenticated(metadata),
        let policy = try? NativeInspectionPolicy.sealed(),
        let selection = try? NativeFirmwareSelection.choose(
          deviceIdentifier: deviceIdentifier, facts: facts, metadata: installation, policy: policy)
      else { return nil }
      return selection.stubChoice
    }

    /// The one line the install log and the plan show while an override is
    /// in effect.
    public static func warning(chosen: StubOverrideChoice, default standard: StubOverrideChoice?)
      -> String
    {
      "macOS stub override: \(describe(chosen)) instead of the default "
        + (standard.map(describe) ?? "(none fits this Mac)")
        + "; this combination is untested"
    }

    private static func describe(_ choice: StubOverrideChoice) -> String {
      choice.build.isEmpty ? choice.version : "\(choice.version) (\(choice.build))"
    }

    static func knownEntries(
      deviceIdentifier: String, hardware: NativeInspectionHardware, policy: NativeInspectionPolicy
    ) throws -> [NativeInspectionPolicy.Firmware] {
      guard policy.supports(deviceIdentifier, hardware: hardware),
        let chip = policy.chipMinimum[String(hardware.chipID)],
        let device = policy.devices[String(deviceIdentifier.dropFirst(6))]
      else { throw NativeFirmwareSelectionError.unsupportedDevice }
      let minimum =
        try NativeInspectionPolicy.Version.atLeast(chip, device.minimum) ? chip : device.minimum
      let model = String(deviceIdentifier.dropFirst(6))
      return try policy.firmware.filter {
        try NativeInspectionPolicy.Version.atLeast($0.version, minimum)
          && ($0.models?.contains(model) ?? true) && !$0.expert
      }
    }

    /// `UniversalMac_26.6.2_25G83_Restore.ipsw` names build 25G83.
    static func build(inSourceURL sourceURL: String) -> String {
      let name = sourceURL.split(separator: "/").last.map(String.init) ?? ""
      let parts = name.split(separator: "_")
      guard parts.count >= 4, name.hasSuffix("_Restore.ipsw") else { return "" }
      let build = String(parts[parts.count - 2])
      return StubOverrideChoice.isWellFormed(build, allowsEmpty: false) ? build : ""
    }
  }
#endif
