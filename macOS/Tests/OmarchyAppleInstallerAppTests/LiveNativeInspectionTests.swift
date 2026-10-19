import Foundation
import XCTest

@testable import OmarchyAppleInstallerApp
@testable import OmarchyAppleInstallerTrustCore

final class LiveNativeInspectionTests: XCTestCase {
  func testWelcomeInspectionUsesNativeServiceBeforeDownloadingAnEngine() async throws {
    let unit: UInt64 = 1_048_576
    let candidate = EngineInstallCandidate(
      kind: "free", sourceIdentifier: "disk0s2",
      offsetBytes: 128 * unit, lengthBytes: 262_144 * unit, minimumInstallBytes: 8192 * unit,
      minimumContainerBytes: 0, identityDigest: nil, recommendedInstallBytes: 16_384 * unit,
      recommendedContainerBytes: 0)
    let unsigned = EngineInventoryMessage(
      layoutDigest: "", systemStoreIdentifier: "disk0", candidates: [candidate])
    let inventory = EngineInventoryMessage(
      layoutDigest: unsigned.computedLayoutDigest,
      systemStoreIdentifier: "disk0", candidates: [candidate])
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let payload = try JSONSerialization.jsonObject(with: encoder.encode(inventory))
    var bytes = Data()
    for (index, row) in [
      ("inspection", ["device_identifier": "apple,j314s", "support": "supported"] as Any),
      ("inventory", payload),
    ].enumerated() {
      bytes.append(
        try JSONSerialization.data(withJSONObject: [
          "schema_version": 1, "sequence": index + 1, "type": row.0, "payload": row.1,
        ]))
      bytes.append(10)
    }
    let host = AppleSiliconHostInspection(
      identity: AppleMacIdentity(
        model: "MacBookPro18,3",
        chip: "Apple M1 Pro", deviceIdentifier: "apple,j314s"), eligibility: .requiresSignedCatalog,
      macOSVersion: "26.6.2", powerSource: .ac, fileVaultEnabled: true,
      storage: APFSStorageInspection(
        containerIdentifier: "disk4", physicalStoreIdentifier: "disk0s2",
        isInternal: true, containerSizeBytes: 512 * 1024 * unit,
        containerFreeBytes: 256 * 1024 * unit,
        minimumPreferredSizeBytes: 128 * 1024 * unit))
    let known = NativeKnownInstallation(
      sourceIdentifier: "disk0s4", offsetBytes: 4096,
      lengthBytes: 16_384 * unit)
    let service = FixedNativeInspection(
      result: try NativeInstallerInspection(
        transcript: bytes,
        knownInstallations: [known, known]))
    let environment = LiveInstallerEnvironment(inspector: service, inspectHost: { host })
    let display = try await environment.inspect()
    XCTAssertTrue(display.supported)
    XCTAssertTrue(environment.engineSupported)
    XCTAssertEqual(display.existingInstalls.map(\.sourceIdentifier), ["disk0s4"])
    let calls = await service.calls()
    XCTAssertEqual(calls, [false])
  }
}

private actor FixedNativeInspection: NativeInstallerInspecting {
  let result: NativeInstallerInspection
  private var metadataArguments = [Bool]()
  init(result: NativeInstallerInspection) { self.result = result }
  func inspect(host: AppleSiliconHostInspection, metadata: StagedInstallerArtifact?) async throws
    -> NativeInstallerInspection
  {
    metadataArguments.append(metadata != nil)
    return result
  }
  func calls() -> [Bool] { metadataArguments }
}
