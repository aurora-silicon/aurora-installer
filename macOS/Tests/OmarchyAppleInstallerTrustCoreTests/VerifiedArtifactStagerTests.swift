import CryptoKit
import Darwin
import Foundation
import Network
import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class VerifiedArtifactStagerTests: XCTestCase {
  func testDescriptorRejectsUntrustedInputs() {
    XCTAssertThrowsError(
      try descriptor(source: "http://example.com/installer.tar.gz")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(try descriptor(fileName: "../installer.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(fileName: "installer\0ignored.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(digest: "sha256:ABC")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidDigest)
    }
  }

  func testValidDownloadIsVerifiedAndAcceptedAtomically() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)

    let result = try await VerifiedArtifactStager(
      downloader: downloader
    ).stage(artifact, in: directory)

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertFalse(result.reusedExistingFile)
    XCTAssertEqual(result.materialization, .atomicRename)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [artifact.fileName]
    )
  }

  func testBundledArtifactIsVerifiedWithoutDownloadAndRemainsInBundle() async throws {
    let data = Data("bundled metadata".utf8)
    let artifact = try descriptor(data: data)
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let source = bundle.appendingPathComponent(artifact.fileName)
    try data.write(to: source)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let result = try await VerifiedArtifactStager(
      downloader: downloader, bundledArtifactDirectory: bundle
    ).stage(artifact, in: root.appendingPathComponent("staging"))
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(try Data(contentsOf: source), data)
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
    // Same size, different bytes: only the digest can catch it.
    try Data(repeating: UInt8(ascii: "x"), count: data.count).write(to: source)
    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader, bundledArtifactDirectory: bundle)
        .stage(artifact, in: root.appendingPathComponent("other-staging"))
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digest mismatch, got \(error)")
      }
    }
  }

  func testExactExistingArtifactIsReusedWithoutDownload() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(artifact, in: directory)
    let replay = try await stager.stage(artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
  }

  func testOfflineBundleStagesEveryRoleWithoutDownload() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Artifacts")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let stager = VerifiedArtifactStager(
      downloader: downloader, bundledArtifactDirectory: bundle, requiresBundledArtifacts: true)
    for role in ["metadata", "payload"] {
      let data = Data("bundled \(role)".utf8)
      let artifact = try PinnedInstallerArtifact(
        role: role, sourceURL: URL(string: "https://example.invalid/\(role)")!,
        fileName: role, expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count))
      try data.write(to: bundle.appendingPathComponent(role))
      let result = try await stager.stage(artifact, in: root.appendingPathComponent("staging"))
      XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
      XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(role)), data)
    }
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
  }

  func testOfflineBundleFailsClosedWithoutNetworkFallback() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Artifacts")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let stager = VerifiedArtifactStager(
      downloader: downloader, bundledArtifactDirectory: bundle, requiresBundledArtifacts: true)
    let data = Data("expected payload".utf8)
    let artifact = try PinnedInstallerArtifact(
      role: "payload", sourceURL: URL(string: "https://example.invalid/os.zip")!,
      fileName: "os.zip", expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count))
    await assertThrows(try await stager.stage(artifact, in: root.appendingPathComponent("missing")))
    {
      XCTAssertEqual($0 as? ArtifactStageError, .bundledArtifactMissing("os.zip"))
    }
    try Data(repeating: 0, count: data.count).write(to: bundle.appendingPathComponent("os.zip"))
    await assertThrows(try await stager.stage(artifact, in: root.appendingPathComponent("corrupt")))
    {
      guard case .digestMismatch = $0 as? ArtifactStageError else {
        return XCTFail("Expected digest mismatch, got \($0)")
      }
    }
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
  }

  func testDigestMismatchLeavesNoAcceptedOrPendingFile() async throws {
    let expected = Data("expected".utf8)
    let delivered = Data("tampered".utf8)
    let downloader = FixtureArtifactDownloader(data: delivered)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: expected)

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testWrongExistingDestinationFailsClosed() async throws {
    let data = Data("expected".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let artifact = try descriptor(data: data)
    try Data("wrong".utf8).write(
      to: directory.appendingPathComponent(artifact.fileName)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(artifact.fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testSizeMismatchIsRejectedBeforeAcceptance() async throws {
    let data = Data("payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try PinnedInstallerArtifact(
      role: "payload",
      sourceURL: URL(string: "https://example.com/installer.tar.gz")!,
      fileName: "installer.tar.gz",
      expectedDigest: digest(data),
      expectedSizeBytes: UInt64(data.count + 1)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count + 1),
          actual: UInt64(data.count)
        )
      )
    }
  }

  func testCrossDeviceRenameUsesVerifiedCopyFallback() async throws {
    let data = Data("cross-device payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EXDEV) }

    let result = try await VerifiedArtifactStager(
      downloader: downloader,
      promoter: promoter
    ).stage(artifact, in: directory)

    XCTAssertEqual(result.materialization, .verifiedCopyFallback)
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
  }

  func testRenameFailureOtherThanCrossDeviceDoesNotCopy() async throws {
    let data = Data("do not copy".utf8)
    let source = temporaryDirectory()
    let destination = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }
    try data.write(to: source, options: .withoutOverwriting)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EACCES) }

    XCTAssertThrowsError(try promoter.promote(source: source, pending: destination))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testMultiPartDescriptorRejectsUnusableManifests() throws {
    let data = Data("multi-part installer payload".utf8)
    let chunks = partition(data, into: 2)

    XCTAssertThrowsError(
      try descriptor(data: data, parts: [try part(chunks[0], index: 0)])
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(1))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: Data(repeating: 0x61, count: 17),
        parts: try (0..<17).map { index in
          try part(Data([0x61]), index: index)
        }
      )
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(17))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1], index: 0),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz.part00")
      )
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], fileName: "installer.tar.gz"),
          try part(chunks[1], index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz")
      )
    }
    XCTAssertThrowsError(
      try part(chunks[0], fileName: "../installer.tar.gz.part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(
      try part(chunks[0], source: "http://example.com/part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1].dropLast(), index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .partSizeSumMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count - 1)
        )
      )
    }
  }

  func testMultiPartDescriptorAcceptsBoundaryPartCounts() throws {
    let data = Data("multi-part installer payload".utf8)
    let pair = partition(data, into: 2)
    let twoParts = try descriptor(
      data: data,
      parts: [try part(pair[0], index: 0), try part(pair[1], index: 1)]
    )
    XCTAssertEqual(twoParts.parts.count, 2)

    let wide = Data(repeating: 0x62, count: 16)
    let chunks = partition(wide, into: 16)
    let sixteenParts = try descriptor(
      data: wide,
      parts: try chunks.enumerated().map { index, chunk in
        try part(chunk, index: index)
      }
    )
    XCTAssertEqual(sixteenParts.parts.count, 16)
  }

  func testMultiPartPayloadIsAssembledFromVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory,
      progress: recorder.handler
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(result.materialization, .assembledFromParts)
    XCTAssertFalse(result.reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    // Parts download together, so they may start in either order.
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(
      Set(requestedURLs), Set(fixture.artifact.parts.map(\.sourceURL)))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )

    let events = recorder.events
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
    XCTAssertTrue(events.contains { $0.phase == .assembling })
    XCTAssertTrue(
      events.allSatisfy { $0.role == "payload" && $0.totalBytes == UInt64(data.count) }
    )
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(
      events.compactMap(\.partCount).allSatisfy { $0 == 2 },
      true
    )
  }

  func testPartsDownloadSeveralAtATime() async throws {
    let data = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    let fixture = try partsFixture(data: data, count: 7)
    let downloader = ConcurrentFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact, in: directory, progress: recorder.handler)

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let most = await downloader.mostInFlight
    XCTAssertEqual(most, VerifiedArtifactStager.partsInFlight)
    let downloads = await downloader.downloadCount
    XCTAssertEqual(downloads, 7)
    let totals = recorder.events.filter { $0.phase == .downloading }.map(\.bytesCompleted)
    XCTAssertEqual(totals, totals.sorted(), "Progress never goes backwards")
    XCTAssertEqual(totals.last, UInt64(data.count))
  }

  func testAFailedPartLetsThePartsInFlightFinishAndStartsNoMore() async throws {
    let data = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let fixture = try partsFixture(data: data, count: 5)
    var responses = fixture.responses
    let tampered = fixture.artifact.parts[1]
    responses[tampered.sourceURL] = Data(
      repeating: 0x21, count: Int(tampered.expectedSizeBytes))
    let downloader = ConcurrentFixtureDownloader(responses: responses, failing: tampered.sourceURL)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact, in: directory)
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    XCTAssertEqual(
      kept, [fixture.artifact.parts[0].fileName, fixture.artifact.parts[2].fileName].sorted())
    let downloads = await downloader.downloadCount
    XCTAssertEqual(downloads, VerifiedArtifactStager.partsInFlight)
  }

  func testAnInterruptedDownloadResumesWhereItStopped() async throws {
    let image = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 12) })
    let server = try ResumingHTTPServer(image: image, dropAfter: 1 << 20)
    let url = try await server.start()
    defer { server.stop() }
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let resumeData = directory.appendingPathComponent(
      VerifiedArtifactStager.resumeDataName(for: "payload.bin"))
    let downloader = ProgressReportingArtifactDownloader()

    do {
      _ = try await downloader.download(
        from: url, expectedSizeBytes: UInt64(image.count), resumeData: resumeData, onBytes: nil)
      XCTFail("The dropped connection must fail the first transfer")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: resumeData.path))

    let file = try await downloader.download(
      from: url, expectedSizeBytes: UInt64(image.count), resumeData: resumeData, onBytes: nil)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(try Data(contentsOf: file), image)
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeData.path))
    let requests = server.requests()
    XCTAssertEqual(requests.count, 2)
    let ranged = try XCTUnwrap(requests.last).lowercased()
    XCTAssertTrue(ranged.contains("range: bytes="), ranged)
    XCTAssertFalse(ranged.contains("range: bytes=0-"), ranged)
  }

  func testPartDigestMismatchKeepsEarlierVerifiedPart() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    var responses = fixture.responses
    let tampered = fixture.artifact.parts[1]
    responses[tampered.sourceURL] = Data(
      repeating: 0x21,
      count: Int(tampered.expectedSizeBytes)
    )
    let downloader = RoutedFixtureDownloader(responses: responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.parts[0].fileName]
    )
  }

  func testWholeDigestMismatchKeepsVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let decoy = Data(repeating: 0x7a, count: data.count)
    let fixture = try partsFixture(data: data, wholeDigest: digest(decoy))
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      fixture.artifact.parts.map(\.fileName).sorted()
    )
  }

  func testAssembledPayloadIsReusedWithoutRedownloadingParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(fixture.artifact, in: directory)
    try Data("stale part".utf8).write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )
    let replay = try await stager.stage(fixture.artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )
  }

  func testExistingVerifiedPartIsNotDownloadedAgain() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try fixture.chunks[0].write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(requestedURLs, [fixture.artifact.parts[1].sourceURL])
  }

  func testConflictingExistingPartFailsClosedBeforeDownload() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x33, count: Int(fixture.artifact.parts[0].expectedSizeBytes))
      .write(
        to: directory.appendingPathComponent(
          fixture.artifact.parts[0].fileName
        )
      )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(fixture.artifact.parts[0].fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testOversizedDeliveryIsRejectedAndStagesNothing() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data + Data("overfeed".utf8)
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count + 8)
        )
      )
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testSingleFileStagingReportsDownloadThenVerifiedProgress() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    _ = try await VerifiedArtifactStager(downloader: downloader).stage(
      artifact,
      in: directory,
      progress: recorder.handler
    )

    let events = recorder.events
    XCTAssertEqual(events.first?.phase, .downloading)
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(events.last?.totalBytes, UInt64(data.count))
    XCTAssertTrue(events.allSatisfy { $0.partIndex == nil && $0.partCount == nil })
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
  }

  func testRequiredFreeBytesIsTwiceThePayloadSize() {
    XCTAssertEqual(VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100), 200)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: UInt64.max), UInt64.max)
  }

  func testRequiredFreeBytesOnResumeCountsVerifiedPartsAlreadyOnDisk() {
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 80),
      120)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 200),
      0)
    XCTAssertEqual(
      VerifiedArtifactStager.requiredFreeBytes(forPayloadSize: 100, alreadyOnDisk: 0),
      200)
  }

  func testMatchesHashesTheOnDiskFile() throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(artifact.fileName)
    try data.write(to: file)
    XCTAssertTrue(VerifiedArtifactStager().matches(artifact, at: file))
    try Data(repeating: 0x61, count: data.count).write(to: file)
    XCTAssertFalse(VerifiedArtifactStager().matches(artifact, at: file))
  }

  func testDownloadTaskCancelsWhenTheSwiftTaskIsCancelled() async throws {
    let server = try SlowHTTPServer()
    let url = try await server.start()
    defer { server.stop() }
    let downloader = ProgressReportingArtifactDownloader()
    let download = Task {
      try await downloader.download(
        from: url, expectedSizeBytes: 50_000_000, onBytes: nil)
    }
    try await Task.sleep(for: .milliseconds(250))
    download.cancel()
    do {
      _ = try await download.value
      XCTFail("cancelled download must not succeed")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  private func descriptor(
    source: String = "https://example.com/installer.tar.gz",
    fileName: String = "installer.tar.gz",
    digest: String? = nil,
    data: Data = Data("pinned installer payload".utf8),
    parts: [PinnedArtifactPart] = []
  ) throws -> PinnedInstallerArtifact {
    try PinnedInstallerArtifact(
      role: "payload",
      sourceURL: URL(string: source)!,
      fileName: fileName,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count),
      parts: parts
    )
  }

  private func part(
    _ data: Data,
    index: Int = 0,
    fileName: String? = nil,
    source: String? = nil,
    digest: String? = nil
  ) throws -> PinnedArtifactPart {
    let name = fileName ?? String(format: "installer.tar.gz.part%02d", index)
    return try PinnedArtifactPart(
      sourceURL: URL(string: source ?? "https://example.com/\(name)")!,
      fileName: name,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count)
    )
  }

  private func partsFixture(
    data: Data,
    count: Int = 2,
    fileName: String = "installer.tar.gz",
    wholeDigest: String? = nil
  ) throws -> (
    artifact: PinnedInstallerArtifact, chunks: [Data], responses: [URL: Data]
  ) {
    let chunks = partition(data, into: count)
    var parts = [PinnedArtifactPart]()
    var responses = [URL: Data]()
    for (index, chunk) in chunks.enumerated() {
      let part = try self.part(chunk, index: index)
      parts.append(part)
      responses[part.sourceURL] = chunk
    }
    let artifact = try descriptor(
      fileName: fileName,
      digest: wholeDigest ?? digest(data),
      data: data,
      parts: parts
    )
    return (artifact, chunks, responses)
  }

  private func partition(_ data: Data, into count: Int) -> [Data] {
    let chunkSize = data.count / count
    var chunks = [Data]()
    var offset = 0
    for index in 0..<count {
      let length = index == count - 1 ? data.count - offset : chunkSize
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }
    return chunks
  }

  private func digest(_ data: Data) -> String {
    "sha256:"
      + SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-stager-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
  }
}

private actor FixtureArtifactDownloader: ArtifactDownloading {
  private let data: Data
  private(set) var downloadCount = 0

  init(data: Data) {
    self.data = data
  }

  func download(from sourceURL: URL) async throws -> URL {
    downloadCount += 1
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-downloader-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

private actor RoutedFixtureDownloader: ArtifactDownloading {
  private let responses: [URL: Data]
  private(set) var downloadCount = 0
  private(set) var requestedURLs = [URL]()

  init(responses: [URL: Data]) {
    self.responses = responses
  }

  func download(from sourceURL: URL) async throws -> URL {
    try await download(
      from: sourceURL,
      expectedSizeBytes: UInt64.max,
      onBytes: nil
    )
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    guard let data = responses[sourceURL] else {
      throw URLError(.fileDoesNotExist)
    }
    downloadCount += 1
    requestedURLs.append(sourceURL)
    if let onBytes {
      onBytes(UInt64(data.count / 2))
      onBytes(UInt64(data.count))
    }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-routed-download-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

/// Answers each part after a short wait and records how many were in flight.
private actor ConcurrentFixtureDownloader: ArtifactDownloading {
  private let responses: [URL: Data]
  private let failing: URL?
  private(set) var downloadCount = 0
  private(set) var mostInFlight = 0
  private var inFlight = 0

  init(responses: [URL: Data], failing: URL? = nil) {
    self.responses = responses
    self.failing = failing
  }

  func download(from sourceURL: URL) async throws -> URL {
    try await download(from: sourceURL, expectedSizeBytes: UInt64.max, onBytes: nil)
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    guard let data = responses[sourceURL] else { throw URLError(.fileDoesNotExist) }
    downloadCount += 1
    inFlight += 1
    mostInFlight = max(mostInFlight, inFlight)
    defer { inFlight -= 1 }
    // The failing part answers first; the others are still in flight.
    try await Task.sleep(for: .milliseconds(sourceURL == failing ? 50 : 300))
    onBytes?(UInt64(data.count))
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-concurrent-download-\(UUID().uuidString.lowercased())")
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

/// Serves `image`, dropping the first connection after `dropAfter` body bytes,
/// and answers a ranged request with the rest.
private final class ResumingHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let image: Data
  private let dropAfter: Int
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var received: [String] = []
  private var startContinuation: CheckedContinuation<URL, any Error>?

  init(image: Data, dropAfter: Int) throws {
    listener = try NWListener(using: .tcp, on: .any)
    self.image = image
    self.dropAfter = dropAfter
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { startContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = self.listener.port else { return }
          self.resumeStart(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/payload.bin")!))
        case .failed(let error):
          self.resumeStart(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: .global())
        self.readRequest(connection, buffered: Data())
      }
      listener.start(queue: .global())
    }
  }

  private func readRequest(_ connection: NWConnection, buffered: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, _, error in
      guard let self, error == nil, let data else { return }
      let request = buffered + data
      guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
        self.readRequest(connection, buffered: request)
        return
      }
      let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
      let first = self.lock.withLock {
        self.received.append(head)
        return self.received.count == 1
      }
      self.respond(head, first: first, on: connection)
    }
  }

  private func respond(_ head: String, first: Bool, on connection: NWConnection) {
    let total = image.count
    let validators =
      "Accept-Ranges: bytes\r\nETag: \"fixture\"\r\n"
      + "Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT\r\n"
    let range = head.lowercased().components(separatedBy: "\r\n").first {
      $0.hasPrefix("range: bytes=")
    }
    if let range, let start = Int(range.dropFirst("range: bytes=".count).prefix { $0 != "-" }),
      start < total
    {
      let header =
        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(total - 1)/\(total)\r\n"
        + "Content-Length: \(total - start)\r\n\(validators)Connection: close\r\n\r\n"
      connection.send(
        content: Data(header.utf8) + image[start...],
        completion: .contentProcessed { _ in connection.cancel() })
      return
    }
    let header =
      "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\n\(validators)Connection: close\r\n\r\n"
    let body = first ? image.prefix(dropAfter) : image[...]
    connection.send(
      content: Data(header.utf8) + body,
      completion: .contentProcessed { _ in
        // Closing before the declared length is a lost connection.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
          connection.cancel()
        }
      })
  }

  func requests() -> [String] { lock.withLock { received } }

  func stop() {
    let pending = lock.withLock { () -> [NWConnection] in
      let current = connections
      connections.removeAll()
      return current
    }
    for connection in pending { connection.cancel() }
    listener.cancel()
  }

  private func resumeStart(_ result: Result<URL, any Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
      let value = startContinuation
      startContinuation = nil
      return value
    }
    pending?.resume(with: result)
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = [ArtifactStagingProgress]()

  var events: [ArtifactStagingProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  var handler: ArtifactStagingProgressHandler {
    { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
    }
  }
}

private func assertThrows<T>(
  _ expression: @autoclosure () async throws -> T,
  handler: (any Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    handler(error)
  }
}

private final class SlowHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var startContinuation: CheckedContinuation<URL, any Error>?

  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { startContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = self.listener.port else { return }
          self.resumeStart(
            .success(URL(string: "http://127.0.0.1:\(port.rawValue)/payload.bin")!))
        case .failed(let error):
          self.resumeStart(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: .global())
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 50000000\r\n\r\n".utf8)
        connection.send(content: header, completion: .contentProcessed { _ in })
      }
      listener.start(queue: .global())
    }
  }

  func stop() {
    let pending = lock.withLock { () -> [NWConnection] in
      let current = connections
      connections.removeAll()
      return current
    }
    for connection in pending {
      connection.cancel()
    }
    listener.cancel()
  }

  private func resumeStart(_ result: Result<URL, any Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
      let value = startContinuation
      startContinuation = nil
      return value
    }
    pending?.resume(with: result)
  }
}
