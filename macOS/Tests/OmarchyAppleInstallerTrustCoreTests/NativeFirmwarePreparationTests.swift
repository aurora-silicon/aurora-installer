#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  private actor NativePreparationObservations {
    private var calls: [[String]] = []
    func append(_ value: [String]) { calls.append(value) }
    func snapshot() -> [[String]] { calls }
  }

  private enum FirmwarePreparationInterruption: Error { case simulated }

  final class NativeFirmwarePreparationTests: XCTestCase {
    private func workspace() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      return root
    }

    func testInterruptedExtractionReusesItsPrivateRecipeAndRangeCache() async throws {
      let root = try workspace()
      let observations = NativePreparationObservations()
      let preparer = NativeFirmwarePreparer(expectedOwnerID: geteuid()) { plan, output, cache in
        try FileManager.default.createDirectory(
          at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
          at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = cache.appendingPathComponent("retained-range")
        let previous = FileManager.default.fileExists(atPath: marker.path)
        if !previous { try Data("verified range".utf8).write(to: marker) }
        await observations.append([plan.recipeSHA256, output.path, cache.path, String(previous)])
        if !previous { throw FirmwarePreparationInterruption.simulated }
      }
      do {
        _ = try await preparer.prepare(deviceIdentifier: "apple,j700", in: root)
        XCTFail("Expected the first extraction to be interrupted")
      } catch FirmwarePreparationInterruption.simulated {}
      let second = try await preparer.prepare(deviceIdentifier: "apple,j700", in: root)
      let calls = await observations.snapshot()
      XCTAssertEqual(second?.path, calls[0][1])
      XCTAssertEqual(calls.count, 2)
      XCTAssertEqual(Array(calls[0].prefix(3)), Array(calls[1].prefix(3)))
      XCTAssertEqual(calls.map { $0[3] }, ["false", "true"])
      XCTAssertEqual(
        calls[0][0], try FirmwareExtractionPlan.bundled(for: "apple,j700").recipeSHA256)
    }

    func testOtherBoardsDoNotStartTheNeoDownload() async throws {
      let observations = NativePreparationObservations()
      let preparer = NativeFirmwarePreparer(expectedOwnerID: geteuid()) { _, _, _ in
        await observations.append(["unexpected download"])
      }
      let output = try await preparer.prepare(
        deviceIdentifier: "apple,j314s", in: URL(fileURLWithPath: "/does-not-exist"))
      XCTAssertNil(output)
      let calls = await observations.snapshot()
      XCTAssertTrue(calls.isEmpty)
    }

    func testUnsafeOwnerAndPublishedSymlinkAreRefused() async throws {
      let root = try workspace()
      let observations = NativePreparationObservations()
      let wrongOwner = NativeFirmwarePreparer(expectedOwnerID: geteuid() + 1) { _, _, _ in
        await observations.append(["unexpected download"])
      }
      do {
        _ = try await wrongOwner.prepare(deviceIdentifier: "apple,j700", in: root)
        XCTFail("A caller-owned directory was admitted")
      } catch { XCTAssertEqual(error as? InstallerJobError, .unsafeState) }
      let calls = await observations.snapshot()
      XCTAssertTrue(calls.isEmpty)
      let linked = NativeFirmwarePreparer(expectedOwnerID: geteuid()) { _, output, _ in
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: root)
      }
      do {
        _ = try await linked.prepare(deviceIdentifier: "apple,j700", in: root)
        XCTFail("A linked output was admitted")
      } catch { XCTAssertEqual(error as? InstallerJobError, .unsafeState) }
    }
  }
#endif
