#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class PrivateM3CatalogTests: XCTestCase {
    func testActualDraftThroughSealedCatalogTrustPath() async throws {
      guard let catalogPath = ProcessInfo.processInfo.environment["OMARCHY_PRIVATE_CATALOG"] else {
        throw XCTSkip("Set OMARCHY_PRIVATE_CATALOG to the pinned private M3 catalog")
      }
      let payload = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
      XCTAssertEqual(
        SHA256Digest(hashing: payload).rawValue,
        "sha256:b378959e19acee3f75af935d1f28260ab056bad06ce800a99988785df23a9b0c")
      let key = Curve25519.Signing.PrivateKey()
      let publicKey = key.publicKey.rawRepresentation
      let signature = try key.signature(for: payload)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let descriptor: [String: Any] = [
        "schema_version": 3, "default_channel": "rc",
        "channels": Dictionary(
          uniqueKeysWithValues: ["stable", "rc", "edge"].map {
            ($0, ["catalog_url": "https://quattro-development.invalid/\($0)/catalog.signed.json"])
          }),
        "trust_root_fingerprint": SHA256Digest(hashing: publicKey).rawValue,
        "helper_mach_service_name": InstallerProductIdentity.helperMachServiceName,
        "helper_code_signing_requirement":
          "identifier \"\(InstallerProductIdentity.helperIdentifier)\"",
      ]
      let files = [
        "release.json": try JSONSerialization.data(withJSONObject: descriptor),
        "trust-root.ed25519.pub": publicKey, "catalog.json": payload, "catalog.json.sig": signature,
      ]
      for (name, data) in files {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
      let configuration = try InstallerReleaseConfigurationLocator().load(from: directory)
      let documents = try await InstallerReleaseCatalogFetcher().fetch(
        configuration: configuration, channel: .rc)
      XCTAssertEqual(documents.payload, payload)
      let core = AppleInstallerTrustCore()
      let catalog = try core.validateSupportCatalog(
        payload: documents.payload, signature: documents.signature,
        trustRoot: configuration.trustRoot, now: Date())
      guard case .admitted(let record) = catalog.admission(for: "apple,j613") else {
        return XCTFail("13-inch M3 Air must be admitted")
      }
      XCTAssertEqual(
        record.payloadDigest,
        "sha256:161e4273e0885986210b64eb7a9e14756e6bcb3c7a8383f3f58cb43248cdf595")
      for model in [
        "apple,j433", "apple,j434", "apple,j504", "apple,j613", "apple,j615",
        "apple,j514s", "apple,j514c", "apple,j514m", "apple,j516s", "apple,j516c", "apple,j516m",
      ] {
        guard case .admitted = catalog.admission(for: model) else {
          return XCTFail("M3 private test model must be admitted: \(model)")
        }
      }
      for model in ["apple,j614s", "apple,j313", "apple,unknown"] {
        XCTAssertEqual(catalog.admission(for: model), .unsupported(deviceIdentifier: model))
      }
      XCTAssertThrowsError(
        try core.validateSupportCatalog(
          payload: payload + Data([32]), signature: signature, trustRoot: configuration.trustRoot,
          now: Date()))
      let wrongSignature = try Curve25519.Signing.PrivateKey().signature(for: payload)
      XCTAssertThrowsError(
        try core.validateSupportCatalog(
          payload: payload, signature: wrongSignature, trustRoot: configuration.trustRoot,
          now: Date()))
      let newer = try AcceptedCatalogIdentity(
        sequence: catalog.sequence + 1, payloadDigest: SHA256Digest(hashing: payload).rawValue)
      XCTAssertThrowsError(
        try core.validateSupportCatalog(
          payload: payload, signature: signature, trustRoot: configuration.trustRoot, now: Date(),
          previouslyAccepted: newer))
    }
  }
#endif
