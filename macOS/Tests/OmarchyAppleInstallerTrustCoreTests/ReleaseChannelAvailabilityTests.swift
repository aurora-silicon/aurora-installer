#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class ReleaseChannelAvailabilityTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let thisMac = "apple,j314s"

    // MARK: Classification

    func testAVerifiedCatalogWithoutModelsIsNoRelease() {
      XCTAssertEqual(
        ReleaseChannelAvailability(admittedDeviceIdentifiers: [], deviceIdentifier: thisMac),
        .noRelease)
    }

    func testAVerifiedCatalogWithoutThisMacIsModelUnavailable() {
      XCTAssertEqual(
        ReleaseChannelAvailability(
          admittedDeviceIdentifiers: ["apple,j274"], deviceIdentifier: thisMac),
        .modelUnavailable(supportedDeviceIdentifiers: ["apple,j274"]))
    }

    func testAVerifiedCatalogWithThisMacIsAvailable() {
      XCTAssertEqual(
        ReleaseChannelAvailability(
          admittedDeviceIdentifiers: ["apple,j274", thisMac], deviceIdentifier: thisMac),
        .available)
    }

    func testTransportFailuresAreNetworkAndEverythingElseIsVerification() {
      let network: [any Error] = [
        URLError(.notConnectedToInternet),
        InstallerReleaseConfigurationError.unexpectedHTTPStatus(404),
        InstallerReleaseConfigurationError.unexpectedHTTPStatus(503),
      ]
      for error in network {
        XCTAssertEqual(ReleaseChannelCheckFailure(error), .network, "\(error)")
      }
      let verification: [any Error] = [
        InstallerReleaseConfigurationError.invalidCatalogEnvelope,
        InstallerReleaseConfigurationError.invalidCatalogSignature,
        InstallerReleaseConfigurationError.oversizedDocument("catalog"),
        InstallerReleaseConfigurationError.invalidDescriptor,
        InstallerReleaseConfigurationError.releaseResourcesUnavailable,
        SupportCatalogError.invalidSignature,
        SupportCatalogError.expired,
        SupportCatalogError.notYetValid,
        SupportCatalogSequenceError.rollback(stored: 9, candidate: 8),
        SupportCatalogSequenceError.sequenceReuse(9),
        AcceptedCatalogIdentityStoreError.unsafeState,
      ]
      for error in verification {
        XCTAssertEqual(ReleaseChannelCheckFailure(error), .verification, "\(error)")
      }
    }

    func testOnlyChannelsWithNothingForThisMacAreUnselectable() {
      XCTAssertTrue(ReleaseChannelAvailability.available.isSelectable)
      XCTAssertTrue(ReleaseChannelAvailability.checkFailed(.network).isSelectable)
      XCTAssertTrue(ReleaseChannelAvailability.checkFailed(.verification).isSelectable)
      XCTAssertFalse(ReleaseChannelAvailability.noRelease.isSelectable)
      XCTAssertFalse(
        ReleaseChannelAvailability.modelUnavailable(supportedDeviceIdentifiers: []).isSelectable)
    }

    // MARK: Probing each channel's signed catalog

    func testEachChannelReportsItsOwnStateFromItsSignedCatalog() async throws {
      let configuration = try configuration()
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .stable): try envelope(emptyCatalog(sequence: 5)),
        configuration.catalogURL(for: .rc): try envelope(modelCatalog(devices: ["apple,j274"])),
        configuration.catalogURL(for: .edge): try envelope(modelCatalog(devices: [thisMac])),
      ])

      let stable = await availability(coordinator, configuration, .stable)
      let rc = await availability(coordinator, configuration, .rc)
      let edge = await availability(coordinator, configuration, .edge)

      XCTAssertEqual(stable, .noRelease)
      XCTAssertEqual(rc, .modelUnavailable(supportedDeviceIdentifiers: ["apple,j274"]))
      XCTAssertEqual(edge, .available)
    }

    func testAnEmptyCatalogWithABadSignatureIsNeverReadAsNoRelease() async throws {
      let configuration = try configuration()
      let payload = emptyCatalog(sequence: 5)
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .stable): envelope(
          payload: payload, signature: Data(repeating: 1, count: 64))
      ])

      let stable = await availability(coordinator, configuration, .stable)

      XCTAssertEqual(stable, .checkFailed(.verification))
    }

    func testAMissingChannelObjectIsANetworkFailureNotNoRelease() async throws {
      let configuration = try configuration()
      let coordinator = coordinator(serving: [:])

      let rc = await availability(coordinator, configuration, .rc)

      XCTAssertEqual(rc, .checkFailed(.network))
    }

    func testAnEmptyCatalogBelowTheRollbackFloorIsAVerificationFailure() async throws {
      let configuration = try configuration()
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .stable): try envelope(emptyCatalog(sequence: 5))
      ])

      let stable = await coordinator.availability(
        configuration: configuration, channel: .stable, deviceIdentifier: thisMac,
        validationTime: now,
        previouslyAcceptedCatalog: try AcceptedCatalogIdentity(
          sequence: 6, payloadDigest: "sha256:" + String(repeating: "a", count: 64)))

      XCTAssertEqual(stable, .checkFailed(.verification))
    }

    // MARK: Preparation on a channel with no Mac release

    func testPreparingFromAnEmptyCatalogSaysTheChannelHasNoMacRelease() async throws {
      let payload = emptyCatalog(sequence: 5)
      let request = InstallerAssetPreparationRequest(
        host: host(),
        catalogPayload: payload,
        catalogSignature: try key.signature(for: payload),
        trustRoot: try trustRoot(),
        validationTime: now,
        stagingDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("omarchy-no-release-\(UUID().uuidString.lowercased())")
      )

      do {
        _ = try await InstallerAssetPreparer().prepare(request)
        XCTFail("an empty catalog must not prepare anything")
      } catch {
        XCTAssertEqual(error as? InstallerAssetPreparationError, .noMacRelease)
      }
    }

    func testPreparingFromACatalogWithoutThisMacStillNamesTheSupportedMacs() async throws {
      let payload = modelCatalog(devices: ["apple,j274"])
      let request = InstallerAssetPreparationRequest(
        host: host(),
        catalogPayload: payload,
        catalogSignature: try key.signature(for: payload),
        trustRoot: try trustRoot(),
        validationTime: now,
        stagingDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("omarchy-not-listed-\(UUID().uuidString.lowercased())")
      )

      do {
        _ = try await InstallerAssetPreparer().prepare(request)
        XCTFail("a catalog without this Mac must not prepare anything")
      } catch {
        XCTAssertEqual(
          error as? InstallerAssetPreparationError,
          .notInCatalog(
            deviceIdentifier: thisMac, modelIdentifier: "MacBookPro18,3",
            supportedDeviceIdentifiers: ["apple,j274"]))
      }
    }

    // MARK: Fixtures

    private func availability(
      _ coordinator: InstallerReleaseAssetCoordinator,
      _ configuration: InstallerReleaseConfiguration,
      _ channel: ReleaseChannel
    ) async -> ReleaseChannelAvailability {
      await coordinator.availability(
        configuration: configuration, channel: channel, deviceIdentifier: thisMac,
        validationTime: now, previouslyAcceptedCatalog: nil)
    }

    private func coordinator(serving values: [URL: Data]) -> InstallerReleaseAssetCoordinator {
      InstallerReleaseAssetCoordinator(
        catalogFetcher: InstallerReleaseCatalogFetcher(
          downloader: ChannelFixtureDownloader(values: values)),
        assetPreparer: InstallerAssetPreparer())
    }

    /// What `publish-channels empty-catalog` writes.
    private func emptyCatalog(sequence: Int) -> Data {
      Data(
        """
        {"schemaVersion":4,"sequence":\(sequence),"issuedAt":"2026-09-01T00:00:00Z","models":[]}
        """.utf8)
    }

    private func modelCatalog(devices: [String]) -> Data {
      let models = devices.map { device in
        """
        {"deviceIdentifier":"\(device)","status":"enabled","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","engineDigest":"sha256:\(String(repeating: "1", count: 64))","metadataDigest":"sha256:\(String(repeating: "2", count: 64))","payloadDigest":"sha256:\(String(repeating: "3", count: 64))","evidenceRevision":"evidence-s4"}
        """
      }
      return Data(
        """
        {"schemaVersion":1,"sequence":7,"issuedAt":"2026-09-01T00:00:00Z","expiresAt":"2027-09-01T00:00:00Z","models":[\(models.joined(separator: ","))]}
        """.utf8)
    }

    private func envelope(_ payload: Data) throws -> Data {
      envelope(payload: payload, signature: try key.signature(for: payload))
    }

    private func envelope(payload: Data, signature: Data) -> Data {
      Data(
        """
        {"schema_version":1,"catalog":"\(payload.base64EncodedString())","signature":"\(signature.base64EncodedString())"}
        """.utf8)
    }

    private func trustRoot() throws -> AppOwnedTrustRoot {
      let publicKey = key.publicKey.rawRepresentation
      return try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: "sha256:"
          + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined())
    }

    private func configuration() throws -> InstallerReleaseConfiguration {
      InstallerReleaseConfiguration(
        channels: ReleaseChannelEndpoints(
          endpoints: Dictionary(
            uniqueKeysWithValues: ReleaseChannel.allCases.map {
              let url = "https://releases.example.com/channels/\($0.rawValue)/catalog.signed.json"
              return ($0, URL(string: url)!)
            }))!,
        defaultChannel: .edge,
        trustRoot: try trustRoot(),
        helperMachServiceName: InstallerProductIdentity.helperMachServiceName,
        helperCodeSigningRequirement: "identifier \"\(InstallerProductIdentity.helperIdentifier)\""
      )
    }

    private func host() -> AppleSiliconHostInspection {
      AppleSiliconHostInspection(
        identity: AppleMacIdentity(
          model: "MacBookPro18,3", chip: "Apple M1 Pro", deviceIdentifier: thisMac),
        eligibility: .requiresSignedCatalog,
        macOSVersion: "Version 15.6",
        powerSource: .ac,
        fileVaultEnabled: true,
        storage: APFSStorageInspection(
          containerIdentifier: "disk3", physicalStoreIdentifier: "disk0s2", isInternal: true,
          containerSizeBytes: 1_000, containerFreeBytes: 500, minimumPreferredSizeBytes: 600)
      )
    }
  }

  private struct ChannelFixtureDownloader: ReleaseDocumentDownloading {
    let values: [URL: Data]

    func download(from url: URL, maximumBytes: Int, role: String) async throws -> Data {
      guard let value = values[url] else {
        throw InstallerReleaseConfigurationError.unexpectedHTTPStatus(404)
      }
      return value
    }
  }
#endif
