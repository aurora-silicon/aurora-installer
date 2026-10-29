#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class RestoreImageHelperTests: XCTestCase {
    private let team = "ABCDE12345"

    func testTheDecoderLivesInTheAppsHelpersUnderItsOwnIdentifier() {
      XCTAssertEqual(
        RestoreImageHelper.identifier, InstallerBuildConfiguration.restoreImageIdentifier)
      XCTAssertTrue(
        RestoreImageHelper.identifier.hasPrefix(InstallerProductIdentity.appIdentifier + "."))
      XCTAssertEqual(
        RestoreImageHelper.bundledURL(in: URL(fileURLWithPath: "/Applications/X.app")).path,
        "/Applications/X.app/Contents/Helpers/omarchy-restore-image")
    }

    func testADeveloperIDClientImpliesTheSameTeamForTheDecoder() {
      let client =
        "anchor apple generic and identifier \"\(InstallerProductIdentity.appIdentifier)\""
        + " and certificate leaf[subject.OU] = \"\(team)\""
      XCTAssertEqual(
        RestoreImageHelper.requirement(environment: [
          InstallerProductIdentity.clientRequirementEnvironmentVariable: client
        ]),
        "anchor apple generic and identifier \"\(RestoreImageHelper.identifier)\""
          + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
          + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
          + " and certificate leaf[subject.OU] = \"\(team)\"")
    }

    func testAnyAppleCertificateOfTheTeamIsNotADeveloperIDPin() {
      // TN3127: the team OU alone also matches the team's Apple Development
      // and distribution certificates; release decoders need Developer ID.
      for pinned in [
        "anchor apple generic and identifier \"\(RestoreImageHelper.identifier)\""
          + " and certificate leaf[subject.OU] = \"\(team)\"",
        "anchor apple generic and identifier \"\(RestoreImageHelper.identifier)\""
          + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
          + " and certificate leaf[subject.OU] = \"\(team)\"",
      ] {
        XCTAssertNil(
          RestoreImageHelper.requirement(environment: [
            RestoreImageHelper.requirementEnvironmentVariable: pinned
          ]), pinned)
      }
      let developerID = RestoreImageHelper.developerIDRequirement(team: team)
      XCTAssertEqual(
        RestoreImageHelper.requirement(environment: [
          RestoreImageHelper.requirementEnvironmentVariable: developerID
        ]), developerID)
    }

    func testAnAdHocClientHasNoDecoderIdentityWithoutAPin() {
      for client in [
        "identifier \"\(InstallerProductIdentity.appIdentifier)\"",
        "identifier \"\(InstallerProductIdentity.appIdentifier)\" and cdhash H\""
          + String(repeating: "a", count: 40) + "\"",
        "anchor apple generic and identifier \"other.app\" and certificate leaf[subject.OU] = \"\(team)\"",
      ] {
        XCTAssertNil(
          RestoreImageHelper.requirement(environment: [
            InstallerProductIdentity.clientRequirementEnvironmentVariable: client
          ]), client)
      }
      XCTAssertNil(RestoreImageHelper.requirement(environment: [:]))
    }

    func testAPinnedRequirementMustBeOneOfTheTwoDecoderForms() {
      let pinned = RestoreImageHelper.adHocRequirement(codeHash: String(repeating: "c", count: 40))
      XCTAssertEqual(
        RestoreImageHelper.requirement(environment: [
          RestoreImageHelper.requirementEnvironmentVariable: pinned
        ]), pinned)
      for rejected in [
        "identifier \"\(RestoreImageHelper.identifier)\"",
        "identifier \"other\" and cdhash H\"" + String(repeating: "c", count: 40) + "\"",
        RestoreImageHelper.developerIDRequirement(team: team) + " or anchor apple",
        "anchor apple generic",
      ] {
        // An invalid pin is never replaced by the client-derived team.
        XCTAssertNil(
          RestoreImageHelper.requirement(environment: [
            RestoreImageHelper.requirementEnvironmentVariable: rejected,
            InstallerProductIdentity.clientRequirementEnvironmentVariable:
              "anchor apple generic and identifier \"\(InstallerProductIdentity.appIdentifier)\""
              + " and certificate leaf[subject.OU] = \"\(team)\"",
          ]), rejected)
      }
    }

    func testCodesignAcceptsOnlyTheExactSignedDecoder() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("restore-image-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }
      let decoder = directory.appendingPathComponent(RestoreImageHelper.fileName)
      // A thin executable, like the decoder: a cdhash names one architecture.
      try run("/usr/bin/lipo", ["/usr/bin/true", "-thin", "arm64e", "-output", decoder.path])
      let unsigned = directory.appendingPathComponent("unsigned")
      try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: unsigned)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unsigned.path)

      try codesign([
        "--force", "--sign", "-", "--identifier", RestoreImageHelper.identifier, decoder.path,
      ])
      let hash = try codeHash(decoder)
      try RestoreImageHelper.verify(
        decoder, requirement: RestoreImageHelper.adHocRequirement(codeHash: hash))

      let other = String(repeating: "0", count: hash.count)
      for (file, requirement) in [
        (decoder, RestoreImageHelper.adHocRequirement(codeHash: other)),
        (decoder, RestoreImageHelper.developerIDRequirement(team: team)),
        (unsigned, RestoreImageHelper.adHocRequirement(codeHash: hash)),
      ] {
        XCTAssertThrowsError(try RestoreImageHelper.verify(file, requirement: requirement)) {
          XCTAssertEqual($0 as? RestoreImageHelperError, .signatureRejected)
        }
      }

      // The right code under another identifier is not the decoder.
      try codesign(["--force", "--sign", "-", "--identifier", "org.example.other", decoder.path])
      XCTAssertThrowsError(
        try RestoreImageHelper.verify(
          decoder, requirement: RestoreImageHelper.adHocRequirement(codeHash: try codeHash(decoder))
        ))

      let link = directory.appendingPathComponent("link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoder)
      XCTAssertThrowsError(try RestoreImageHelper.verify(link, requirement: "x")) {
        XCTAssertEqual($0 as? RestoreImageHelperError, .unsafeFile)
      }
      XCTAssertThrowsError(
        try RestoreImageHelper.verify(directory.appendingPathComponent("missing"), requirement: "x")
      ) {
        XCTAssertEqual($0 as? RestoreImageHelperError, .unavailable)
      }
    }

    private func codesign(_ arguments: [String]) throws {
      try run("/usr/bin/codesign", arguments)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
    }

    private func codeHash(_ file: URL) throws -> String {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      process.arguments = ["--display", "--verbose=4", file.path]
      process.standardError = output
      process.standardOutput = output
      try process.run()
      let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
      return String(line.dropFirst("CDHash=".count))
    }
  }
#endif
