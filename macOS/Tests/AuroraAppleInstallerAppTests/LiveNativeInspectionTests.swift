import AuroraInstallerUXCore
import CryptoKit
import Foundation
import XCTest

@testable import AuroraAppleInstallerApp
@testable import AuroraAppleInstallerTrustCore

final class LiveNativeInspectionTests: XCTestCase {
  func testStartupDefersRecoveryQueryUntilTheInstalledServiceIsAuthenticated() async throws {
    for status in [InstallerHelperStatus.missing, .outdated, .disabled, .busy] {
      let events = LiveInspectionEvents()
      let environment = LiveInstallerEnvironment(
        helperProbe: { HelperDisplay(status: status, canInstall: true) },
        recoveryAccountInspector: {
          events.append("account-query")
          throw EngineXPCSubmissionError.connectionFailed
        })
      let account = try await environment.inspectRecoveryAccount()
      XCTAssertNil(account)
      XCTAssertTrue(events.values.isEmpty, "Unauthenticated service was queried: \(status)")
    }
  }

  func testStartupStillQueriesTheAuthenticatedCurrentService() async throws {
    let events = LiveInspectionEvents()
    let environment = LiveInstallerEnvironment(
      helperProbe: { HelperDisplay(status: .current, canInstall: true) },
      recoveryAccountInspector: {
        events.append("account-query")
        return RecoveryAccountReply()
      })
    let account = try await environment.inspectRecoveryAccount()
    XCTAssertNil(account)
    XCTAssertEqual(events.values, ["account-query"])
  }

  func testWelcomeInspectionUsesNativeServiceBeforeDownloadingAnEngine() async throws {
    let (host, bytes, known) = try fixture()
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

  private func fixture() throws -> (AppleSiliconHostInspection, Data, NativeKnownInstallation) {
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
    return (host, bytes, known)
  }

  func testInspectionWaitsForRetiredWritersBeforeSamplingHostFreeSpace() async throws {
    let (host, bytes, _) = try fixture()
    let service = FixedNativeInspection(result: try NativeInstallerInspection(transcript: bytes))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "live-retirement-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("payload".utf8)
    let artifact = try PinnedInstallerArtifact(
      role: "payload", sourceURL: URL(string: "https://example.com/payload.bin")!,
      fileName: "payload.bin",
      expectedDigest: "sha256:"
        + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      expectedSizeBytes: UInt64(data.count))
    let gate = LiveRetirementGate()
    let events = LiveInspectionEvents()
    let prefetch = PayloadPrefetchOrchestrator(
      makeNetwork: { DisplayTestNetwork() }, makeKeepAwake: { DisplayTestKeepAwake() },
      makeFreeSpace: { _ in DisplayTestFreeSpace() }, matchesPinned: { _, _ in false },
      requiredFreeBytes: { $0 }, requiresNetwork: { _ in false },
      stage: { artifact, directory, _ in
        let file = directory.appendingPathComponent(artifact.fileName)
        try data.write(to: file)
        await gate.wait()
        events.append("writer-finished")
        return StagedInstallerArtifact(artifact: artifact, fileURL: file, reusedExistingFile: false)
      })
    prefetch.begin(
      payload: StagedInstallerArtifact(
        artifact: artifact, fileURL: root.appendingPathComponent(artifact.fileName),
        reusedExistingFile: false))
    await gate.waitUntilEntered()
    prefetch.cancel()
    let environment = LiveInstallerEnvironment(
      inspector: service,
      inspectHost: {
        events.append("host-sampled")
        return host
      }, prefetch: prefetch)
    let inspection = Task { try await environment.inspect() }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(events.values.contains("host-sampled"))
    await gate.release()
    _ = try await inspection.value
    XCTAssertEqual(events.values, ["writer-finished", "host-sampled"])
  }
}

private final class LiveInspectionEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) { lock.withLock { storage.append(value) } }
  var values: [String] { lock.withLock { storage } }
}

private actor LiveRetirementGate {
  private var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilEntered() async { while !entered { await Task.yield() } }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct DisplayTestNetwork: InstallerNetworkPathObserving {
  func current() -> InstallerNetworkPathSnapshot {
    InstallerNetworkPathSnapshot(isSatisfied: true, isExpensive: false, isConstrained: false)
  }
  func updates() -> AsyncStream<InstallerNetworkPathSnapshot> { AsyncStream { $0.finish() } }
}

private struct DisplayTestKeepAwake: InstallerKeepAwakeHolding {
  func acquire() {}
  func release() {}
}

private struct DisplayTestFreeSpace: InstallerFreeSpaceChecking {
  func availableBytes() throws -> UInt64 { 8_000_000_000 }
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
