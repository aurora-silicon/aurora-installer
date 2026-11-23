#if os(macOS)
  import Foundation

  /// The code-signing requirement the privileged helper holds its client, the
  /// installer app, to. The helper reads it from its launchd job and enforces
  /// only the forms below; any other text, even one that compiles, is refused,
  /// so a job file never widens who may drive the helper.
  public enum HelperClientRequirement {
    /// An ad hoc app bundle carries this in its embedded job: it accepts no
    /// client until a package pins the final app's code hash.
    public static let denyAll = "never"

    private static let anchoredIdentifier =
      "anchor apple generic and identifier \"\(InstallerProductIdentity.appIdentifier)\""
    private static let developerIDMarkers =
      " and certificate 1[field.1.2.840.113635.100.6.2.6]"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
    private static let teamPrefix = " and certificate leaf[subject.OU] = \""

    /// A Developer ID build of the app: a Developer ID Application
    /// certificate (TN3127: the Developer ID CA intermediate and the leaf's
    /// Developer ID Application marker) of the given team, the same form the
    /// decoder and the Recovery template are held to. The team OU alone also
    /// matches the team's Apple Development and distribution certificates.
    public static func developerIDRequirement(team: String) -> String {
      anchoredIdentifier + developerIDMarkers + teamPrefix + team + "\""
    }

    /// An ad hoc build is identified by its exact code hash: an ad hoc
    /// identifier alone proves nothing.
    public static func adHocRequirement(codeHash: String) -> String {
      "identifier \"\(InstallerProductIdentity.appIdentifier)\" and cdhash H\"\(codeHash)\""
    }

    /// What earlier release builds wrote into their launchd job: any
    /// Apple-issued certificate of the team.
    static func legacyTeamRequirement(team: String) -> String {
      anchoredIdentifier + teamPrefix + team + "\""
    }

    /// The requirement the helper enforces for the one its launchd job
    /// configures, or nil when the configured text is none of the accepted
    /// forms. A job an earlier release installed names only the team; the
    /// helper holds such a client to the Developer ID form of that team, so
    /// a newer helper under an older job never accepts less than a new job
    /// would.
    public static func enforced(for configured: String) -> String? {
      if configured == denyAll { return configured }
      let identifier = NSRegularExpression.escapedPattern(
        for: InstallerProductIdentity.appIdentifier)
      let adHoc =
        "\\Aidentifier \"\(identifier)\" and cdhash H\"[0-9a-f]{40}\"\\z"
      if configured.range(of: adHoc, options: .regularExpression) != nil { return configured }
      return teamIdentifier(in: configured).map(developerIDRequirement(team:))
    }

    /// The team of a Developer ID client requirement, in the current form or
    /// the one earlier release builds wrote; nil for anything else.
    static func teamIdentifier(in configured: String) -> String? {
      for prefix in [
        anchoredIdentifier + developerIDMarkers + teamPrefix, anchoredIdentifier + teamPrefix,
      ] {
        guard configured.hasPrefix(prefix), configured.hasSuffix("\"") else { continue }
        let team = String(configured.dropFirst(prefix.count).dropLast())
        if team.range(of: "\\A[A-Z0-9]{10}\\z", options: .regularExpression) != nil {
          return team
        }
      }
      return nil
    }
  }
#endif
