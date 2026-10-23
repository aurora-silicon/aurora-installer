#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeStubFileTests: XCTestCase, @unchecked Sendable {
    final class ReadGate: @unchecked Sendable {
      private let lock = NSLock()
      private var blocked = false
      func close() { lock.withLock { blocked = true } }
      func check() throws {
        guard !lock.withLock({ blocked }) else { throw NativeStubFileError.invalidImage }
      }
    }
    struct Vectors: Decodable {
      struct Vector: Decodable {
        let name: String
        let archive: Data
        let success: Bool
      }
      let vectors: [Vector]
      let expectedManifest: Data
      let expectedVersion: [String: String]
      let recoveryBytes: Int
      let recoverySHA256: String
    }
    struct Source: FirmwareRangeReading {
      let bytes: Data
      var gate: ReadGate? = nil
      var sizeBytes: Int { bytes.count }
      func read(offset: Int, count: Int) async throws -> Data {
        try Task.checkCancellation()
        try gate?.check()
        return bytes.subdata(in: offset..<(offset + count))
      }
    }
    func vectors() throws -> Vectors {
      try JSONDecoder().decode(
        Vectors.self,
        from: Data(
          contentsOf: XCTUnwrap(
            Bundle.module.url(
              forResource: "native-stub-files", withExtension: "json", subdirectory: "Fixtures"))))
    }
    func root() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return root
    }
    func plan(_ vector: Vectors.Vector) async throws -> NativeStubFilePlan {
      let archive = try await IPSWArchive.open(Source(bytes: vector.archive))
      return try await NativeStubFilePlan(
        archive: archive,
        source: NativeFirmwareSelection(
          version: "26.6.2", sourceURL: URL(string: "https://updates.cdn-apple.com/test.ipsw")!,
          stubBytes: 6_000_000_000),
        deviceClass: "j700ap", boardID: 1, chipID: 2)
    }
    func testRestorePlanMatchesTheLockedSourceOracleAndNormalizesItsFallback() async throws {
      let fixture = try vectors()
      for vector in fixture.vectors {
        if !vector.success {
          do {
            _ = try await plan(vector)
            XCTFail("Unsafe restore path admitted")
          } catch {}
          continue
        }
        let result = try await plan(vector)
        XCTAssertEqual(result.restorePath, "Restore")
        let native =
          try PropertyListSerialization.propertyList(from: result.manifest, format: nil)
          as! NSDictionary
        let expected =
          try PropertyListSerialization.propertyList(from: fixture.expectedManifest, format: nil)
          as! NSDictionary
        XCTAssertEqual(native, expected)
        XCTAssertEqual(
          try PropertyListSerialization.propertyList(from: result.systemVersion, format: nil)
            as? [String: String], fixture.expectedVersion)
        XCTAssertFalse(
          result.copies.contains { $0.member == "excluded.img" || $0.member == "recovery.dmg" })
        XCTAssertTrue(
          result.copies.contains {
            $0.member == "kernelcache.fixture" && $0.installerDataName == "kernelcache.fixture"
          })
      }
    }
    func testFrameworkLinksAreAdmittedBeforeWritesAndResumeWithoutFollowingThem() async throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let vector = try XCTUnwrap(vectors().vectors.first { $0.name == "links" })
      let source = try await plan(vector)
      XCTAssertEqual(source.linkTargets.count, 3)
      for member in source.archive.members where member.isSymbolicLink {
        do {
          _ = try await source.archive.read(member, maximumBytes: 4096)
          XCTFail("Generic extraction followed a link")
        } catch {}
      }
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: source, owner: geteuid(), platform: fixture.platform, cache: nil)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      let receipt =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf: URL(
              fileURLWithPath:
                fixture.journal.path + ".native-stub-files.evidence"))) as! [String: Any]
      let entries = receipt["files"] as! [[String: Any]]
      XCTAssertFalse(entries.contains { ($0["path"] as! String).hasSuffix("Demo.framework/Demo") })
      let linkReceipt =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf: URL(
              fileURLWithPath:
                fixture.journal.path + ".native-stub-links.evidence"))) as! [String: Any]
      XCTAssertEqual((linkReceipt["targets"] as! [String: String]).count, 3)
      XCTAssertEqual(linkReceipt["plan_digest"] as? String, fixture.approved.planDigest)
      let link = fixture.mounts.appendingPathComponent(
        "disk8s3/"
          + (fixture.snapshot.containers.first {
            $0.volumes.contains { $0.identifier == "disk8s3" }
          }!.volumes.first { $0.roles == ["System"] }!.group!)
          + "/Restore/Bootability/Demo.framework/Demo")
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
        "Versions/Current/Demo")
      XCTAssertEqual(try Data(contentsOf: link), Data("synthetic framework executable".utf8))
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
      do {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
        XCTFail("Changed link was adopted")
      } catch {}
    }

    func testOptInLiveRestorePlanAdmitsEverySelectedRecordWithoutDiskWrites() async throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_STUB_PLAN"] == "1" else {
        throw XCTSkip("Explicit live restore-plan probe only")
      }
      let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["AURORA_LIVE_STUB_URL"])
      let url = try XCTUnwrap(URL(string: raw))
      let reader = try await IPSWHTTPRangeReader.discover(url: url)
      let archive = try await IPSWArchive.open(reader)
      let facts = try NativeFirmwareSelection.Facts.live()
      let result = try await NativeStubFilePlan(
        archive: archive,
        source: NativeFirmwareSelection(
          version: "26.6.2", sourceURL: url, stubBytes: 6_000_000_000),
        deviceClass: "j700ap", boardID: NativeStubFilePlatform.live.boardID(),
        chipID: facts.hardware.chipID)
      XCTAssertGreaterThan(result.copies.count, 5)
      XCTAssertEqual(result.linkTargets.count, 3)
      print(
        "Live restore plan admitted: \(result.copies.count) files, \(result.linkTargets.count) links"
      )
    }

    func testNativePreparationRetryRequiresExactCompletedAPFSCheckpointAndOwnerEvidence() throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let source = try JSONSerialization.data(
        withJSONObject: [
          "plan_digest": fixture.approved.planDigest,
          "bootstrap": fixture.bootstrap.configuration,
        ], options: [.sortedKeys])
      try fixture.writeEvidence(source, name: "native-source-owner")
      let bytes = try Data(contentsOf: fixture.journal)
      func eligible(_ data: Data, changed: String? = nil) -> Bool {
        PinnedAsahiEngineExecutor.nativeDiskPreparationRetryEligible(
          transcript: data,
          planDigest: fixture.approved.planDigest,
          deviceIdentifier: fixture.package.deviceIdentifier,
          storeIdentifier: fixture.package.storeIdentifier,
          evidence: { identifier in
            if changed == identifier { return Data("changed".utf8) }
            return try Data(
              contentsOf: URL(
                fileURLWithPath: fixture.journal.path + "." + identifier + ".evidence"))
          })
      }
      XCTAssertTrue(eligible(bytes))
      for identifier in ["apfs-target-prepared", "native-stub-volumes", "native-source-owner"] {
        XCTAssertFalse(eligible(bytes, changed: identifier))
      }
      let ambiguous = Data(bytes.split(separator: 10).prefix(4).flatMap { Array($0) + [10] })
      XCTAssertFalse(eligible(ambiguous))
      XCTAssertFalse(
        PinnedAsahiEngineExecutor.nativeDiskPreparationRetryEligible(
          transcript: bytes,
          planDigest: String(repeating: "0", count: 64),
          deviceIdentifier: fixture.package.deviceIdentifier,
          storeIdentifier: fixture.package.storeIdentifier, evidence: { _ in source }))
    }

    func testOnlyTheJournalThatCreatedAPartialStartupContainerProvesIt() throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let container = fixture.snapshot.containers[1]
      let stub = try XCTUnwrap(
        fixture.snapshot.partitions.first { $0.uuid == container.storeUUID })
      let original = try Data(contentsOf: fixture.journal)
      func created(
        _ part: RemovalPartition, snapshot: RemovalSnapshot? = nil, transcript: Data? = nil,
        changed: String? = nil
      ) -> Bool {
        NativeRemovalInstallJournals.created(
          part, transcript: transcript ?? original,
          snapshot: snapshot ?? fixture.snapshot,
          evidence: { identifier in
            if identifier == changed { return Data("changed".utf8) }
            return try Data(
              contentsOf: URL(
                fileURLWithPath: fixture.journal.path + "." + identifier + ".evidence"))
          })
      }
      XCTAssertTrue(created(stub))
      // Another partition, changed evidence, changed volumes or a journal that
      // went further prove nothing.
      let macOS = try XCTUnwrap(
        fixture.snapshot.partitions.first { $0.uuid == fixture.snapshot.macOSStoreUUID })
      XCTAssertFalse(created(macOS))
      for identifier in ["apfs-target-prepared", NativeStubVolumes.evidenceIdentifier] {
        XCTAssertFalse(created(stub, changed: identifier), identifier)
      }
      var renamed = fixture.snapshot
      renamed.containers[1] = RemovalContainer(
        uuid: container.uuid, storeUUID: container.storeUUID,
        volumes: container.volumes.map {
          RemovalVolume(
            uuid: $0.uuid, name: $0.name + " 2", roles: $0.roles, group: $0.group,
            identifier: $0.identifier)
        })
      XCTAssertFalse(created(stub, snapshot: renamed))
      let started = try JSONSerialization.data(
        withJSONObject: [
          "schema_version": 1, "sequence": 6, "type": "event",
          "payload": ["plan_digest": fixture.approved.planDigest, "name": "stub_and_esp_started"],
        ], options: [.sortedKeys])
      XCTAssertTrue(created(stub, transcript: original + started + Data([10])))
      let unfinished = Data(original.split(separator: 10).prefix(4).flatMap { Array($0) + [10] })
      XCTAssertFalse(created(stub, transcript: unfinished))

      // The installer's working directory holds the journal; one held by a
      // running process proves nothing.
      let working = fixture.directory.appendingPathComponent("working")
      let journals = working.appendingPathComponent("execution-journals")
      for path in [working, journals] {
        try FileManager.default.createDirectory(
          at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      let name = fixture.journal.lastPathComponent
      for suffix in ["", ".apfs-target-prepared.evidence", ".native-stub-volumes.evidence"] {
        let copy = journals.appendingPathComponent(name + suffix)
        try FileManager.default.copyItem(
          at: URL(fileURLWithPath: fixture.journal.path + suffix), to: copy)
      }
      let source = NativeRemovalInstallJournals(workingDirectory: working, owner: geteuid())
      XCTAssertEqual(
        try source.creator(of: stub, in: fixture.snapshot), String(name.dropLast(6)))
      XCTAssertNil(try source.creator(of: macOS, in: fixture.snapshot))
      let held = open(journals.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(held, 0)
      defer { close(held) }
      XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
      XCTAssertNil(try source.creator(of: stub, in: fixture.snapshot))
    }

    func testSavedRestoreImageIsVerifiedWithoutDownloadingItAgain() async throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let vector = try XCTUnwrap(vectors().vectors.first { $0.name == "aea" })
      let gate = ReadGate()
      let archive = try await IPSWArchive.open(Source(bytes: vector.archive, gate: gate))
      let source = try await NativeStubFilePlan(
        archive: archive,
        source: NativeFirmwareSelection(
          version: "26.6.2", sourceURL: URL(string: "https://updates.cdn-apple.com/test.ipsw")!,
          stubBytes: 6_000_000_000),
        deviceClass: "j700ap", boardID: 1, chipID: 2)
      var platform = fixture.platform
      platform.decode = { _, _, output, _, _ in
        var bytes = Data(repeating: 0x69, count: 131072 + 13)
        bytes.append(Data("koly".utf8))
        bytes.append(Data(repeating: 0, count: 508))
        try bytes.write(to: output)
      }
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: source, owner: geteuid(), platform: platform, cache: nil)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      gate.close()
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
    }

    func testNativeResourceForkCompressionRoundTripsThroughTheFilesystem() async throws {
      let fixture = try vectors()
      let source = try await plan(XCTUnwrap(fixture.vectors.first))
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = try NativeStubFileStore(
        tree: NativeHandoffFileTree(directory, protected: true, owner: geteuid()), owner: geteuid())
      let result = try await store.member(
        source.recoveryMember, archive: source.archive, at: "Recovery/image.dmg", compressed: true)
      XCTAssertEqual(result.bytes, fixture.recoveryBytes)
      XCTAssertEqual(result.sha256, fixture.recoverySHA256)
      let path = directory.appendingPathComponent("Recovery/image.dmg")
      let bytes = try Data(contentsOf: path)
      XCTAssertEqual(bytes.count, fixture.recoveryBytes)
      XCTAssertEqual(
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), fixture.recoverySHA256
      )
      var info = stat()
      XCTAssertEqual(lstat(path.path, &info), 0)
      XCTAssertNotEqual(info.st_flags & UInt32(UF_COMPRESSED), 0)
      let repeated = try await store.member(
        source.recoveryMember, archive: source.archive, at: "Recovery/image.dmg", compressed: true)
      XCTAssertEqual(repeated, result)
    }
    func testCompleteNativeStubFilesResumeWithoutReplayingDiskWorkAndRetainOriginalOwner()
      async throws
    {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      // Neo's source Preboot group is root-owned mode 0777.
      XCTAssertEqual(
        chmod(
          fixture.mounts.appendingPathComponent("disk4s3/" + fixture.bootstrap.groupUUID).path,
          0o777), 0)
      let vector = try XCTUnwrap(vectors().vectors.first)
      let source = try await plan(vector)
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: source, owner: geteuid(), platform: fixture.platform, cache: nil)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      let path = URL(fileURLWithPath: fixture.journal.path + ".native-stub-files.evidence")
      let receipt = try Data(contentsOf: path)
      let before = try Data(contentsOf: fixture.journal)
      XCTAssertEqual(before.split(separator: 10).count, 5)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      XCTAssertEqual(try Data(contentsOf: path), receipt)
      XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
      let version = fixture.mounts.appendingPathComponent(
        "disk8s1/System/Library/CoreServices/SystemVersion.plist")
      try Data("corrupt".utf8).write(to: version)
      do {
        try await execution.prepare(
          journal: fixture.journal, authorization: fixture.authorization,
          sourceBootstrap: fixture.bootstrap)
        XCTFail("Changed completed file was adopted")
      } catch {}
    }

    func testInterruptedDecodePublicationIsRetiredBeforeTheSameOperationRetries() async throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let vector = try XCTUnwrap(vectors().vectors.first { $0.name == "aea" })
      let source = try await plan(vector)
      let stale = fixture.directory.appendingPathComponent(
        "native-stub-decode-" + fixture.approved.planDigest)
      try FileManager.default.createDirectory(
        at: stale, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try Data("interrupted output".utf8).write(to: stale.appendingPathComponent("output.dmg"))
      var platform = fixture.platform
      platform.decode = { _, _, output, _, _ in
        guard !FileManager.default.fileExists(atPath: output.path) else {
          throw NativeStubFileError.changedFile
        }
        var bytes = Data(repeating: 0x69, count: 131072 + 13)
        bytes.append(Data("koly".utf8))
        bytes.append(Data(repeating: 0, count: 508))
        try bytes.write(to: output)
      }
      let execution = NativeStubFilesExecution(
        package: fixture.package, approved: fixture.approved,
        plan: source, owner: geteuid(), platform: platform, cache: nil)
      try await execution.prepare(
        journal: fixture.journal, authorization: fixture.authorization,
        sourceBootstrap: fixture.bootstrap)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    actor CountingSource: FirmwareRangeReading {
      nonisolated let sizeBytes = 65536
      var calls = 0
      func read(offset: Int, count: Int) async throws -> Data {
        calls += 1
        return Data(repeating: 0x31, count: count)
      }
      func count() -> Int { calls }
    }

    func testRangeCacheDeduplicatesConcurrentReadsAndRejectsChangedRetainedBytes() async throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let source = CountingSource()
      let location = directory.appendingPathComponent("cache")
      let cache = try NativeStubRestoreCache(
        source: source, root: location, owner: geteuid(), identity: Data("source-identity".utf8))
      async let first = cache.read(offset: 0, count: 65536)
      async let second = cache.read(offset: 0, count: 65536)
      let results = try await [first, second]
      XCTAssertEqual(results[0], results[1])
      let count = await source.count()
      XCTAssertEqual(count, 1)
      try Data(repeating: 0x32, count: 65536).write(
        to: location.appendingPathComponent("0-65536.bin"))
      do {
        _ = try await cache.read(offset: 0, count: 65536)
        XCTFail("Corrupt cache accepted")
      } catch {}
      try await cache.retire()
      XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    func testRestoreCacheOutlivesAFailedAttemptAndServesTheNextOne() async throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let identity = Data(#"{"bytes":65536,"url":"image","version":"26.6.2"}"#.utf8)
      let location = NativeStubRestoreCache.root(in: directory, identity: identity)
      XCTAssertTrue(location.lastPathComponent.hasPrefix(NativeStubRestoreCache.prefix))
      let first = CountingSource()
      let failed = try NativeStubRestoreCache(
        source: first, root: location, owner: geteuid(), identity: identity)
      let bytes = try await failed.read(offset: 0, count: 65536)
      // The attempt fails here; the next one has a new plan but the same image.
      NativeStubRestoreCache.prune(
        in: directory, keeping: (location, identity), owner: geteuid(), freeBytes: { _ in 0 })
      let second = CountingSource()
      let next = try NativeStubRestoreCache(
        source: second, root: location, owner: geteuid(), identity: identity)
      let reused = try await next.read(offset: 0, count: 65536)
      XCTAssertEqual(reused, bytes)
      let downloads = await second.count()
      XCTAssertEqual(downloads, 0)
      try await next.retire()
      XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    func testRestoreCachesArePrunedByAgeKindAndSpace() throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = Date()
      let identity = Data("current".utf8)
      let current = NativeStubRestoreCache.root(in: directory, identity: identity)
      func cache(_ name: String, daysAgo: Double, identity: Data? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let identity {
          try identity.write(to: url.appendingPathComponent("identity.json"))
          chmod(url.appendingPathComponent("identity.json").path, 0o600)
        }
        try FileManager.default.setAttributes(
          [.modificationDate: now.addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
        return url
      }
      let plan = try cache(NativeStubRestoreCache.planPrefix + "plan", daysAgo: 0)
      let stale = try cache(NativeStubRestoreCache.prefix + "stale", daysAgo: 8)
      let recent = try cache(NativeStubRestoreCache.prefix + "recent", daysAgo: 1)
      let older = try cache(NativeStubRestoreCache.prefix + "older", daysAgo: 2)
      _ = try cache(current.lastPathComponent, daysAgo: 30, identity: identity)
      let unrelated = try cache("native-stub-decode-plan", daysAgo: 30)
      func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

      NativeStubRestoreCache.prune(
        in: directory, keeping: (current, identity), owner: geteuid(), now: now,
        freeBytes: { _ in 100 << 30 })
      XCTAssertFalse(exists(plan), "Plan-keyed caches are never reused")
      XCTAssertFalse(exists(stale))
      XCTAssertTrue(exists(recent))
      XCTAssertTrue(exists(older))
      XCTAssertTrue(exists(current), "The image being installed keeps its cache at any age")
      XCTAssertTrue(exists(unrelated))

      // Low space removes other images' caches, least recently used first.
      var free: UInt64 = 1 << 30
      NativeStubRestoreCache.prune(
        in: directory, keeping: (current, identity), owner: geteuid(), now: now,
        freeBytes: { _ in
          defer { free += 20 << 30 }
          return free
        })
      XCTAssertFalse(exists(older))
      XCTAssertTrue(exists(recent))
      XCTAssertTrue(exists(current))

      // A cache under the current name for another identity is replaced.
      NativeStubRestoreCache.prune(
        in: directory, keeping: (current, Data("another".utf8)), owner: geteuid(), now: now,
        freeBytes: { _ in 100 << 30 })
      XCTAssertFalse(exists(current))

      // The helper's start-up pass applies the same age and kind rules.
      let left = try cache(NativeStubRestoreCache.planPrefix + "left", daysAgo: 0)
      RestoreImageCacheHousekeeping.run(in: directory)
      XCTAssertFalse(exists(left))
    }

    func testLiveNestedDecoderWorkspaceIsNeverRetired() throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let workspace = directory.appendingPathComponent(".omarchy-restore-Ab12Cd")
      try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let descriptor = open(
        workspace.appendingPathComponent(".lease").path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
        0o600)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { close(descriptor) }
      XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
      XCTAssertThrowsError(
        try NativeStubDecoder.requireInactiveWorkspaces(directory, owner: geteuid())
      ) {
        XCTAssertEqual($0 as? NativeRecoveryJournalError, .busy)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
      XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
      try NativeStubDecoder.requireInactiveWorkspaces(directory, owner: geteuid())
    }

    func testDecoderLeaseKeepsTheJournalLockedAfterTheSupervisorCloses() throws {
      let fixture = try ExecutionFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      var journal: NativeInstallJournalFile? = try NativeInstallJournalFile(
        url: fixture.journal,
        package: fixture.package, owner: geteuid())
      let lease = try journal!.leaseForChild()
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/bin/sleep")
      child.arguments = ["0.3"]
      child.standardInput = lease
      try child.run()
      journal = nil
      try lease.close()
      XCTAssertThrowsError(
        try NativeInstallJournalFile(
          url: fixture.journal, package: fixture.package, owner: geteuid())
      ) {
        XCTAssertEqual($0 as? NativeRecoveryJournalError, .busy)
      }
      child.waitUntilExit()
      _ = try NativeInstallJournalFile(
        url: fixture.journal, package: fixture.package, owner: geteuid())
    }

    final class ExecutionFixture: @unchecked Sendable {
      let directory: URL, mounts: URL, journal: URL
      let package: ImportedEngineHandoffPackage
      let approved: ValidatedEnginePlan
      let snapshot: RemovalSnapshot
      let bootstrap: NativeSourceBootstrap
      let authorization: MachineOwnerAuthorization
      init(deviceIdentifier: String = "apple,j700") throws {
        let file = try XCTUnwrap(
          Bundle.module.url(
            forResource: "native-handoff-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let vector = (doc["vectors"] as! [[String: Any]])[0]
        var snapshot = try JSONDecoder().decode(
          RemovalSnapshot.self, from: JSONSerialization.data(withJSONObject: vector["snapshot"]!))
        let old = snapshot.containers[1]
        snapshot.containers[1] = RemovalContainer(
          uuid: old.uuid, storeUUID: old.storeUUID,
          volumes: old.volumes.map {
            RemovalVolume(
              uuid: $0.uuid, name: $0.roles == ["Data"] ? "System - Data" : $0.name,
              roles: $0.roles, group: $0.group, identifier: $0.identifier)
          })
        self.snapshot = snapshot
        let lines = (vector["transcript"] as! String).split(separator: "\n").prefix(5)
        var transcript = Data((lines.joined(separator: "\n") + "\n").utf8)
        if deviceIdentifier != "apple,j700" {
          var messages = try transcript.split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
          }
          var plan = messages[2]["payload"] as! [String: Any]
          plan["device_identifier"] = deviceIdentifier
          let decoder = JSONDecoder()
          decoder.keyDecodingStrategy = .convertFromSnakeCase
          let admitted = try decoder.decode(
            EnginePlanMessage.self, from: JSONSerialization.data(withJSONObject: plan))
          for index in messages.indices {
            var payload = messages[index]["payload"] as! [String: Any]
            if payload["device_identifier"] != nil {
              payload["device_identifier"] = deviceIdentifier
            }
            if payload["plan_digest"] != nil {
              payload["plan_digest"] = admitted.computedPlanDigest
            }
            messages[index]["payload"] = payload
          }
          transcript = try messages.reduce(into: Data()) {
            $0.append(try JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]))
            $0.append(10)
          }
        }
        approved = try XCTUnwrap(
          AppleInstallerTrustCore().validateEngineTranscript(transcript).plan)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mounts = directory.appendingPathComponent("mounts")
        for path in [directory, mounts] {
          try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        for container in snapshot.containers {
          for volume in container.volumes {
            try FileManager.default.createDirectory(
              at: mounts.appendingPathComponent(volume.identifier),
              withIntermediateDirectories: false,
              attributes: [.posixPermissions: 0o755])
          }
        }
        let journals = directory.appendingPathComponent("journals")
        try FileManager.default.createDirectory(
          at: journals, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binding = "sha256:" + String(repeating: "b", count: 64)
        journal = journals.appendingPathComponent(String(repeating: "b", count: 64) + ".jsonl")
        try transcript.write(to: journal)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let imported = directory.appendingPathComponent("imported")
        try FileManager.default.createDirectory(
          at: imported, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        package = ImportedEngineHandoffPackage(
          packageURL: imported, manifestURL: imported.appendingPathComponent("manifest.json"),
          requestURL: imported.appendingPathComponent("request.json"),
          identityURL: imported.appendingPathComponent("identity.json"),
          engineURL: imported.appendingPathComponent("engine.tar.gz"),
          metadataURL: imported.appendingPathComponent("metadata.json"),
          payloadURL: imported.appendingPathComponent("payload.zip"),
          restoreImageURL: imported.appendingPathComponent("decoder"),
          bindingDigest: binding, planDigest: approved.planDigest,
          deviceIdentifier: approved.deviceIdentifier, storeIdentifier: approved.storeIdentifier)
        let source = snapshot.containers[0].volumes.first { $0.roles == ["System"] }!
        bootstrap = try NativeSourceBootstrap(
          systemUUID: source.uuid, groupUUID: source.group!,
          ownerUUID: vector["ownerUUID"] as! String)
        authorization = try MachineOwnerAuthorization(
          username: "mina", password: Data("synthetic".utf8))
        let admin = mounts.appendingPathComponent("disk4s3/" + bootstrap.groupUUID + "/var/db")
        try FileManager.default.createDirectory(
          at: admin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PropertyListSerialization.data(
          fromPropertyList: ["mina": ["GeneratedUID": bootstrap.ownerUUID, "RealName": "Mina"]],
          format: .xml, options: 0
        )
        .write(to: admin.appendingPathComponent("AdminUserRecoveryInfo.plist"))
        let target = snapshot.partitions.first { $0.uuid == old.storeUUID }!
        let evidence = try NativeAPFSTargetEvidence(plan: approved.planDigest, partition: target)
          .bytes
        try writeEvidence(evidence, name: "apfs-target-prepared")
        if deviceIdentifier != "apple,j700" {
          var messages = try transcript.split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
          }
          var checkpoint = messages[4]["payload"] as! [String: Any]
          checkpoint["evidence_digest"] = SHA256Digest(hashing: evidence).rawValue
          messages[4]["payload"] = checkpoint
          transcript = try messages.reduce(into: Data()) {
            $0.append(try JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]))
            $0.append(10)
          }
          try transcript.write(to: journal)
        }
        let volumes = NativeStubVolumes(
          planDigest: approved.planDigest, partitionUUID: target.uuid,
          containerUUID: old.uuid, label: "System", volumes: snapshot.containers[1].volumes)
        try writeEvidence(volumes.bytes, name: NativeStubVolumes.evidenceIdentifier)
      }
      func writeEvidence(_ bytes: Data, name: String) throws {
        let path = URL(fileURLWithPath: journal.path + "." + name + ".evidence")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }
      var platform: NativeStubFilePlatform {
        let environment = NativeHandoffEnvironment(
          snapshot: { self.snapshot }, device: { self.package.deviceIdentifier },
          command: { executable, arguments in
            XCTAssertEqual(executable, "/usr/sbin/diskutil")
            var result = [String: Any]()
            if arguments[0] == "apfs" {
              XCTAssertEqual(arguments[1], "listUsers")
              result = [
                "Users": [["APFSCryptoUserUUID": self.bootstrap.ownerUUID, "VolumeOwner": true]]
              ]
            } else {
              XCTAssertEqual(arguments.prefix(2), ["info", "-plist"])
              let name = arguments[2]
              if name == "/" {
                result = [
                  "APFSVolumeGroupID": self.bootstrap.groupUUID, "APFSContainerReference": "disk4",
                ]
              } else {
                let containers = self.snapshot.containers
                let volume = try XCTUnwrap(
                  containers.flatMap(\.volumes).first { $0.identifier == name || $0.uuid == name })
                result = [
                  "VolumeUUID": volume.uuid,
                  "MountPoint": self.mounts.appendingPathComponent(volume.identifier).path,
                  "WritableVolume": true,
                  "APFSContainerReference": volume.identifier.hasPrefix("disk4")
                    ? "disk4" : "disk8",
                ]
                if let group = volume.group { result["APFSVolumeGroupID"] = group }
              }
            }
            return try PropertyListSerialization.data(
              fromPropertyList: result, format: .xml, options: 0)
          }, ownerUUID: { _ in self.bootstrap.ownerUUID },
          rawDigest: { _, _ in throw NativeStubFileError.invalidPlan },
          verifyRecovery: { _, _ in }, owner: geteuid(), mountRoot: mounts,
          sourcePrebootMount: mounts.appendingPathComponent("disk4s3"), verifyMount: { _, _, _ in })
        return NativeStubFilePlatform(
          environment: environment, boardID: { 1 }, configureSystem: { _ in },
          protectAdmin: { _ in },
          decode: { _, _, _, _, _ in throw NativeStubFileError.invalidImage })
      }
    }

    func testAtomicPublicationPreservesConflictsAndRejectsLinksAndResumesOwnedTemps() async throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = try NativeStubFileStore(
        tree: NativeHandoffFileTree(directory, protected: true, owner: geteuid()), owner: geteuid())
      let bytes = Data("approved".utf8)
      _ = try await store.data(bytes, at: "System/file")
      do {
        _ = try await store.data(Data("conflict".utf8), at: "System/file")
        XCTFail("Existing contents overwritten")
      } catch {}
      XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("System/file")), bytes)
      try FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent("unsafe").path, withDestinationPath: "/tmp")
      do {
        _ = try await store.data(bytes, at: "unsafe/file")
        XCTFail("Linked parent admitted")
      } catch {}
      do {
        _ = try await store.data(bytes, at: "../escape")
        XCTFail("Traversal admitted")
      } catch {}
      let temporary = ".aurora-stub-" + NativeStubFileStore.hash(Data("native-stub:resumed".utf8))
      try Data("interrupted".utf8).write(to: directory.appendingPathComponent(temporary))
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(temporary).path)
      _ = try await store.data(bytes, at: "resumed")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(temporary).path))
      XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("resumed")), bytes)
    }
  }
#endif
