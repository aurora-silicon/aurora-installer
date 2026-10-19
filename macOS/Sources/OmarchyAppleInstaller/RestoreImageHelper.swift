#if os(macOS)
  import Darwin
  import Foundation

  public enum RestoreImageHelperError: Error, Equatable, Sendable {
    case unavailable
    case unsafeFile
    case signatureRejected
  }

  /// The Swift decoder the engine runs for macOS 26 restore images and the
  /// MacBook Neo's radio inputs (Engine/RestoreImage). It ships in the app's
  /// sealed `Contents/Helpers`, never in the byte-pinned engine archive, so the
  /// release signing gives it a Developer ID, the hardened runtime and a
  /// secure timestamp like every other piece of the app's code.
  ///
  /// The app hands its copy to the privileged helper in the handoff package;
  /// the helper imports it into its root-only package directory, checks the
  /// copy's signature against the requirement below and passes both to the
  /// engine, which checks them again before every use.
  public enum RestoreImageHelper {
    public static let fileName = "omarchy-restore-image"
    public static let identifier = InstallerBuildConfiguration.restoreImageIdentifier
    public static let pathEnvironmentVariable = "OMARCHY_RESTORE_IMAGE"
    public static let requirementEnvironmentVariable = "OMARCHY_RESTORE_IMAGE_REQUIREMENT"
    /// The build is about 0.5 MB; anything near this is not the decoder.
    public static let maximumBytes: UInt64 = 33_554_432

    public static func bundledURL(in bundle: URL = Bundle.main.bundleURL) -> URL {
      bundle.appendingPathComponent("Contents/Helpers/\(fileName)", isDirectory: false)
    }

    /// The designated requirement of a Developer ID build of the decoder: a
    /// Developer ID Application certificate (TN3127: the Developer ID CA
    /// intermediate and the leaf's Developer ID Application marker) of the
    /// app's team, not just any Apple-issued certificate with that team.
    public static func developerIDRequirement(team: String) -> String {
      "anchor apple generic and identifier \"\(identifier)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// An ad hoc build is identified by its exact code hash: an ad hoc
    /// identifier alone proves nothing.
    public static func adHocRequirement(codeHash: String) -> String {
      "identifier \"\(identifier)\" and cdhash H\"\(codeHash)\""
    }

    /// The requirement the privileged helper holds the decoder to, from its
    /// launchd environment. An explicit `OMARCHY_RESTORE_IMAGE_REQUIREMENT`
    /// (the signing scripts and the ad hoc blesser record it) wins and must
    /// be one of the two forms above. Otherwise a helper whose client is
    /// pinned to a Developer ID team (an SMJobBless install, whose embedded
    /// job carries only that) holds the decoder to the same team. Anything
    /// else has no decoder identity, and installs that need one are refused.
    public static func requirement(environment: [String: String]) -> String? {
      if let pinned = environment[requirementEnvironmentVariable] {
        return isAccepted(pinned) ? pinned : nil
      }
      guard
        let client = environment[InstallerProductIdentity.clientRequirementEnvironmentVariable],
        let team = teamIdentifier(inClientRequirement: client)
      else {
        return nil
      }
      return developerIDRequirement(team: team)
    }

    static func isAccepted(_ requirement: String) -> Bool {
      let identifier = NSRegularExpression.escapedPattern(for: identifier)
      let team =
        "\\Aanchor apple generic and identifier \"\(identifier)\""
        + " and certificate 1\\[field\\.1\\.2\\.840\\.113635\\.100\\.6\\.2\\.6\\]"
        + " and certificate leaf\\[field\\.1\\.2\\.840\\.113635\\.100\\.6\\.1\\.13\\]"
        + " and certificate leaf\\[subject\\.OU\\] = \"[A-Z0-9]{10}\"\\z"
      let adHoc =
        "\\Aidentifier \"\(identifier)\" and cdhash H\"[0-9a-f]{40}(?:[0-9a-f]{24})?\"\\z"
      return [team, adHoc].contains {
        requirement.range(of: $0, options: .regularExpression) != nil
      }
    }

    static func teamIdentifier(inClientRequirement client: String) -> String? {
      let prefix =
        "anchor apple generic and identifier \"\(InstallerProductIdentity.appIdentifier)\""
        + " and certificate leaf[subject.OU] = \""
      guard client.hasPrefix(prefix), client.hasSuffix("\"") else { return nil }
      let team = String(client.dropFirst(prefix.count).dropLast())
      guard team.range(of: "\\A[A-Z0-9]{10}\\z", options: .regularExpression) != nil else {
        return nil
      }
      return team
    }

    /// Checks the signature of `file` against `requirement` with codesign, strictly.
    public static func verify(_ file: URL, requirement: String) throws {
      var status = stat()
      guard lstat(file.path, &status) == 0 else {
        throw RestoreImageHelperError.unavailable
      }
      guard (status.st_mode & S_IFMT) == S_IFREG,
        status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & S_IXUSR != 0,
        status.st_mode & 0o022 == 0,
        status.st_size > 0,
        UInt64(status.st_size) <= maximumBytes
      else {
        throw RestoreImageHelperError.unsafeFile
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      process.arguments = ["--verify", "--strict", "-R=" + requirement, file.path]
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        throw RestoreImageHelperError.signatureRejected
      }
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw RestoreImageHelperError.signatureRejected
      }
    }
  }
#endif
