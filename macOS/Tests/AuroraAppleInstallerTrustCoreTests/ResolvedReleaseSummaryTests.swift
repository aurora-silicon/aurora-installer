#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class ResolvedReleaseSummaryTests: XCTestCase {
    private let feed = URL(
      string: "https://example.invalid/Profiles/fedora-kde/channels/edge-alpha/catalog.signed.json")!

    private func catalog(_ extra: [String: Any] = [:]) throws -> Data {
      var object: [String: Any] = [
        "schemaVersion": 5, "sequence": 1_795_229_840, "issuedAt": "2026-11-21T02:57:20Z",
        "models": [
          [
            "deviceIdentifier": "apple,j413",
            "payloadDigest": "sha256:" + String(repeating: "1", count: 64),
          ],
          [
            "deviceIdentifier": "apple,j700",
            "payloadDigest": "sha256:" + String(repeating: "a", count: 64),
            "downstreamRevision": "99f180f9", "evidenceRevision": "image-build-44843863741",
            "payloadArtifact": ["sourceURL": "https://example.invalid/payload.zip"],
          ],
        ],
      ]
      object.merge(extra) { $1 }
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testAFetchedEdgeCatalogNamesItsFeedThisMacsBuildAndItsSources() throws {
      let payload = try catalog([
        "edgeQualification": [
          "linux": ["branch": "main", "revision": "c4b7e839"],
          "mesa": ["branch": "aurora-wip", "revision": "36623c0a"],
        ]
      ])
      let line = ResolvedReleaseSummary(
        payload: payload, channel: .edge, sealed: false, feed: feed,
        minimumSequence: 1_795_229_000, deviceIdentifier: "apple,j700"
      ).logLine
      XCTAssertTrue(line.hasPrefix("Resolved release: channel=edge source=\(feed.absoluteString) "))
      for field in [
        "sequence=1795229840", "issued=2026-11-21T02:57:20Z", "floor=1795229000", "mac=apple,j700",
        "payload=sha256:" + String(repeating: "a", count: 64),
        "from=https://example.invalid/payload.zip", "downstream=99f180f9",
        "evidence=image-build-44843863741", "linux=main@c4b7e839", "mesa=aurora-wip@36623c0a",
      ] {
        XCTAssertTrue(line.contains(" \(field)"), field)
      }
    }

    func testASealedCatalogSaysSoAndLeavesOutWhatItDoesNotCarry() throws {
      let line = ResolvedReleaseSummary(
        payload: try catalog(), channel: .stable, sealed: true, feed: feed,
        minimumSequence: nil, deviceIdentifier: "apple,j999"
      ).logLine
      XCTAssertTrue(line.contains("channel=stable source=sealed sequence=1795229840"))
      XCTAssertTrue(line.contains(" mac=apple,j999"))
      for absent in ["floor=", "payload=", "from=", "linux=", "mesa="] {
        XCTAssertFalse(line.contains(absent), absent)
      }
    }
  }
#endif
