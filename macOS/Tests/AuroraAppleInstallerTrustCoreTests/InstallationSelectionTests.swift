import CryptoKit
import Foundation
import XCTest

@testable import AuroraAppleInstallerTrustCore

final class InstallationSelectionTests: XCTestCase {
  func testEachLinuxDesktopHasItsOwnProfile() {
    let optedIn = ProcessInfo.processInfo.environment["AURORA_ENABLE_OMARCHY"] == "1"
    let distributions: [AuroraDistribution] = [.fedora, .arch, .nixos, .debian]
    XCTAssertEqual(
      AuroraDistribution.installable,
      distributions + (optedIn ? [.omarchy] : []))
    var expected: Set<String> = [
      "fedora-kde", "fedora-gnome", "fedora-minimal",
      "arch-kde", "arch-gnome", "arch-minimal",
      "nixos-kde", "nixos-gnome", "nixos-minimal",
      "debian-kde", "debian-gnome", "debian-minimal",
    ]
    if optedIn { expected.insert("omarchy-hyprland") }
    XCTAssertEqual(AuroraInstallationSelection.allProfileIDs, expected)
  }

  func testDebianOffersTheStandardDesktops() throws {
    XCTAssertEqual(AuroraDistribution.debian.availableDesktops, [.kde, .gnome, .minimal])
    for desktop in AuroraDistribution.debian.availableDesktops {
      let selection = AuroraInstallationSelection(distribution: .debian, desktop: desktop)
      XCTAssertEqual(selection.profileID, "debian-" + desktop.rawValue)
      try selection.requireMatchingProfile(selection.profileID)
      XCTAssertThrowsError(try selection.requireMatchingProfile("arch-" + desktop.rawValue))
    }
    var selection = AuroraInstallationSelection(distribution: .omarchy)
    selection.selectDistribution(.debian)
    XCTAssertEqual(selection.profileID, "debian-kde")
    let invalid = AuroraInstallationSelection(distribution: .debian, desktop: .hyprland)
    XCTAssertThrowsError(try invalid.requireMatchingProfile(invalid.profileID))
    let data = try JSONEncoder().encode(invalid)
    XCTAssertThrowsError(try JSONDecoder().decode(AuroraInstallationSelection.self, from: data))
  }

  func testOmarchyOffersOnlyHyprlandAndSwitchingKeepsAValidSelection() throws {
    var selection = AuroraInstallationSelection()
    selection.selectDistribution(.omarchy)
    XCTAssertEqual(selection.desktop, .hyprland)
    XCTAssertEqual(selection.profileID, "omarchy-hyprland")
    XCTAssertEqual(AuroraDistribution.omarchy.availableDesktops, [.hyprland])
    if ProcessInfo.processInfo.environment["AURORA_ENABLE_OMARCHY"] == "1" {
      try selection.requireMatchingProfile("omarchy-hyprland")
    } else {
      XCTAssertThrowsError(try selection.requireMatchingProfile("omarchy-hyprland"))
    }
    selection.selectDistribution(.arch)
    XCTAssertEqual(selection.desktop, .kde)
    XCTAssertEqual(selection.profileID, "arch-kde")
    for pair in [(AuroraDistribution.omarchy, AuroraDesktop.kde), (.arch, .hyprland)] {
      let invalid = AuroraInstallationSelection(distribution: pair.0, desktop: pair.1)
      XCTAssertThrowsError(try invalid.requireMatchingProfile(invalid.profileID))
      let data = try JSONEncoder().encode(invalid)
      XCTAssertThrowsError(try JSONDecoder().decode(AuroraInstallationSelection.self, from: data))
    }
  }

  func testNixOSKeepsItsDesktopInTheSignedProfile() {
    for desktop in AuroraDistribution.nixos.availableDesktops {
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
      "metadataDigest": "sha256:" + String(repeating: "e", count: 64),
      "payloadDigest": "sha256:" + String(repeating: "f", count: 64),
      "evidenceRevision": "test-profile",
      "metadataArtifact": [
        "sourceURL": "https://downloads.example.com/metadata.json",
        "fileName": "metadata.json", "sizeBytes": 1,
      ],
      "payloadArtifact": [
        "sourceURL": "https://downloads.example.com/payload.zip",
        "fileName": "payload.zip", "sizeBytes": 1,
      ],
    ]
    let payload = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 5, "sequence": 1, "issuedAt": "2026-01-01T00:00:00Z",
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
