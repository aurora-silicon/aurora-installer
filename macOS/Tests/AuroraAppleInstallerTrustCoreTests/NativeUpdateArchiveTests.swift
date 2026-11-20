#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// The stub stage on an OTA update archive, the only form Apple ships
  /// macOS 14.8.3 in: the firmware every M3 Mac needs.
  final class NativeUpdateArchiveTests: XCTestCase, @unchecked Sendable {
    struct Vectors: Decodable {
      struct Vector: Decodable {
        let name: String
        let archive: Data
      }
      let vectors: [Vector]
      let expectedManifest: Data
      let recoveryBytes: Int
      let recoverySHA256: String
      let recoverySHA1: String

      func archive(_ name: String) throws -> Data {
        try XCTUnwrap(vectors.first { $0.name == name }).archive
      }
    }

    static func vectors() throws -> Vectors {
      try JSONDecoder().decode(
        Vectors.self,
        from: Data(
          contentsOf: XCTUnwrap(
            Bundle.module.url(
              forResource: "native-update-archive", withExtension: "json",
              subdirectory: "Fixtures"))))
    }

    /// The sealed policy's 14.8.3 source.
    static func updateArchive() throws -> URL {
      let entry = try XCTUnwrap(
        NativeInspectionPolicy.sealed().firmware.first { $0.version == "14.8.3" })
      return try XCTUnwrap(URL(string: entry.sourceURL))
    }

    static func selection(_ url: URL) -> NativeFirmwareSelection {
      NativeFirmwareSelection(version: "14.8.3", sourceURL: url, stubBytes: 2_499_805_184)
    }

    func plan(
      _ archive: Data, url: URL? = nil, gate: NativeStubFileTests.ReadGate? = nil,
      admitRecords: Bool = true
    ) async throws -> NativeStubFilePlan {
      try await NativeStubFilePlan(
        archive: IPSWArchive.open(NativeStubFileTests.Source(bytes: archive, gate: gate)),
        source: Self.selection(url ?? Self.updateArchive()),
        deviceClass: "j613ap", boardID: 0x30, chipID: 0x8122, admitRecords: admitRecords)
    }

    func testTheSealedPolicysM3SourceIsAnUpdateArchive() throws {
      XCTAssertEqual(NativeRestoreSourceLayout(sourceURL: try Self.updateArchive()), .updateArchive)
      for entry in try NativeInspectionPolicy.sealed().firmware where entry.version != "14.8.3" {
        XCTAssertEqual(
          NativeRestoreSourceLayout(sourceURL: try XCTUnwrap(URL(string: entry.sourceURL))),
          .restoreImage, entry.version)
      }
      for other in [
        "https://updates.cdn-apple.com/a/InstallAssistant.pkg",
        "https://updates.cdn-apple.com/a/other.zip",
      ] {
        XCTAssertNil(NativeRestoreSourceLayout(sourceURL: try XCTUnwrap(URL(string: other))))
      }
    }

    func testAnUpdateArchivePlanSelectsItsUpdateIdentityAndCopiesTheRestoreImagesFiles()
      async throws
    {
      let fixture = try Self.vectors()
      let plan = try await plan(fixture.archive("full"))
      XCTAssertEqual(plan.layout, .updateArchive)
      XCTAssertEqual(plan.restorePath, "Restore")
      XCTAssertEqual(
        try PropertyListSerialization.propertyList(from: plan.manifest, format: nil)
          as? NSDictionary,
        try PropertyListSerialization.propertyList(from: fixture.expectedManifest, format: nil)
          as? NSDictionary)
      let copies = Dictionary(uniqueKeysWithValues: plan.copies.map { ($0.path, $0) })
      // Every file lands where a restore image's would.
      for (path, member) in [
        ("usr/standalone/bootcaches.plist", "AssetData/boot/usr/standalone/bootcaches.plist"),
        (
          "System/Library/CoreServices/PlatformSupport.plist",
          "AssetData/boot/PlatformSupport.plist"
        ),
        ("Restore/SystemVersion.plist", "AssetData/boot/SystemVersion.plist"),
        ("Restore/RestoreVersion.plist", "AssetData/boot/RestoreVersion.plist"),
        ("Restore/kernelcache.release.mac15g", "AssetData/boot/kernelcache.release.mac15g"),
        (
          "Restore/Firmware/all_flash/iBoot.j613.RELEASE.im4p",
          "AssetData/boot/Firmware/all_flash/iBoot.j613.RELEASE.im4p"
        ),
        ("Restore/Firmware/AOP/aopfw.im4p", "AssetData/boot/Firmware/AOP/aopfw.im4p"),
        (
          "Restore/apticket.j613ap.im4m",
          "AssetData/boot/Firmware/Manifests/restore/macOS Customer Software Update/"
            + "apticket.j613ap.im4m"
        ),
        (
          "Restore/Bootability/Bootability.trustcache",
          "AssetData/Restore/BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache"
        ),
        (
          "Restore/Bootability/BootabilityBrain.framework/Versions/A/BootabilityBrain",
          "AssetData/Restore/BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/"
            + "Versions/A/BootabilityBrain"
        ),
      ] {
        XCTAssertEqual(copies[path]?.member, member, path)
      }
      XCTAssertEqual(
        copies["Restore/kernelcache.release.mac15g"]?.installerDataName,
        "kernelcache.release.mac15g")
      XCTAssertEqual(
        copies["Restore/RestoreVersion.plist"]?.installerDataName, "RestoreVersion.plist")
      // The erase identity's files, the excluded components and the update
      // archive's own files stay out.
      for member in plan.copies.map(\.member) {
        XCTAssertFalse(member.contains("decoy") || member.contains("excluded"), member)
        XCTAssertFalse(member.hasPrefix("AssetData/payloadv2"), member)
        XCTAssertFalse(member.hasSuffix(".dmg"), member)
      }
      XCTAssertEqual(plan.linkTargets.count, 3)
      XCTAssertEqual(plan.recoveryMember.name, NativeRestoreSourceLayout.updateRecoveryMember)
      XCTAssertEqual(plan.recoveryImage?.outputBytes, fixture.recoveryBytes)
      XCTAssertEqual(
        plan.recoveryImage?.sha1.map { String(format: "%02x", $0) }.joined(),
        fixture.recoverySHA1)
      let info = try XCTUnwrap(
        JSONSerialization.jsonObject(with: plan.stubInfo) as? [String: Any])
      let manifestInfo = try XCTUnwrap(info["manifest_info"] as? [String: String])
      XCTAssertEqual(manifestInfo["variant"], "macOS Customer Software Update")
      XCTAssertEqual(manifestInfo["build_number"], "23J220")
      XCTAssertEqual(
        (info["system_version"] as? [String: String])?["ProductUserVisibleVersion"],
        "14.8.3 (stub)")
      // A space estimate selects the same files without admitting records.
      let estimate = try await self.plan(fixture.archive("full"), admitRecords: false)
      XCTAssertEqual(estimate.copies, plan.copies)
      XCTAssertEqual(estimate.recoveryImage, plan.recoveryImage)
    }

    func testFirmwareCollectionFollowsTheUpdateIdentity() async throws {
      let plan = try await plan(Self.vectors().archive("full"))
      let source = try NativeFirmwareSourcePlan(manifest: plan.manifest)
      XCTAssertEqual(source.machine, "j613")
      XCTAssertEqual(source.kernel, "kernelcache.release.mac15g")
      XCTAssertEqual(
        source.fud,
        [NativeFirmwareSourcePlan.FUD(component: "AOP", member: "Firmware/AOP/aopfw.im4p")])
    }

    func testAnArchiveMustHaveTheLayoutItsURLNames() async throws {
      let update = try Self.vectors().archive("full")
      let restore = try XCTUnwrap(
        JSONDecoder().decode(
          NativeStubFileTests.Vectors.self,
          from: Data(
            contentsOf: XCTUnwrap(
              Bundle.module.url(
                forResource: "native-stub-files", withExtension: "json",
                subdirectory: "Fixtures")))
        ).vectors.first { $0.name == "fallback" }
      ).archive
      let restoreURL = try XCTUnwrap(URL(string: "https://updates.cdn-apple.com/test.ipsw"))
      do {
        _ = try await plan(update, url: restoreURL)
        XCTFail("An update archive was read as a restore image")
      } catch {
        XCTAssertEqual(error as? NativeStubFileError, .invalidPlan)
      }
      do {
        _ = try await plan(restore)
        XCTFail("A restore image was read as an update archive")
      } catch {
        XCTAssertEqual(error as? NativeStubFileError, .invalidPlan)
      }
      do {
        _ = try await plan(
          update, url: URL(string: "https://updates.cdn-apple.com/a/InstallAssistant.pkg"))
        XCTFail("An unknown kind of source was planned")
      } catch {
        XCTAssertEqual(error as? NativeFirmwareSelectionError, .invalidSource)
      }
    }

    func testAnUpdateArchiveThatPatchesAnEarlierImageIsRefusedByName() async throws {
      // A delta header, and archives that also lack the whole image, the
      // Bootability bundle or the BaseSystem entry: each is named as an
      // update archive the stub can't use, not as a failed verification.
      for name in ["delta", "no-image", "delta-incomplete"] {
        do {
          _ = try await plan(Self.vectors().archive(name))
          XCTFail("\(name): an update archive without a whole Recovery image was planned")
        } catch {
          XCTAssertEqual(
            error as? NativeFirmwareSelectionError, .updateArchiveOnly(version: "14.8.3"), name)
        }
      }
    }

    func recoveryPath(_ fixture: NativeStubFileTests.ExecutionFixture) -> URL {
      let volumes = fixture.snapshot.containers[1].volumes
      let recovery = volumes.first { $0.roles == ["Recovery"] }!
      let group = volumes.first { $0.roles == ["System"] }!.group!
      return fixture.mounts.appendingPathComponent(
        recovery.identifier + "/" + group + "/usr/standalone/firmware/arm64eBaseSystem.dmg")
    }

    func restorePath(_ fixture: NativeStubFileTests.ExecutionFixture, _ path: String) -> URL {
      let volumes = fixture.snapshot.containers[1].volumes
      let preboot = volumes.first { $0.roles == ["Preboot"] }!
      let group = volumes.first { $0.roles == ["System"] }!.group!
      return fixture.mounts.appendingPathComponent(
        preboot.identifier + "/" + group + "/Restore/" + path)
    }

    func testAnUpdateArchiveStubInstallsAndResumesWithoutReadingTheArchiveAgain() async throws {
      let vectors = try Self.vectors()
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let gate = NativeStubFileTests.ReadGate()
      let plan = try await plan(vectors.archive("full"), gate: gate)
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: plan, owner: geteuid(), platform: fixture.platform, cache: nil)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)

      // The Recovery image is the decoded image, compressed on the volume.
      let recovery = recoveryPath(fixture)
      let image = try Data(contentsOf: recovery)
      XCTAssertEqual(image.count, vectors.recoveryBytes)
      XCTAssertEqual(
        SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined(),
        vectors.recoverySHA256)
      var info = stat()
      XCTAssertEqual(lstat(recovery.path, &info), 0)
      XCTAssertNotEqual(info.st_flags & UInt32(UF_COMPRESSED), 0)

      // The restore directory holds the update identity's files.
      XCTAssertEqual(
        try Data(contentsOf: restorePath(fixture, "kernelcache.release.mac15g")),
        Data("synthetic update kernel".utf8))
      XCTAssertEqual(
        try Data(contentsOf: restorePath(fixture, "apticket.j613ap.im4m")),
        Data("update restore manifest".utf8))
      XCTAssertEqual(
        try Data(contentsOf: restorePath(fixture, "BuildManifest.plist")), plan.manifest)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: restorePath(fixture, "Bootability/BootabilityBrain.framework/BootabilityBrain")
            .path), "Versions/Current/BootabilityBrain")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: restorePath(fixture, "decoy.im4m").path))

      let receiptURL = URL(fileURLWithPath: fixture.journal.path + ".native-stub-files.evidence")
      let receipt = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
      XCTAssertEqual(receipt["firmware_version"] as? String, "14.8.3")
      XCTAssertEqual(receipt["source_url"] as? String, try Self.updateArchive().absoluteString)
      let files = try XCTUnwrap(receipt["files"] as? [[String: Any]])
      XCTAssertTrue(
        files.contains {
          ($0["path"] as? String)?.hasSuffix("usr/standalone/firmware/arm64eBaseSystem.dmg")
            == true
            && (($0["identity"] as? [String: Any])?["sha256"] as? String)
              == vectors.recoverySHA256
        })

      // A completed stage reads nothing from the archive again.
      gate.close()
      let saved = try Data(contentsOf: receiptURL)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      XCTAssertEqual(try Data(contentsOf: receiptURL), saved)
    }

    func testARecoveryImageThatFailsItsSHA1IsNeverPublished() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let plan = try await plan(Self.vectors().archive("corrupt"))
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: plan, owner: geteuid(), platform: fixture.platform, cache: nil)
      do {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
        XCTFail("A corrupt Recovery image was published")
      } catch {
        XCTAssertTrue(error is RestoreFailure, "\(error)")
      }
      let recovery = recoveryPath(fixture)
      XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
      let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: recovery.deletingLastPathComponent().path)
      XCTAssertEqual(leftovers, [])
    }

    func testTheStagingRequirementCountsTheUpdateArchivesOwnReads() async throws {
      let plan = try await plan(Self.vectors().archive("full"), admitRecords: false)
      let decoded = try await NativeStubStagingRequirement.decodedMembers(of: plan)
      XCTAssertEqual(decoded, [])
      let names = [
        "AssetData/boot/BuildManifest.plist", "AssetData/boot/usr/standalone/bootcaches.plist",
        "AssetData/boot/SystemVersion.plist",
      ]
      let planning = plan.archive.members.filter { names.contains($0.name) }
      XCTAssertEqual(planning.count, 3)
      let requirement = NativeStubStagingRequirement(
        plan: plan, decoded: [], includingPlanningReads: true)
      XCTAssertEqual(
        requirement.cacheBytes,
        NativeStubStagingRequirement.cacheBytes(
          reading: (plan.readMembers + planning).map(NativeStubStagingRequirement.Read.init))
          + NativeStubStagingRequirement.directoryBytes)
      XCTAssertEqual(requirement.largestDecodeBytes, 0)
      XCTAssertTrue(plan.readMembers.contains(plan.recoveryMember))
    }

    func testARecoveryImageWithoutAUDIFTrailerIsNeverPublished() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let plan = try await plan(Self.vectors().archive("no-trailer"))
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: plan, owner: geteuid(), platform: fixture.platform, cache: nil)
      do {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
        XCTFail("A Recovery image without a UDIF trailer was published")
      } catch {
        XCTAssertEqual(error as? NativeStubFileError, .invalidImage)
      }
      let recovery = recoveryPath(fixture)
      XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          atPath: recovery.deletingLastPathComponent().path), [])
    }

    /// Answers reads from memory, and runs `action` once, on the first read
    /// inside `span` after it is armed.
    final class BodyRead: @unchecked Sendable {
      private let lock = NSLock()
      private var span: Range<Int>?
      private var action: (() throws -> Void)?

      func arm(_ span: Range<Int>, action: @escaping () throws -> Void) {
        lock.withLock {
          self.span = span
          self.action = action
        }
      }

      func check(offset: Int) throws {
        let action: (() throws -> Void)? = lock.withLock {
          guard let span, span.contains(offset) else { return nil }
          defer { self.action = nil }
          return self.action
        }
        try action?()
      }
    }

    struct Source: FirmwareRangeReading {
      let bytes: Data
      let body: BodyRead
      var sizeBytes: Int { bytes.count }
      func read(offset: Int, count: Int) async throws -> Data {
        try Task.checkCancellation()
        try body.check(offset: offset)
        return bytes.subdata(in: offset..<(offset + count))
      }
    }

    /// Cancels a task, also when asked before the task is known.
    final class Canceller: @unchecked Sendable {
      private let lock = NSLock()
      private var task: Task<Void, Error>?
      private var requested = false

      func set(_ task: Task<Void, Error>) {
        lock.withLock {
          self.task = task
          if requested { task.cancel() }
        }
      }

      func cancel() {
        lock.withLock {
          requested = true
          task?.cancel()
        }
      }
    }

    func testThePaddedStage1NeedsRoomBesideWhatTheStubRestores() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let archive = try Self.vectors().archive("full")
      func plan(stubBytes: UInt64) async throws -> NativeStubFilePlan {
        try await NativeStubFilePlan(
          archive: IPSWArchive.open(NativeStubFileTests.Source(bytes: archive)),
          source: NativeFirmwareSelection(
            version: "14.8.3", sourceURL: Self.updateArchive(), stubBytes: stubBytes),
          deviceClass: "j613ap", boardID: 0x30, chipID: 0x8122)
      }
      let probe = try await plan(stubBytes: 2_499_805_184)
      // The Recovery image counts as it is decoded, as the plan's size limit counts it.
      let recovery = try XCTUnwrap(probe.recoveryImage)
      XCTAssertNotEqual(recovery.outputBytes, probe.recoveryMember.sizeBytes)
      let sizes = Dictionary(
        probe.archive.members.map { ($0.name, UInt64($0.sizeBytes)) },
        uniquingKeysWith: { first, _ in first })
      let restored = probe.copies.reduce(UInt64(recovery.outputBytes)) {
        $0 + sizes[$1.member]!
      }
      XCTAssertEqual(probe.estimatedStubBytes, restored)
      let expanded: UInt64 = 153_190_400
      let needed = restored + NativeEnrollmentSpace.recoveryDataBytes + expanded
      for stub in [needed, needed - 1] {
        let execution = NativeStubFilesExecution(
          package: fixture.package, approved: fixture.approved,
          plan: try await plan(stubBytes: stub), owner: geteuid(), platform: fixture.platform,
          cache: nil)
        if stub == needed {
          XCTAssertNoThrow(try execution.requireRoom(forExpandedStage1: expanded))
        } else {
          XCTAssertThrowsError(try execution.requireRoom(forExpandedStage1: expanded)) {
            XCTAssertEqual(
              $0 as? NativeStubFileError, .noRoomForStage1(requiredBytes: needed, stubBytes: stub))
          }
        }
      }
    }

    /// An execution over the full vector whose Recovery member body read
    /// can be intercepted.
    func interceptable(_ fixture: NativeStubFileTests.ExecutionFixture) async throws -> (
      execution: NativeStubFilesExecution, body: BodyRead, span: Range<Int>
    ) {
      let body = BodyRead()
      let plan = try await NativeStubFilePlan(
        archive: IPSWArchive.open(Source(bytes: Self.vectors().archive("full"), body: body)),
        source: Self.selection(Self.updateArchive()),
        deviceClass: "j613ap", boardID: 0x30, chipID: 0x8122)
      let start = try await plan.archive.dataOffset(for: plan.recoveryMember)
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: plan, owner: geteuid(), platform: fixture.platform, cache: nil)
      return (execution, body, start..<(start + plan.recoveryMember.compressedSize))
    }

    func assertRecoveryInstalled(
      _ fixture: NativeStubFileTests.ExecutionFixture, file: StaticString = #filePath,
      line: UInt = #line
    ) throws {
      let recovery = recoveryPath(fixture)
      XCTAssertEqual(
        SHA256.hash(data: try Data(contentsOf: recovery)).map { String(format: "%02x", $0) }
          .joined(), try Self.vectors().recoverySHA256, file: file, line: line)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          atPath: recovery.deletingLastPathComponent().path), [recovery.lastPathComponent],
        file: file, line: line)
    }

    func testCancellingDuringTheDecodePublishesNothingAndTheStageResumes() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let (execution, body, span) = try await interceptable(fixture)
      let canceller = Canceller()
      body.arm(span) { canceller.cancel() }
      let task = Task {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
      }
      canceller.set(task)
      do {
        try await task.value
        XCTFail("A cancelled decode completed")
      } catch {
        XCTAssertTrue(error is CancellationError, "\(error)")
      }
      let recovery = recoveryPath(fixture)
      XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          atPath: recovery.deletingLastPathComponent().path), [])
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      try assertRecoveryInstalled(fixture)
    }

    func testAnInterruptedDecodeIsRedoneFromTheStart() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let (execution, body, span) = try await interceptable(fixture)
      body.arm(span) { throw URLError(.networkConnectionLost) }
      do {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
        XCTFail("An interrupted decode completed")
      } catch {
        XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")
      }
      // A helper that stopped mid-decode leaves its private partial file.
      let recovery = recoveryPath(fixture)
      let group = fixture.snapshot.containers[1].volumes.first { $0.roles == ["System"] }!.group!
      let partial = recovery.deletingLastPathComponent().appendingPathComponent(
        ".aurora-stub-"
          + NativeStubFileStore.hash(
            Data(
              (fixture.approved.planDigest + ":" + group
                + "/usr/standalone/firmware/arm64eBaseSystem.dmg").utf8)))
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: partial.path, contents: Data(repeating: 0x72, count: 4096),
          attributes: [.posixPermissions: 0o600]))
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      try assertRecoveryInstalled(fixture)
    }

    func testAnImagePublishedBeforeItsReceiptIsAdoptedOnResume() async throws {
      let fixture = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let (execution, _, _) = try await interceptable(fixture)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      func evidence(_ identifier: String) -> URL {
        URL(fileURLWithPath: fixture.journal.path + "." + identifier + ".evidence")
      }
      let receipt = try Data(contentsOf: evidence("native-stub-files"))
      // Roll the stage back to the moment the image was published: its
      // receipt, and everything after it, never written.
      var index = 0
      while FileManager.default.fileExists(atPath: evidence("native-stub-file-\(index)").path) {
        let saved = try JSONDecoder().decode(
          NativeStubFilesExecution.Installed.self,
          from: Data(contentsOf: evidence("native-stub-file-\(index)")))
        if saved.path.hasSuffix("usr/standalone/firmware/arm64eBaseSystem.dmg") { break }
        index += 1
      }
      let first = index
      while FileManager.default.fileExists(atPath: evidence("native-stub-file-\(index)").path) {
        let saved = try JSONDecoder().decode(
          NativeStubFilesExecution.Installed.self,
          from: Data(contentsOf: evidence("native-stub-file-\(index)")))
        if index > first {
          let volume = fixture.snapshot.containers[1].volumes.first { $0.roles == [saved.role] }!
          try FileManager.default.removeItem(
            at: fixture.mounts.appendingPathComponent(volume.identifier + "/" + saved.path))
        }
        try FileManager.default.removeItem(at: evidence("native-stub-file-\(index)"))
        index += 1
      }
      XCTAssertGreaterThan(index, first + 1)
      for identifier in ["native-stub-files", "native-stub-links"] {
        try FileManager.default.removeItem(at: evidence(identifier))
      }
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      try assertRecoveryInstalled(fixture)
      XCTAssertEqual(try Data(contentsOf: evidence("native-stub-files")), receipt)
    }

    /// What the restore cache keeps once the stage has run, against what
    /// planning counted for it: the count must never fall short.
    func cachedAndPlanned(
      _ archive: Data, url: URL, fixture: NativeStubFileTests.ExecutionFixture,
      deviceClass: String, boardID: UInt64, chipID: UInt64
    ) async throws -> (kept: UInt64, planned: UInt64, largestBody: UInt64) {
      let root = fixture.directory.appendingPathComponent("cache")
      let reader = try NativeStubRestoreCache(
        source: NativeStubFileTests.Source(bytes: archive), root: root, owner: geteuid(),
        identity: NativeStubRestoreCache.identity(url: url, bytes: archive.count))
      let plan = try await NativeStubFilePlan(
        archive: IPSWArchive.open(reader),
        source: NativeFirmwareSelection(
          version: url.pathExtension == "ipsw" ? "26.6.2" : "14.8.3", sourceURL: url,
          stubBytes: 0),
        deviceClass: deviceClass, boardID: boardID, chipID: chipID)
      let planned = NativeStubStagingRequirement(
        plan: plan, decoded: try await NativeStubStagingRequirement.decodedMembers(of: plan),
        includingPlanningReads: true
      ).cacheBytes
      try await NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: plan, owner: geteuid(), platform: fixture.platform, cache: reader
      ).prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasSuffix(".bin") }
        .reduce(UInt64(0)) { total, name in
          let size =
            try FileManager.default.attributesOfItem(
              atPath: root.appendingPathComponent(name).path)[.size] as! NSNumber
          return total + size.uint64Value
        }
      return (kept, planned, UInt64(plan.readMembers.map(\.compressedSize).max() ?? 0))
    }

    func testTheCacheKeepsNoMoreThanPlanningCountedForEitherLayout() async throws {
      let update = try NativeStubFileTests.ExecutionFixture(deviceIdentifier: "apple,j613")
      defer { try? FileManager.default.removeItem(at: update.directory) }
      let archive = try await cachedAndPlanned(
        Self.vectors().archive("full"), url: Self.updateArchive(), fixture: update,
        deviceClass: "j613ap", boardID: 0x30, chipID: 0x8122)
      let restore = try NativeStubFileTests.ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: restore.directory) }
      let image = try await cachedAndPlanned(
        XCTUnwrap(
          JSONDecoder().decode(
            NativeStubFileTests.Vectors.self,
            from: Data(
              contentsOf: XCTUnwrap(
                Bundle.module.url(
                  forResource: "native-stub-files", withExtension: "json",
                  subdirectory: "Fixtures")))
          ).vectors.first { $0.name == "fallback" }
        ).archive, url: XCTUnwrap(URL(string: "https://updates.cdn-apple.com/test.ipsw")),
        fixture: restore, deviceClass: "j700ap", boardID: 1, chipID: 2)
      for (name, result) in [("update archive", archive), ("restore image", image)] {
        // Each fixture has a member of 64 KiB or more, which the cache keeps
        // as read rather than in shared windows.
        XCTAssertGreaterThanOrEqual(result.largestBody, 65_536, name)
        XCTAssertGreaterThanOrEqual(result.kept, result.largestBody, name)
        XCTAssertLessThanOrEqual(result.kept, result.planned, name)
      }
    }

    // MARK: Apple's archive

    /// Every M3 Mac the sealed policy lists for 14.8.3, with the board and
    /// chip its identity names in the 14.8.3 manifest. The 15-inch M3 MacBook
    /// Air (J615) takes the pinned macOS 27.2 stub instead.
    static let m3Boards: [(device: String, board: UInt64, chip: UInt64)] = [
      ("j433", 0x28, 0x8122), ("j434", 0x2a, 0x8122), ("j504", 0x22, 0x8122),
      ("j613", 0x30, 0x8122), ("j514s", 0x04, 0x6030),
      ("j514c", 0x44, 0x6031), ("j514m", 0x44, 0x6034), ("j516s", 0x06, 0x6030),
      ("j516c", 0x46, 0x6031), ("j516m", 0x46, 0x6034),
    ]

    /// Plans every M3 Mac's stub from Apple's 14.8.3 update archive, admitting
    /// every record it would read, without writing anything.
    func testOptInLiveUpdateArchivePlansEveryM3Mac() async throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_UPDATE_ARCHIVE"] == "1" else {
        throw XCTSkip("Explicit live update-archive probe only")
      }
      let url = try Self.updateArchive()
      let source = try await IPSWHTTPRangeReader.discover(url: url)
      XCTAssertEqual(source.sizeBytes, 13_637_436_385)
      let archive = try await IPSWArchive.open(NativeWindowedRangeReader(source))
      let policy = try NativeInspectionPolicy.sealed()
      let listed = try XCTUnwrap(policy.firmware.first { $0.version == "14.8.3" }?.models)
      XCTAssertEqual(Set(listed), Set(Self.m3Boards.map(\.device)))
      for (device, board, chip) in Self.m3Boards {
        let started = Date()
        let plan = try await NativeStubFilePlan(
          archive: archive, source: Self.selection(url), deviceClass: device + "ap",
          boardID: board, chipID: chip)
        XCTAssertEqual(plan.recoveryImage?.outputBytes, 2_149_321_569, device)
        XCTAssertEqual(
          plan.recoveryImage?.sha1.map { String(format: "%02x", $0) }.joined(),
          "ba320b14b89b3108320b6f3d970affed90c1fee7", device)
        XCTAssertEqual(plan.linkTargets.count, 3, device)
        let firmware = try NativeFirmwareSourcePlan(manifest: plan.manifest)
        XCTAssertEqual(firmware.machine, device, device)
        XCTAssertTrue(plan.copies.contains { $0.path == "Restore/" + firmware.kernel }, device)
        print(
          "Live 14.8.3 \(device): \(plan.copies.count) files, \(firmware.fud.count) FUD, "
            + "planned in \(Date().timeIntervalSince(started)) s")
      }
    }

    /// Decodes the 14.8.3 Recovery image from Apple's archive into a private
    /// directory the way the stub stage does, compressed, and checks it. Then
    /// reads the firmware the vendor stage takes from it and from the M3
    /// kernels, with the stage's own parsers.
    func testOptInLiveUpdateArchiveRecoveryImageDecodes() async throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_UPDATE_ARCHIVE_DECODE"] == "1" else {
        throw XCTSkip("Explicit live update-archive decode only (about 565 MB)")
      }
      let url = try Self.updateArchive()
      let archive = try await IPSWArchive.open(IPSWHTTPRangeReader.discover(url: url))
      let plan = try await NativeStubFilePlan(
        archive: archive, source: Self.selection(url), deviceClass: "j613ap", boardID: 0x30,
        chipID: 0x8122)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = try NativeStubFileStore(
        tree: NativeHandoffFileTree(directory, protected: true, owner: geteuid()),
        owner: geteuid())
      let started = Date()
      let identity = try await store.updateImage(
        plan.recoveryMember, image: XCTUnwrap(plan.recoveryImage), archive: plan.archive,
        at: "arm64eBaseSystem.dmg", compressed: true)
      let elapsed = Date().timeIntervalSince(started)
      XCTAssertEqual(identity.bytes, 2_149_321_569)
      // Measured 2026-11-02; the decoder has already matched Apple's SHA-1.
      XCTAssertEqual(
        identity.sha256, "0f26d213aef5a7c3db095be45b633e2eadabdd94d48557c58375c6d3b6b45bf3")
      let image = directory.appendingPathComponent("arm64eBaseSystem.dmg")
      let handle = try FileHandle(forReadingFrom: image)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(identity.bytes - 512))
      XCTAssertEqual(try handle.read(upToCount: 4), Data("koly".utf8))
      var info = stat()
      XCTAssertEqual(lstat(image.path, &info), 0)
      XCTAssertNotEqual(info.st_flags & UInt32(UF_COMPRESSED), 0)
      print(
        "Live 14.8.3 Recovery image: \(identity.sha256) in \(elapsed) s, "
          + "\(Int(info.st_blocks) * 512) bytes allocated")

      // The vendor stage attaches the image read-only and reads its radio
      // and camera firmware.
      let mounted = try NativeFirmwareMountedImage.open(image: image, parent: directory)
      try await NativeFirmwareMountedImage.withCleanup(mounted) {
        let tree = try NativeHandoffFileTree(
          mounted.root, protected: true, owner: 0, volumeRoot: true,
          volumeDevice: mounted.device, readOnlyVolume: true)
        let radio = try NativeFirmwareInputFiles.snapshot(
          root: mounted.root, prefix: "usr/share/firmware", tree: tree, owner: 0)
        func under(_ prefix: String) -> ([String: Data], [String: String]) {
          (
            Dictionary(
              uniqueKeysWithValues: radio.files.filter { $0.key.hasPrefix(prefix) }.map {
                (String($0.key.dropFirst(prefix.count)), $0.value)
              }),
            Dictionary(
              uniqueKeysWithValues: radio.links.filter {
                $0.key.hasPrefix(prefix) && $0.value.hasPrefix(prefix)
              }.map {
                (String($0.key.dropFirst(prefix.count)), String($0.value.dropFirst(prefix.count)))
              })
          )
        }
        let (wifiFiles, wifiLinks) = under("wifi/")
        let (bluetoothFiles, bluetoothLinks) = under("bluetooth/")
        let wifi = try BroadcomFirmware.wifi(wifiFiles, links: wifiLinks)
        let bluetooth = try BroadcomFirmware.bluetooth(bluetoothFiles, links: bluetoothLinks)
        XCTAssertFalse(wifi.isEmpty)
        XCTAssertFalse(bluetooth.isEmpty)
        var cameras = [String: Int]()
        for name in ["appleh13camerad", "appleh16camerad"] {
          let path = "usr/sbin/" + name
          guard try !tree.isAbsent(path) else { continue }
          let data = try tree.read(path, maximum: 16 << 20)
          cameras[name] = try NeoFirmwareConversions.camera(data, requireNeoSet: false).count
        }
        XCTAssertFalse(cameras.isEmpty)
        print(
          "Live 14.8.3 vendor firmware: \(wifi.count) Wi-Fi, \(bluetooth.count) Bluetooth, "
            + "cameras \(cameras)")
      }

      // Every M3 kernel decodes and yields its controller firmware.
      for name in ["mac15g", "mac15j", "mac15s"] {
        let member = try XCTUnwrap(
          archive.members.first { $0.name == "AssetData/boot/kernelcache.release." + name })
        let bytes = try await archive.read(member, maximumBytes: 64 << 20)
        let kernel = try FirmwareImage.decode(bytes)
        XCTAssertEqual(kernel.type, "krnl", name)
        let firmware = try FirmwareImage.controllerFirmware(in: kernel.bytes)
        print("Live 14.8.3 kernelcache.release.\(name): \(firmware.keys.sorted())")
      }
    }
  }
#endif
