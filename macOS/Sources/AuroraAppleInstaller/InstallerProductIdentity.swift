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
  /// Where the helper's system LaunchDaemon job file lives. Only the
  /// installer package and earlier versions of the app put one there.
  public static let systemLaunchDaemonDirectory = "/Library/LaunchDaemons"
  /// The absolute path of the helper's system LaunchDaemon plist, the job
  /// launchd loads at every startup and macOS lists in Login Items.
  public static let systemLaunchDaemonPath =
    systemLaunchDaemonDirectory + "/" + helperDaemonPlistName
  /// The root-owned copy of the helper that launchd runs.
  public static let installedHelperPath = "/Library/PrivilegedHelperTools/" + helperIdentifier
  /// Where the app copies the helper and checks the copy's signature before
  /// starting it; the started helper moves itself to `installedHelperPath`.
  public static let stagedHelperPath = installedHelperPath + ".new"
  /// The helper's launchd job when the app starts it: outside the
  /// LaunchDaemons folders, so launchd never loads it at startup and macOS
  /// records no background item.
  public static let sessionJobDirectory = "/private/var/run/" + helperIdentifier
  public static let sessionJobPath = sessionJobDirectory + "/" + helperDaemonPlistName
  public static let helperWorkingDirectory =
    "/var/db/" + appIdentifier
  /// Earlier packages installed launchd jobs that set this exact name, and
  /// the helper such a job launches must still find it, so it stays as is.
  public static let clientRequirementEnvironmentVariable =
    "OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"
}
