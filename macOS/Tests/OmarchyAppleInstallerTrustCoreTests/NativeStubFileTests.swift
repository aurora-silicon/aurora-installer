#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeStubFileTests: XCTestCase, @unchecked Sendable {
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
      var sizeBytes: Int { bytes.count }
      func read(offset: Int, count: Int) async throws -> Data {
        try Task.checkCancellation()
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
