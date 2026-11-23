import Foundation

/// Product identity from Packaging/identity.conf, compiled in by the
/// AuroraInstallerIdentityPlugin.
public enum InstallerProductIdentity {
  public static let appName = InstallerBuildConfiguration.appName
  public static let recoveryAppBundleName = appName + ".app"
  public static let installedRecoveryTemplateDirectory =
    "/Library/PrivilegedHelperTools/" + helperIdentifier + ".RecoveryTemplate"
  /// The name the app had before the rename; package-installed copies may
  /// still carry it.
  public static let legacyAppName = InstallerBuildConfiguration.legacyAppName
  public static let appIdentifier = InstallerBuildConfiguration.appIdentifier
  public static let helperIdentifier = InstallerBuildConfiguration.helperIdentifier
  public static let helperMachServiceName = helperIdentifier
  public static let helperDaemonPlistName = helperIdentifier + ".plist"
  /// Where the helper's system LaunchDaemon job file lives.
  public static let systemLaunchDaemonDirectory = "/Library/LaunchDaemons"
  /// The absolute path of the helper's system LaunchDaemon plist. Its
  /// presence is the app's synchronous registration signal for the helper.
  public static let systemLaunchDaemonPath =
    systemLaunchDaemonDirectory + "/" + helperDaemonPlistName
  public static let helperWorkingDirectory =
    "/var/db/" + appIdentifier
  /// Earlier packages installed launchd jobs that set this exact name, and
  /// the helper such a job launches must still find it, so it stays as is.
  public static let clientRequirementEnvironmentVariable =
    "OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"
  /// Set only in the launchd job linked into the helper for SMJobBless, so a
  /// helper can tell an SMJobBless install from a package install: both put
  /// the same helper at the same path in /Library/PrivilegedHelperTools.
  public static let helperInstallKindEnvironmentVariable = "AURORA_HELPER_INSTALLED_BY"
  public static let smJobBlessInstallKind = "SMJobBless"
}
