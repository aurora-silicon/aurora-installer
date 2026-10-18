import CryptoKit
import Foundation
import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class InstallationSelectionTests: XCTestCase {
  func testEachLinuxDesktopHasItsOwnProfile() {
    XCTAssertEqual(
      AuroraInstallationSelection.allProfileIDs,
      [
        "fedora-kde", "fedora-gnome", "fedora-minimal",
        "arch-kde", "arch-gnome", "arch-minimal",
        "nixos-kde", "nixos-gnome", "nixos-minimal",
      ])
  }

  func testNixOSKeepsItsDesktopInTheSignedProfile() {
    for desktop in AuroraDesktop.allCases {
      let selection = AuroraInstallationSelection(distribution: .nixos, desktop: desktop)
      XCTAssertEqual(selection.effectiveDesktop, desktop)
      XCTAssertEqual(selection.profileID, "nixos-" + desktop.rawValue)
      XCTAssertThrowsError(try selection.requireMatchingProfile("fedora-" + desktop.rawValue))
    }
  }

  func testTheSelectedProfileMustMatchTheSignedRelease() throws {
    let selection = AuroraInstallationSelection(distribution: .arch, desktop: .gnome)
    try selection.requireMatchingProfile("arch-gnome")
    XCTAssertThrowsError(try selection.requireMatchingProfile("fedora-gnome"))
    XCTAssertThrowsError(try selection.requireMatchingProfile("arch-kde"))
    XCTAssertThrowsError(try selection.requireMatchingProfile(nil))
  }
  func testSignedCatalogBindsTheInstallationProfile() throws {
    let key = Curve25519.Signing.PrivateKey()
    let model: [String: Any] = [
      "deviceIdentifier": "apple,j700", "status": "enabled", "installationProfile": "arch-gnome",
      "asahiInstallerTag": "v0.9.2", "asahiInstallerRevision": String(repeating: "a", count: 40),
      "asahiInstallerDataRevision": String(repeating: "b", count: 40),
      "downstreamRevision": String(repeating: "c", count: 40),
      "engineDigest": "sha256:" + String(repeating: "d", count: 64),
      "metadataDigest": "sha256:" + String(repeating: "e", count: 64),
      "payloadDigest": "sha256:" + String(repeating: "f", count: 64),
      "evidenceRevision": "test-profile",
    ]
    let payload = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "sequence": 1, "issuedAt": "2026-01-01T00:00:00Z",
      "expiresAt": "2027-01-01T00:00:00Z", "models": [model],
    ])
    let publicKey = key.publicKey.rawRepresentation
    let fingerprint =
      "sha256:" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    let catalog = try AppleInstallerTrustCore().validateSupportCatalog(
      payload: payload, signature: key.signature(for: payload),
      trustRoot: AppOwnedTrustRoot(rawRepresentation: publicKey, expectedFingerprint: fingerprint),
      now: Date(timeIntervalSince1970: 1_788_000_000))
    guard case .admitted(let record) = catalog.admission(for: "apple,j700") else {
      return XCTFail("Expected the signed profile to be admitted")
    }
    XCTAssertEqual(record.installationProfile, "arch-gnome")
    try AuroraInstallationSelection(distribution: .arch, desktop: .gnome)
      .requireMatchingProfile(record.installationProfile)
    XCTAssertThrowsError(
      try AuroraInstallationSelection().requireMatchingProfile(record.installationProfile))
  }

}
