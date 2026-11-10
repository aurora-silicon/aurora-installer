#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class ReviewFindingsStagingTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testATransientNetworkErrorInAPreflightIsANetworkFailure() {
      for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet] {
        let (reason, summary) = NativeInstallerExecutor.preflightFailure(
          stage: .stubFiles, error: URLError(code))
        XCTAssertEqual(reason, .networkUnavailable, "\(code)")
        XCTAssertEqual(summary, NativeInstallerExecutor.networkSummary)
      }
    }

    func testCappingAResizeBelowItsRecommendedSizeKeepsTheTrueMinimum() throws {
      let resize = ValidatedEngineCandidate(
        kind: "resize", sourceIdentifier: "disk0s2", offsetBytes: 0, lengthBytes: 400 * gib,
        minimumInstallBytes: 32 * gib, minimumContainerBytes: 200 * gib, identityDigest: nil,
        recommendedInstallBytes: 62 * gib)
      let recommendation = try InstallerAllocationRecommendation(
        inventory: ValidatedEngineInventory(
          layoutDigest: "sha256:" + String(repeating: "a", count: 64),
          systemStoreIdentifier: "disk0", candidates: [resize]))
      XCTAssertEqual(recommendation.minimumBytes, 62 * gib)
      // A cap between the true minimum and the recommended size still fits.
      let limited = try XCTUnwrap(recommendation.limited(toMaximumBytes: 50 * gib))
      XCTAssertEqual(limited.minimumBytes, 32 * gib)
      XCTAssertEqual(limited.maximumBytes, 50 * gib)
      XCTAssertLessThanOrEqual(limited.requestedLengthBytes, 50 * gib)
      XCTAssertNil(recommendation.limited(toMaximumBytes: 31 * gib))
      XCTAssertEqual(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 80 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 30 * gib
        ).maximumBytes, 50 * gib)
    }

    func testAReplacementIsCheckedForStagingSpaceToo() {
      let replace = ValidatedEngineCandidate(
        kind: "replace", sourceIdentifier: "disk0s4", offsetBytes: 0, lengthBytes: 100 * gib,
        minimumInstallBytes: 32 * gib, minimumContainerBytes: 0,
        identityDigest: "sha256:" + String(repeating: "9", count: 64), recommendedInstallBytes: nil)
      let recommendation = InstallerAllocationRecommendation(
        candidate: replace, floorBytes: 100 * gib, minimumBytes: 100 * gib,
        maximumBytes: 100 * gib, requestedLengthBytes: 100 * gib)
      XCTAssertThrowsError(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 8 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 12 * gib)
      ) {
        XCTAssertEqual(
          $0 as? MacOSFreeSpaceShortfall,
          MacOSFreeSpaceShortfall(requiredBytes: 12 * gib, availableBytes: 8 * gib))
      }
    }

    func testMacsWhoseFirmwareIsARestoreImagePassTheUpdateArchiveRefusal() async throws {
      let metadata = try Self.metadata()
      defer {
        try? FileManager.default.removeItem(at: metadata.fileURL.deletingLastPathComponent())
      }
      struct Reached: Error { let url: URL }
      for (device, chip) in [
        ("apple,j274", UInt64(0x8103)), ("apple,j413", 0x8112), ("apple,j414s", 0x6020),
      ] {
        let hardware = NativeInspectionHardware(
          chipID: chip, bootVersion: "iBoot-11881.1.1", macOSVersion: "15.1",
          recoveryVersion: "24.1.0.0.0,0")
        let estimator = NativeStubStagingEstimator(
          facts: { .init(deviceIdentifier: device, hardware: hardware) }, boardID: { 1 },
          open: { throw Reached(url: $0) })
        do {
          _ = try await estimator.requiredFreeBytes(deviceIdentifier: device, metadata: metadata)
          XCTFail("\(device): the stand-in reader returned")
        } catch let reached as Reached {
          XCTAssertTrue(reached.url.lastPathComponent.hasSuffix("_Restore.ipsw"), device)
        }
      }
    }

    static func metadata() throws -> StagedInstallerArtifact {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let data = try JSONSerialization.data(withJSONObject: [
        "os_list": [
          [
            "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
            "partitions": [["size": "1GiB"]],
          ]
        ]
      ])
      let url = root.appendingPathComponent("metadata.json")
      try data.write(to: url)
      return StagedInstallerArtifact(
        artifact: try PinnedInstallerArtifact(
          role: "metadata", sourceURL: URL(string: "https://example.com/metadata.json")!,
          fileName: "metadata.json", expectedDigest: SHA256Digest(hashing: data).rawValue,
          expectedSizeBytes: UInt64(data.count)),
        fileURL: url, reusedExistingFile: false)
    }
  }
#endif
