#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class HelperClientRequirementTests: XCTestCase {
    private let team = "ABCDE12345"
    private let app = InstallerProductIdentity.appIdentifier

    func testAReleaseClientIsADeveloperIDApplicationOfTheTeam() {
      let requirement = HelperClientRequirement.developerIDRequirement(team: team)
      XCTAssertEqual(
        requirement,
        "anchor apple generic and identifier \"\(app)\""
          + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
          + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
          + " and certificate leaf[subject.OU] = \"\(team)\"")
      XCTAssertEqual(HelperClientRequirement.enforced(for: requirement), requirement)
      XCTAssertEqual(HelperClientRequirement.teamIdentifier(in: requirement), team)
      XCTAssertTrue(EngineCodeSigningRequirement.isValid(requirement))
      // The decoder is held to the same form, under its own identifier.
      XCTAssertEqual(
        RestoreImageHelper.developerIDRequirement(team: team),
        requirement.replacingOccurrences(
          of: "identifier \"\(app)\"", with: "identifier \"\(RestoreImageHelper.identifier)\""))
    }

    func testAJobFromAnEarlierReleaseIsHeldToTheDeveloperIDForm() {
      // TN3127: the team OU alone also matches the team's Apple Development
      // and distribution certificates.
      let earlier =
        "anchor apple generic and identifier \"\(app)\""
        + " and certificate leaf[subject.OU] = \"\(team)\""
      XCTAssertEqual(HelperClientRequirement.legacyTeamRequirement(team: team), earlier)
      XCTAssertEqual(
        HelperClientRequirement.enforced(for: earlier),
        HelperClientRequirement.developerIDRequirement(team: team))
      XCTAssertEqual(HelperClientRequirement.teamIdentifier(in: earlier), team)
    }

    func testExactCodeHashAndDenyAllFormsStayAsConfigured() {
      for hash in [String(repeating: "a", count: 40), String(repeating: "0", count: 40)] {
        let pinned = HelperClientRequirement.adHocRequirement(codeHash: hash)
        XCTAssertEqual(pinned, "identifier \"\(app)\" and cdhash H\"\(hash)\"")
        XCTAssertEqual(HelperClientRequirement.enforced(for: pinned), pinned)
        XCTAssertNil(HelperClientRequirement.teamIdentifier(in: pinned))
        XCTAssertTrue(EngineCodeSigningRequirement.isValid(pinned))
      }
      XCTAssertEqual(HelperClientRequirement.enforced(for: "never"), "never")
      XCTAssertTrue(EngineCodeSigningRequirement.isValid("never"))
    }

    func testAnyOtherRequirementIsRefusedEvenWhenItCompiles() {
      let developerID = HelperClientRequirement.developerIDRequirement(team: team)
      let hash = String(repeating: "a", count: 40)
      for refused in [
        "",
        "always",
        "anchor apple",
        "anchor apple generic",
        "anchor trusted",
        "identifier \"\(app)\"",
        "anchor apple generic and identifier \"\(app)\"",
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
        // Another identifier, in each accepted form.
        developerID.replacingOccurrences(of: app, with: "other.app"),
        "anchor apple generic and identifier \"other.app\""
          + " and certificate leaf[subject.OU] = \"\(team)\"",
        "identifier \"other.app\" and cdhash H\"\(hash)\"",
        // codesign reports a 20-byte CDHash; a longer pin is not one it wrote.
        "identifier \"\(app)\" and cdhash H\"" + String(repeating: "0", count: 64) + "\"",
        // One Developer ID marker alone.
        "anchor apple generic and identifier \"\(app)\""
          + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
          + " and certificate leaf[subject.OU] = \"\(team)\"",
        "anchor apple generic and identifier \"\(app)\""
          + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
          + " and certificate leaf[subject.OU] = \"\(team)\"",
        // A team that is not ten upper-case letters or digits.
        developerID.replacingOccurrences(of: team, with: "abcde12345"),
        developerID.replacingOccurrences(of: team, with: "ABCDE1234"),
        developerID.replacingOccurrences(of: team, with: "ABCDE12345\" or \"ABCDE12345"),
        // Anything appended or prepended.
        developerID + " or anchor apple",
        developerID + " or always",
        "always or " + developerID,
        " " + developerID,
        developerID + "\n",
        "identifier \"\(app)\" and cdhash H\"\(hash)\" or always",
        "identifier \"\(app)\" and cdhash H\"\(String(repeating: "a", count: 39))\"",
        "identifier \"\(app)\" and cdhash H\"\(hash.uppercased())\"",
        "cdhash H\"\(hash)\"",
        "never or always",
      ] {
        XCTAssertNil(HelperClientRequirement.enforced(for: refused), refused)
      }
    }

    func testTheListenerEnforcesOnlyAnAcceptedForm() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("helper-client-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }
      let server = ClosedEngineHelperServer(
        workingDirectory: directory, executor: UnusedHandoffExecutor())
      let developerID = HelperClientRequirement.developerIDRequirement(team: team)
      for (configured, enforced) in [
        (developerID, developerID),
        (HelperClientRequirement.legacyTeamRequirement(team: team), developerID),
        ("never", "never"),
      ] {
        let delegate = try AuthenticatedEngineXPCListenerDelegate(
          clientCodeSigningRequirement: configured, server: server, helperVersion: "1")
        XCTAssertEqual(delegate.enforcedClientRequirement, enforced)
      }
      for refused in [
        "anchor apple generic", "identifier \"\(app)\"", developerID + " or always", "",
      ] {
        XCTAssertThrowsError(
          try AuthenticatedEngineXPCListenerDelegate(
            clientCodeSigningRequirement: refused, server: server, helperVersion: "1"), refused
        ) {
          XCTAssertEqual($0 as? ClosedEngineHelperError, .invalidClientRequirement)
        }
      }
    }
  }

  private struct UnusedHandoffExecutor: ImportedEngineHandoffExecuting {
    func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      throw ClosedEngineHelperError.invalidOperation
    }
  }
#endif
