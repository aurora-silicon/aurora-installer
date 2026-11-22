#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

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
        InstallerReleaseConfigurationError.catalogUnreachable(
          URLError.notConnectedToInternet.rawValue),
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
      XCTAssertFalse(ReleaseChannelAvailability.notPublished.isSelectable)
      XCTAssertFalse(
        ReleaseChannelAvailability.modelUnavailable(supportedDeviceIdentifiers: []).isSelectable)
    }

    // MARK: Probing each channel's signed catalog

    func testEdgeIsUnavailableUntilAQualifiedAlphaIsPublished() async throws {
      let configuration = try configuration()
      let missing = await availability(coordinator(serving: [:]), configuration, .edge)
      XCTAssertEqual(missing, .notPublished)
      let undeclared = try legacyDevelopmentCatalog()
      let legacy = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(undeclared)
      ])
      let state = await availability(legacy, configuration, .edge)
      XCTAssertEqual(state, .notPublished)
    }

    func testSignedEmptyEdgeIsClearlyEmptyWithoutInventingQualification() async throws {
      let configuration = try configuration()
      let value = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(
          emptyCatalog(sequence: 5, channel: .edge))
      ])
      let state = await availability(value, configuration, .edge)
      XCTAssertEqual(state, .noRelease)
    }

    func testAnEmptyEdgeCatalogMustDeclareEdge() async throws {
      // An empty catalog signed for no channel says nothing about Edge, and
      // one signed for another channel was served in the wrong place: neither
      // reads as "no release yet". Only the undeclared one is "not published";
      // another channel's is a verification failure, as on every channel.
      let configuration = try configuration()
      let others: [ReleaseChannel?] = [nil, .stable, .rc, .testing]
      for declared in others {
        let value = coordinator(serving: [
          configuration.catalogURL(for: .edge): try envelope(
            emptyCatalog(sequence: 5, channel: declared))
        ])
        let state = await availability(value, configuration, .edge)
        XCTAssertEqual(
          state, declared == nil ? .notPublished : .checkFailed(.verification),
          declared?.rawValue ?? "undeclared")
      }
    }

    func testACatalogSignedForAnotherChannelIsAVerificationFailureOnEdge() async throws {
      // Stable, RC or Testing bytes served at the Edge address are a mis-served
      // or replayed catalog, not an Edge that isn't published yet.
      let configuration = try configuration()
      for declared in [ReleaseChannel.stable, .rc, .testing] {
        for payload in [
          modelCatalog(devices: [thisMac], channel: declared),
          emptyCatalog(sequence: 5, channel: declared),
        ] {
          XCTAssertThrowsError(
            try ReleaseCatalogChannelPolicy.validate(payload: payload, channel: .edge)
          ) {
            XCTAssertEqual(
              $0 as? InstallerReleaseConfigurationError, .invalidCatalogChannel,
              declared.rawValue)
          }
          let value = coordinator(serving: [
            configuration.catalogURL(for: .edge): try envelope(payload)
          ])
          let state = await availability(value, configuration, .edge)
          XCTAssertEqual(state, .checkFailed(.verification), declared.rawValue)
        }
      }
      for payload in [try legacyDevelopmentCatalog(), emptyCatalog(sequence: 5, channel: nil)] {
        XCTAssertThrowsError(
          try ReleaseCatalogChannelPolicy.validate(payload: payload, channel: .edge)
        ) {
          XCTAssertEqual($0 as? InstallerReleaseConfigurationError, .edgeAlphaUnavailable)
        }
      }
    }

    // MARK: Every channel's catalog declares that channel

    func testStableAndRCRefuseACatalogThatDeclaresNoChannel() async throws {
      // The signature covers the channel only when the catalog declares it.
      // Without it the same signed bytes verify on every channel.
      let configuration = try configuration()
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: [thisMac])) as? [String: Any])
      object["channel"] = nil
      let undeclared = try JSONSerialization.data(withJSONObject: object)
      for channel in [ReleaseChannel.stable, .rc] {
        for payload in [undeclared, emptyCatalog(sequence: 5, channel: nil)] {
          let value = coordinator(serving: [
            configuration.catalogURL(for: channel): try envelope(payload)
          ])
          let state = await availability(value, configuration, channel)
          XCTAssertEqual(state, .checkFailed(.verification), channel.rawValue)
        }
      }
    }

    func testACatalogSignedForOneChannelIsRefusedOnEveryOther() async throws {
      let configuration = try configuration()
      for declared in ReleaseChannel.allCases {
        for payload in [
          modelCatalog(devices: [thisMac], channel: declared),
          emptyCatalog(sequence: 5, channel: declared),
        ] {
          for channel in [ReleaseChannel.stable, .rc, .testing] {
            let value = coordinator(serving: [
              configuration.catalogURL(for: channel): try envelope(payload)
            ])
            let state = await availability(value, configuration, channel)
            let label = "\(declared.rawValue) on \(channel.rawValue)"
            if declared == channel {
              XCTAssertNotEqual(state, .checkFailed(.verification), label)
            } else {
              XCTAssertEqual(state, .checkFailed(.verification), label)
            }
          }
        }
      }
    }

    func testAnUndeclaredLegacyDeliveryIsTestingOnly() async throws {
      // The published development deliveries predate the channel field. They
      // stay readable on Testing and nowhere else.
      let configuration = try configuration()
      let legacy = try legacyDevelopmentCatalog()
      let testing = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(legacy)
      ])
      let accepted = await availability(testing, configuration, .testing)
      XCTAssertEqual(accepted, .available)
      for channel in [ReleaseChannel.stable, .rc] {
        let value = coordinator(serving: [
          configuration.catalogURL(for: channel): try envelope(legacy)
        ])
        let state = await availability(value, configuration, channel)
        XCTAssertEqual(state, .checkFailed(.verification), channel.rawValue)
      }
      let edge = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(legacy)
      ])
      let unavailable = await availability(edge, configuration, .edge)
      XCTAssertEqual(unavailable, .notPublished)
    }

    func testAnUndeclaredEmptyCatalogIsNotALegacyTestingDelivery() async throws {
      // The Testing exception is for a delivery that lists its models. An
      // empty catalog signed for no channel is not one.
      let configuration = try configuration()
      let value = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(
          emptyCatalog(sequence: 5, channel: nil))
      ])
      let undeclared = await availability(value, configuration, .testing)
      XCTAssertEqual(undeclared, .checkFailed(.verification))
      let declared = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(
          emptyCatalog(sequence: 5, channel: .testing))
      ])
      let empty = await availability(declared, configuration, .testing)
      XCTAssertEqual(empty, .noRelease)
    }

    func testAQualifiedSignedEdgeAlphaIsSupportedButCannotBeReadAsTesting() async throws {
      let configuration = try configuration()
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: [thisMac], channel: .edge))
          as? [String: Any])
      let source = { (repository: String) in
        [
          "repository": repository, "branch": "aurora-edge",
          "revision": String(repeating: "a", count: 40), "tree": String(repeating: "b", count: 40),
        ]
      }
      object["edgeQualification"] =
        [
          "schemaVersion": 1, "releaseKind": "alpha", "status": "passed", "imageRunID": 41,
          "payloadDigest": "sha256:" + String(repeating: "3", count: 64),
          "evidenceDigest": "sha256:" + String(repeating: "4", count: 64),
          "linux": source("aurora-silicon/linux"), "mesa": source("aurora-silicon/mesa"),
        ] as [String: Any]
      let payload = try JSONSerialization.data(withJSONObject: object)
      let value = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(payload),
        configuration.catalogURL(for: .testing): try envelope(payload),
      ])
      let edge = await availability(value, configuration, .edge)
      let testing = await availability(value, configuration, .testing)
      XCTAssertEqual(edge, .available)
      XCTAssertEqual(testing, .checkFailed(.verification))
      var proof = try XCTUnwrap(object["edgeQualification"] as? [String: Any])
      var mesa = source("aurora-silicon/mesa")
      mesa["branch"] = "main"
      proof["mesa"] = mesa
      object["edgeQualification"] = proof
      let invalid = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(
          JSONSerialization.data(withJSONObject: object))
      ])
      let rejected = await availability(invalid, configuration, .edge)
      XCTAssertEqual(rejected, .checkFailed(.verification))
    }

    // MARK: Edge's per-device proof, for the default channel

    func testOnlyPerDeviceEvidenceMakesEdgeTheDefaultForAMac() async throws {
      // Listing a model makes Edge selectable on it; only being listed as
      // family-qualified makes Edge its default.
      let configuration = try configuration()
      let catalog = try qualifiedEdgeCatalog(
        devices: [thisMac, "apple,j274"],
        proof: ["devices": [thisMac: ["evidenceDigest": digest("5")]]])
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(catalog)
      ])

      let proven = await edgeCheck(coordinator, configuration, thisMac)
      let listed = await edgeCheck(coordinator, configuration, "apple,j274")

      XCTAssertEqual(
        proven, EdgeCatalogCheck(availability: .available, qualifiesThisMac: true))
      XCTAssertEqual(
        listed, EdgeCatalogCheck(availability: .available, qualifiesThisMac: false))
    }

    func testNeoEvidenceWithoutDevicesProvesOnlyTheNeo() async throws {
      // The alpha.1 and alpha.2 catalogs predate `devices`; their Neo
      // evidence covers the MacBook Neo and no other model.
      let configuration = try configuration()
      let catalog = try qualifiedEdgeCatalog(
        devices: ["apple,j700", thisMac],
        proof: ["neoEvidence": ["checks": ["glCTS": ["status": "passed"]]]])
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(catalog)
      ])

      let neo = await edgeCheck(coordinator, configuration, "apple,j700")
      let other = await edgeCheck(coordinator, configuration, thisMac)

      XCTAssertEqual(neo, EdgeCatalogCheck(availability: .available, qualifiesThisMac: true))
      XCTAssertEqual(other, EdgeCatalogCheck(availability: .available, qualifiesThisMac: false))
    }

    func testMalformedDeviceProofQualifiesNoMac() async throws {
      // A `devices` value that isn't well formed proves nothing, and Neo
      // evidence beside it does not stand in for it.
      let configuration = try configuration()
      let malformed: [Any] = [
        [thisMac],
        "\(thisMac)",
        [thisMac: ["evidenceDigest": "sha256:short"]],
        [thisMac: ["evidenceDigest": digest("5")], "apple,j274": digest("6")] as [String: Any],
        [thisMac: ["evidenceDigest": digest("5")], "J274": ["evidenceDigest": digest("6")]],
        [thisMac: [:] as [String: Any]] as [String: Any],
        NSNull(),
      ]
      for devices in malformed {
        let catalog = try qualifiedEdgeCatalog(
          devices: [thisMac, "apple,j700"],
          proof: ["devices": devices, "neoEvidence": ["checks": [:] as [String: Any]]])
        let coordinator = coordinator(serving: [
          configuration.catalogURL(for: .edge): try envelope(catalog)
        ])
        let mac = await edgeCheck(coordinator, configuration, thisMac)
        let neo = await edgeCheck(coordinator, configuration, "apple,j700")
        XCTAssertEqual(
          mac, EdgeCatalogCheck(availability: .available, qualifiesThisMac: false), "\(devices)")
        XCTAssertEqual(
          neo, EdgeCatalogCheck(availability: .available, qualifiesThisMac: false), "\(devices)")
      }
    }

    func testAnEdgeCatalogWithoutThisMacOrThatFailedCarriesNoProof() async throws {
      let configuration = try configuration()
      let catalog = try qualifiedEdgeCatalog(
        devices: ["apple,j274"],
        proof: ["devices": ["apple,j274": ["evidenceDigest": digest("5")]]])
      let other = coordinator(serving: [
        configuration.catalogURL(for: .edge): try envelope(catalog)
      ])
      let missing = coordinator(serving: [:])

      let unlisted = await edgeCheck(other, configuration, thisMac)
      let unpublished = await edgeCheck(missing, configuration, thisMac)

      XCTAssertEqual(
        unlisted,
        EdgeCatalogCheck(
          availability: .modelUnavailable(supportedDeviceIdentifiers: ["apple,j274"]),
          qualifiesThisMac: false))
      XCTAssertEqual(
        unpublished, EdgeCatalogCheck(availability: .notPublished, qualifiesThisMac: false))
    }

    func testANetworkFailureReadingACatalogSaysSo() async throws {
      // Preparation tells an unreachable release list apart from a failed
      // payload download, so its message can point at the channel menu.
      let configuration = try configuration()
      let fetcher = InstallerReleaseCatalogFetcher(downloader: OfflineDownloader())
      for channel in [ReleaseChannel.edge, .rc] {
        do {
          _ = try await fetcher.fetch(configuration: configuration, channel: channel)
          XCTFail("an offline fetch must fail")
        } catch {
          XCTAssertEqual(
            error as? InstallerReleaseConfigurationError,
            .catalogUnreachable(URLError.notConnectedToInternet.rawValue), "\(channel)")
        }
      }
      let offline = coordinator(downloader: OfflineDownloader())
      let edge = await edgeCheck(offline, configuration, thisMac)
      XCTAssertEqual(
        edge, EdgeCatalogCheck(availability: .checkFailed(.network), qualifiesThisMac: false))
    }

    func testLegacyTestingRequiresTheSignedDevelopmentDeliveryLineage() async throws {
      let configuration = try configuration()
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: [thisMac])) as? [String: Any])
      object["channel"] = nil
      let arbitrary = try JSONSerialization.data(withJSONObject: object)
      let bad = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(arbitrary)
      ])
      let rejected = await availability(bad, configuration, .testing)
      XCTAssertEqual(rejected, .checkFailed(.verification))
      var models = try XCTUnwrap(object["models"] as? [[String: Any]])
      models[0]["installationProfile"] = "fedora-kde"
      models[0]["evidenceRevision"] = "image-build-41"
      models[0]["payloadArtifact"] = [
        "sourceURL": "https://github.com/aurora-silicon/fedora-aurora/releases/download/"
          + "payload-fedora-kde-41/payload.zip",
        "fileName": "payload.zip", "sizeBytes": 1,
      ]
      object["models"] = models
      let legacy = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(
          JSONSerialization.data(withJSONObject: object))
      ])
      let accepted = await availability(legacy, configuration, .testing)
      XCTAssertEqual(accepted, .available)
    }

    func testUndeclaredTestingCatalogsMatchTheReleasePreparationVectors() throws {
      // scripts/tests/test_distribution_release.py runs the same vectors
      // through prepare-distribution-release.py, so a bundled default that the
      // release preparation accepts is one this policy accepts, and back.
      let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      let data = try Data(
        contentsOf: fixtures.appendingPathComponent("legacy-testing-catalog-vectors.json"))
      let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
      XCTAssertFalse(cases.isEmpty)
      for vector in cases {
        let name = try XCTUnwrap(vector["name"] as? String)
        let accepted = try XCTUnwrap(vector["acceptedAsTesting"] as? Bool)
        let catalog: [String: Any] = [
          "schemaVersion": 5, "sequence": 1, "issuedAt": "2026-09-01T00:00:00Z",
          "models": try XCTUnwrap(vector["models"] as? [Any]),
        ]
        let payload = try JSONSerialization.data(withJSONObject: catalog)
        do {
          try ReleaseCatalogChannelPolicy.validate(payload: payload, channel: .testing)
          XCTAssertTrue(accepted, name)
        } catch {
          XCTAssertFalse(accepted, name)
          XCTAssertEqual(
            error as? InstallerReleaseConfigurationError, .invalidCatalogChannel, name)
        }
      }
    }

    func testADebianTestingCatalogMustDeclareItsChannel() async throws {
      // Debian has no Testing catalogs from before the channel field, so the
      // legacy development lineage never admits one that lacks it.
      let configuration = try configuration()
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: [thisMac])) as? [String: Any])
      object["channel"] = nil
      var models = try XCTUnwrap(object["models"] as? [[String: Any]])
      models[0]["installationProfile"] = "debian-kde"
      models[0]["evidenceRevision"] = "image-build-41"
      models[0]["payloadArtifact"] = [
        "sourceURL": "https://github.com/aurora-silicon/debian-aurora/releases/download/"
          + "payload-debian-kde-41/payload.zip",
        "fileName": "payload.zip", "sizeBytes": 1,
      ]
      object["models"] = models
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .testing): try envelope(
          JSONSerialization.data(withJSONObject: object))
      ])
      let result = await availability(coordinator, configuration, .testing)
      XCTAssertEqual(result, .checkFailed(.verification))
    }

    func testEachChannelReportsItsOwnStateFromItsSignedCatalog() async throws {
      let configuration = try configuration()
      let coordinator = coordinator(serving: [
        configuration.catalogURL(for: .stable): try envelope(
          emptyCatalog(sequence: 5, channel: .stable)),
        configuration.catalogURL(for: .rc): try envelope(
          modelCatalog(devices: ["apple,j274"], channel: .rc)),
        configuration.catalogURL(for: .testing): try envelope(modelCatalog(devices: [thisMac])),
      ])

      let stable = await availability(coordinator, configuration, .stable)
      let rc = await availability(coordinator, configuration, .rc)
      let edge = await availability(coordinator, configuration, .testing)

      XCTAssertEqual(stable, .noRelease)
      XCTAssertEqual(rc, .modelUnavailable(supportedDeviceIdentifiers: ["apple,j274"]))
      XCTAssertEqual(edge, .available)
    }

    func testAnEmptyCatalogWithABadSignatureIsNeverReadAsNoRelease() async throws {
      let configuration = try configuration()
      let payload = emptyCatalog(sequence: 5, channel: .stable)
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
        configuration.catalogURL(for: .stable): try envelope(
          emptyCatalog(sequence: 5, channel: .stable))
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
      let payload = emptyCatalog(sequence: 5, channel: .stable)
      let request = InstallerAssetPreparationRequest(
        host: host(),
        catalogPayload: payload,
        catalogSignature: try key.signature(for: payload),
        trustRoot: try trustRoot(),
        validationTime: now,
        stagingDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("aurora-no-release-\(UUID().uuidString.lowercased())")
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
          .appendingPathComponent("aurora-not-listed-\(UUID().uuidString.lowercased())")
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

    private func edgeCheck(
      _ coordinator: InstallerReleaseAssetCoordinator,
      _ configuration: InstallerReleaseConfiguration,
      _ deviceIdentifier: String
    ) async -> EdgeCatalogCheck {
      await coordinator.edgeCheck(
        configuration: configuration, deviceIdentifier: deviceIdentifier,
        validationTime: now, previouslyAcceptedCatalog: nil)
    }

    private func digest(_ character: Character) -> String {
      "sha256:" + String(repeating: character, count: 64)
    }

    /// A signed Edge catalog with a passing qualification for its payload,
    /// plus `proof` merged into `edgeQualification`.
    private func qualifiedEdgeCatalog(devices: [String], proof: [String: Any]) throws -> Data {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: devices, channel: .edge))
          as? [String: Any])
      let source = { (repository: String) in
        [
          "repository": repository, "branch": "aurora-edge",
          "revision": String(repeating: "a", count: 40), "tree": String(repeating: "b", count: 40),
        ]
      }
      var qualification: [String: Any] = [
        "schemaVersion": 1, "releaseKind": "alpha", "status": "passed", "imageRunID": 41,
        "payloadDigest": digest("3"), "evidenceDigest": digest("4"),
        "linux": source("aurora-silicon/linux"), "mesa": source("aurora-silicon/mesa"),
      ]
      qualification.merge(proof) { _, new in new }
      object["edgeQualification"] = qualification
      return try JSONSerialization.data(withJSONObject: object)
    }

    private func coordinator(downloader: any ReleaseDocumentDownloading)
      -> InstallerReleaseAssetCoordinator
    {
      InstallerReleaseAssetCoordinator(
        catalogFetcher: InstallerReleaseCatalogFetcher(downloader: downloader),
        assetPreparer: InstallerAssetPreparer())
    }

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

    /// What `publish-channels empty-catalog --channel` writes. Without a
    /// channel it is the undeclared form older publishers wrote.
    private func emptyCatalog(sequence: Int, channel: ReleaseChannel?) -> Data {
      let declared = channel.map { "\"channel\":\"\($0.rawValue)\"," } ?? ""
      return Data(
        """
        {"schemaVersion":5,\(declared)"sequence":\(sequence),"issuedAt":"2026-09-01T00:00:00Z","models":[]}
        """.utf8)
    }

    /// An undeclared catalog of the published development delivery lineage.
    private func legacyDevelopmentCatalog() throws -> Data {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: modelCatalog(devices: [thisMac])) as? [String: Any])
      object["channel"] = nil
      var models = try XCTUnwrap(object["models"] as? [[String: Any]])
      models[0]["installationProfile"] = "fedora-kde"
      models[0]["evidenceRevision"] = "image-build-41"
      models[0]["payloadArtifact"] = [
        "sourceURL": "https://github.com/aurora-silicon/fedora-aurora/releases/download/"
          + "payload-fedora-kde-41/payload.zip",
        "fileName": "payload.zip", "sizeBytes": 1,
      ]
      object["models"] = models
      return try JSONSerialization.data(withJSONObject: object)
    }

    private func modelCatalog(devices: [String], channel: ReleaseChannel = .testing) -> Data {
      let models = devices.map { device in
        """
        {"deviceIdentifier":"\(device)","status":"enabled","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","metadataDigest":"sha256:\(String(repeating: "2", count: 64))","payloadDigest":"sha256:\(String(repeating: "3", count: 64))","evidenceRevision":"evidence-s4","metadataArtifact":{"sourceURL":"https://downloads.example.com/metadata.json","fileName":"metadata.json","sizeBytes":1},"payloadArtifact":{"sourceURL":"https://downloads.example.com/payload.zip","fileName":"payload.zip","sizeBytes":1}}
        """
      }
      return Data(
        """
        {"channel":"\(channel.rawValue)","schemaVersion":5,"sequence":7,"issuedAt":"2026-09-01T00:00:00Z","expiresAt":"2027-09-01T00:00:00Z","models":[\(models.joined(separator: ","))]}
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
        defaultChannel: .testing,
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

  private struct OfflineDownloader: ReleaseDocumentDownloading {
    func download(from url: URL, maximumBytes: Int, role: String) async throws -> Data {
      throw URLError(.notConnectedToInternet)
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
