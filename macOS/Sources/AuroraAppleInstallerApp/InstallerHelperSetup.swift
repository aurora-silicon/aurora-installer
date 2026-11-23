import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import Foundation

/// The app's one way to check and install its privileged helper, shared by
/// the install flow and the removal sheet. It keeps no credential.
enum InstallerHelperSetup {
  /// Whether this build declares its helper and so can start it. Builds
  /// signed ad hoc leave it out and rely on the installer package instead.
  static let canInstall = SessionHelperLauncher.isDeclared()

  private static let provisioner = InstallerHelperProvisioner(
    probe: SystemInstallerHelperProbe(submitter: submitter),
    blesser: canInstall
      ? SessionHelperLauncher(helperRequirement: helperRequirement)
      : UnavailableInstallerHelperBlesser(),
    credentialValidator: OpenDirectoryMachineOwnerCredentialValidator(),
    administrators: OpenDirectoryAdministratorMembership(),
    bundledHelperVersion: InstallerHelperProvisioner.bundledHelperVersion(),
    housekeeping: SystemInstallerHelperHousekeeping(submitter: submitter)
  )

  static var display: HelperDisplay {
    HelperDisplay(status: provisioner.registrationStatus, canInstall: canInstall)
  }

  /// Asks the helper itself, so a switched-off helper shows as `.disabled`.
  static func probeDisplay() async -> HelperDisplay {
    HelperDisplay(status: await provisioner.probeStatus(), canInstall: canInstall)
  }

  @Sendable static func configuration() throws -> InstallerReleaseConfiguration {
    try InstallerReleaseConfigurationLocator().loadFromMainBundle()
  }

  /// The signature the helper's root-owned copy must carry: the one the app
  /// holds it to over XPC.
  @Sendable static func helperRequirement() throws -> String {
    try configuration().helperCodeSigningRequirement
  }

  /// A connection to the helper from the bundled release configuration.
  @Sendable static func submitter() throws -> AuthenticatedEngineXPCSubmitter {
    let configuration = try Self.configuration()
    return try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement
    )
  }

  /// Makes the helper ready for the action just authorized. Throws
  /// `EngineXPCSubmissionError.machineOwnerCredentialsRejected` for wrong
  /// credentials and `InstallerHelperSetupError` for everything else.
  static func ensure(
    _ authorization: MachineOwnerAuthorization, reenablingSwitchedOff: Bool = false
  ) async throws {
    switch await provisioner.ensureCurrent(
      authorization, reenablingSwitchedOff: reenablingSwitchedOff)
    {
    case .alreadyCurrent, .installedSilently, .installedWithDialog:
      return
    case .credentialsRejected:
      throw EngineXPCSubmissionError.machineOwnerCredentialsRejected
    case .notAdministrator:
      throw InstallerHelperSetupError.notAdministrator
    case .cancelled:
      throw InstallerHelperSetupError.cancelled
    case .disabled:
      throw InstallerHelperSetupError.switchedOff
    case .busy:
      throw InstallerHelperSetupError.busy
    case .unavailable:
      throw InstallerHelperSetupError.unavailable
    case .failed(let message):
      throw InstallerHelperSetupError.failed(message)
    }
  }
}
