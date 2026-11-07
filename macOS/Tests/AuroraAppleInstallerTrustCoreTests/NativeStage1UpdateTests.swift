#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeStage1UpdateTests: XCTestCase, @unchecked Sendable {
    static let espUUID = "3CE364B1-1DE6-4418-A00D-5B2D95884AD7"
    static let binding = NativeStage1UpdateBinding(
      systemUUID: "11111111-1111-4111-8111-111111111111",
      groupUUID: "22222222-2222-4222-8222-222222222222",
      prebootUUID: "33333333-3333-4333-8333-333333333333", espUUID: espUUID, machO: true)

    /// This release's padded-window Stage 1 for the fixture ESP, as a fresh
    /// installation would make it.
    static func candidate(machO: Bool = true) async throws -> NativeStage1UpdateCandidate {
      let plan = try await NativeESPFileTests.plan()
      let raw = NativeMachOStage1Tests.loadable(plan.stage1)
      return try NativeStage1UpdateCandidate(
        stage1: raw, machO: machO ? NativeMachOStage1Tests.object(wrapping: raw) : nil,
        windowMilliseconds: 0, legacy: false, espUUID: espUUID)
    }

    static func json(_ value: [String: Any]) throws -> Data {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func configuration(
      _ binding: NativeStage1UpdateBinding = binding, mode: String = "macho",
      stage2Path: String = "m1n1/boot.bin", extra: [String: Any] = [:]
    ) throws -> Data {
      var value: [String: Any] = [
        "schema": 2, "volumeName": "Aurora Alarm", "systemUUID": binding.systemUUID,
        "groupUUID": binding.groupUUID, "prebootUUID": binding.prebootUUID,
        "espUUID": binding.espUUID, "bootMode": mode, "stage2Path": stage2Path,
        "bootstrap": NSNull(),
      ]
      value.merge(extra) { $1 }
      return try json(value)
    }

    static func identity(_ bytes: Data) -> [String: Any] {
      ["sha256": NativeStubFileStore.hash(bytes), "bytes": bytes.count]
    }

    /// An Alpha 17 Mach-O installation: an unpadded Stage 1 loading m1n1/boot.bin.
    static let earlierRaw = Data("earlier raw stage 1".utf8)
    static let earlierObject = Data("earlier unpadded Mach-O stage 1".utf8)
    static let stage2 = Data("standard stage 2".utf8)
    static let vendor: [String: Data] = [
      "vendorfw/firmware.tar": Data("tar".utf8), "vendorfw/firmware.cpio": Data("cpio".utf8),
      "vendorfw/manifest.txt": Data("manifest".utf8),
    ]

    static func payloadFiles() -> [String: Data] {
      vendor.merging([
        "raw/aura-raw.bin": earlierRaw, "raw/boot.bin": stage2,
        "macho/aura-boot.macho": earlierObject,
      ]) { $1 }
    }

    static func manifest(files: [String: Data] = payloadFiles(), mode: String = "macho")
      throws -> Data
    {
      try json([
        "schema": 2, "defaultMode": mode, "modes": [mode: ["espPath": "m1n1/boot.bin"]],
        "vendorFirmware": vendor.keys.sorted(), "files": files.mapValues(identity),
      ])
    }

    static func receipt(stage1: Data = earlierObject, stage2Path: String = "m1n1/boot.bin")
      throws -> Data
    {
      try json([
        "schema": 1, "status": "installed", "mode": "macho", "stage2Path": stage2Path,
        "stage1SHA256": NativeStubFileStore.hash(stage1),
        "stage2SHA256": NativeStubFileStore.hash(stage2), "recoveryAccountRequired": true,
      ])
    }

    static func records(
      configuration: Data? = nil, manifest: Data? = nil, receipt: Data? = nil
    ) throws -> NativeStage1UpdateRecords {
      try NativeStage1Update.records(
        configuration: configuration ?? Self.configuration(), manifest: manifest ?? Self.manifest(),
        receipt: receipt ?? Self.receipt(), pending: false, binding: binding)
    }

    // MARK: The new Stage 1

    func testTheCandidateIsWhatAFreshInstallationEnrollsForThisESP() async throws {
      let candidate = try await Self.candidate()
      XCTAssertEqual(candidate.mode, .macho)
      XCTAssertEqual(candidate.stage2Path, AuraStage1Format.confinedStage2Path)
      let configuration = try Stage1Configuration.read(candidate.raw)
      XCTAssertEqual(configuration.espUUID, Self.espUUID.lowercased())
      XCTAssertEqual(configuration.stage2Path, "m1n1/boot-ctxr.bin")
      let object = try XCTUnwrap(candidate.machO)
      try MachOBootObject.check(object)
      XCTAssertEqual(try Stage1Configuration.read(object).stage2Path, "m1n1/boot-ctxr.bin")
      XCTAssertEqual(candidate.enrolled, object)
      XCTAssertEqual(
        candidate.expandedBytes, try MachOBootObject.expandExecuteWindow(object).size)

      let raw = try await Self.candidate(machO: false)
      XCTAssertEqual(raw.mode, .raw)
      XCTAssertEqual(raw.stage2Path, AuraStage1Format.standardStage2Path)
      XCTAssertNil(raw.expandedBytes)
      XCTAssertEqual(raw.enrolled, raw.raw)
    }

    func testAnObjectThatIsTooLargeOrALegacyStage1IsRefused() async throws {
      let plan = try await NativeESPFileTests.plan()
      let huge = Data(count: NativeStage1UpdateCandidate.maximumBytes + 1)
      XCTAssertThrowsError(
        try NativeStage1UpdateCandidate(
          stage1: plan.stage1, machO: huge, windowMilliseconds: 0, legacy: false,
          espUUID: Self.espUUID)
      ) {
        XCTAssertEqual(
          $0 as? NativeStage1UpdateError, .stage1TooLarge(bytes: UInt64(huge.count)))
      }
      XCTAssertThrowsError(
        try NativeStage1UpdateCandidate(
          stage1: plan.stage1, machO: nil, windowMilliseconds: 0, legacy: true,
          espUUID: Self.espUUID)
      ) { XCTAssertEqual($0 as? NativeStage1UpdateError, .unsupportedStage1) }
      // An object that doesn't carry this Stage 1 fails the fresh-install check.
      XCTAssertThrowsError(
        try NativeStage1UpdateCandidate(
          stage1: NativeMachOStage1Tests.loadable(plan.stage1),
          machO: NativeMachOStage1Tests.object(wrapping: Data(repeating: 7, count: 0x1000)),
          windowMilliseconds: 0, legacy: false, espUUID: Self.espUUID)
      ) { XCTAssertEqual($0 as? NativeBootChainError, .invalidStage1) }
    }

    func testTheStartupVolumeMustHoldWhatRecoveryReads() async throws {
      let candidate = try await Self.candidate()
      let expanded = try XCTUnwrap(candidate.expandedBytes)
      let required =
        expanded + UInt64(candidate.raw.count + candidate.machO!.count)
        + NativeStage1Update.reserveBytes
      try NativeStage1Update.requireSpace(candidate, freeBytes: required)
      XCTAssertThrowsError(try NativeStage1Update.requireSpace(candidate, freeBytes: required - 1))
      {
        XCTAssertEqual(
          $0 as? NativeStage1UpdateError,
          .notEnoughSpace(requiredBytes: required, availableBytes: required - 1))
      }
      XCTAssertTrue(
        NativeStage1UpdateError.notEnoughSpace(requiredBytes: 160 << 20, availableBytes: 1 << 20)
          .summary.contains("needs 168 MB"))
    }

    func testTheESPMustAlreadyHoldTheStage2ItLoads() throws {
      let confined = AuraStage1Format.confinedStage2Path
      try NativeStage1Update.requireStage2(bytes: 1 << 20, path: confined)
      for bytes in [nil, 0, Int(ExecuteWindow.auraSlot) + 1] as [Int?] {
        XCTAssertThrowsError(try NativeStage1Update.requireStage2(bytes: bytes, path: confined)) {
          XCTAssertEqual($0 as? NativeStage1UpdateError, .missingStage2(path: confined))
        }
      }
      try NativeStage1Update.requireStage2(bytes: 20 << 20, path: "m1n1/boot.bin")
      XCTAssertTrue(
        NativeStage1UpdateError.missingStage2(path: confined).summary.contains(
          "install its updates"))
    }

    // MARK: Recognition

    func testARecognizedInstallationIsAcceptedIncludingAnEarlierMachOOne() throws {
      let records = try Self.records()
      XCTAssertEqual(records.stage2Path, "m1n1/boot.bin")
      XCTAssertEqual(records.volumeName, "Aurora Alarm")
      // The padded layout, a raw Mac, and the ESP UUID in either case are accepted too.
      _ = try Self.records(configuration: Self.configuration(stage2Path: "m1n1/boot-ctxr.bin"))
      let raw = NativeStage1UpdateBinding(
        systemUUID: Self.binding.systemUUID, groupUUID: Self.binding.groupUUID,
        prebootUUID: Self.binding.prebootUUID, espUUID: Self.espUUID.lowercased(), machO: false)
      var receipt =
        try JSONSerialization.jsonObject(with: Self.receipt()) as! [String: Any]
      receipt["mode"] = "raw"
      _ = try NativeStage1Update.records(
        configuration: Self.configuration(mode: "raw"), manifest: Self.manifest(mode: "raw"),
        receipt: Self.json(receipt), pending: false, binding: raw)
    }

    func testAChangedOrMismatchedInstallationIsNeverTouched() throws {
      let other = NativeStage1UpdateBinding(
        systemUUID: "44444444-4444-4444-8444-444444444444", groupUUID: Self.binding.groupUUID,
        prebootUUID: Self.binding.prebootUUID, espUUID: Self.espUUID, machO: true)
      let cases: [(Data, NativeStage1UpdateError, String)] = [
        (try Self.configuration(other), .changedInstallation, "another System volume"),
        (
          try Self.configuration(extra: ["espUUID": "55555555-5555-4555-8555-555555555555"]),
          .changedInstallation, "another ESP"
        ),
        (try Self.configuration(mode: "raw"), .wrongBootMode, "a raw installation on Mach-O"),
        (
          try Self.configuration(stage2Path: "m1n1/other.bin"), .changedInstallation,
          "an unknown Stage 2"
        ),
        (try Self.configuration(extra: ["unexpected": true]), .changedInstallation, "unknown key"),
        (Data("{".utf8), .changedInstallation, "unreadable"),
      ]
      for (configuration, expected, why) in cases {
        XCTAssertThrowsError(try Self.records(configuration: configuration), why) {
          XCTAssertEqual($0 as? NativeStage1UpdateError, expected, why)
        }
      }
      // A manifest without the Recovery baseline isn't an installation this made.
      XCTAssertThrowsError(try Self.records(manifest: Self.json(["schema": 2, "files": [:]]))) {
        XCTAssertEqual($0 as? NativeStage1UpdateError, .changedInstallation)
      }
      // Setup that Recovery hasn't finished is finished there first.
      for (receipt, pending) in [(nil, false), (try Self.receipt(), true)] as [(Data?, Bool)] {
        XCTAssertThrowsError(
          try NativeStage1Update.records(
            configuration: Self.configuration(), manifest: Self.manifest(), receipt: receipt,
            pending: pending, binding: Self.binding)
        ) { XCTAssertEqual($0 as? NativeStage1UpdateError, .setupUnfinished) }
      }
    }

    func testTheInstallationsVolumesComeFromItsOwnContainer() throws {
      func partition(_ id: String, _ uuid: String, _ type: String, _ offset: UInt64)
        -> RemovalPartition
      {
        RemovalPartition(
          identifier: id, uuid: uuid, type: type, offset: offset, size: 1 << 30, name: "")
      }
      let stub = partition("disk0s3", "AAAAAAAA-0000-4000-8000-000000000001", "Apple_APFS", 0)
      let target = NativePreservedInstallTarget(
        disk: "disk0", title: "Aurora Alarm", group: Self.binding.groupUUID, stub: stub,
        esp: partition("disk0s4", Self.espUUID, "EFI", 1 << 30),
        boot: partition(
          "disk0s5", "AAAAAAAA-0000-4000-8000-000000000003", "Linux Filesystem", 2 << 30),
        root: partition(
          "disk0s6", "AAAAAAAA-0000-4000-8000-000000000004", "Linux Filesystem", 3 << 30),
        identityDigest: "")
      func snapshot(_ volumes: [RemovalVolume]) -> RemovalSnapshot {
        RemovalSnapshot(
          disk: "disk0", devicePath: "/dev/disk0", diskSize: 1 << 40, macOSStoreUUID: "",
          macOSContainerUUID: "", partitions: [stub],
          containers: [RemovalContainer(uuid: "C", storeUUID: stub.uuid, volumes: volumes)])
      }
      let group = Self.binding.groupUUID
      let volumes = [
        RemovalVolume(
          uuid: Self.binding.systemUUID, name: "Aurora Alarm", roles: ["System"], group: group,
          identifier: "disk4s1"),
        RemovalVolume(
          uuid: "D", name: "Data", roles: ["Data"], group: group, identifier: "disk4s2"),
        RemovalVolume(
          uuid: Self.binding.prebootUUID, name: "Preboot", roles: ["Preboot"], identifier: "disk4s3"
        ),
      ]
      let found = try NativeStage1Update.volumes(target, snapshot: snapshot(volumes))
      XCTAssertEqual(found.system.identifier, "disk4s1")
      XCTAssertEqual(found.preboot.uuid, Self.binding.prebootUUID)
      // A renamed System volume or a second Data volume is not this installation.
      var renamed = volumes
      renamed[0] = RemovalVolume(
        uuid: Self.binding.systemUUID, name: "Other", roles: ["System"], group: group,
        identifier: "disk4s1")
      for changed in [renamed, volumes + [volumes[1]]] {
        XCTAssertThrowsError(try NativeStage1Update.volumes(target, snapshot: snapshot(changed))) {
          XCTAssertEqual($0 as? NativeStage1UpdateError, .changedInstallation)
        }
      }
    }

    // MARK: What to do

    func testAnUnchangedStage1IsANoOpAndAnEarlierOneIsUpdated() async throws {
      let candidate = try await Self.candidate()
      // Alpha 17: an unpadded object loading m1n1/boot.bin is enrolled.
      XCTAssertEqual(NativeStage1Update.decide(candidate, records: try Self.records()), .update)
      // Already enrolled and already Recovery's copy: nothing to do.
      var files = Self.payloadFiles()
      files["raw/aura-raw.bin"] = candidate.raw
      files["macho/aura-boot.macho"] = candidate.machO
      var manifest =
        try JSONSerialization.jsonObject(with: Self.manifest(files: files)) as! [String: Any]
      manifest["modes"] = ["macho": ["espPath": "m1n1/boot-ctxr.bin"]]
      let current = try Self.records(
        configuration: Self.configuration(stage2Path: "m1n1/boot-ctxr.bin"),
        manifest: Self.json(manifest),
        receipt: Self.receipt(stage1: candidate.enrolled, stage2Path: "m1n1/boot-ctxr.bin"))
      XCTAssertEqual(NativeStage1Update.decide(candidate, records: current), .unchanged)
      // Enrolled, but an unfinished update left another object for Recovery.
      let leftover = try Self.records(
        configuration: Self.configuration(stage2Path: "m1n1/boot-ctxr.bin"),
        receipt: Self.receipt(stage1: candidate.enrolled, stage2Path: "m1n1/boot-ctxr.bin"))
      XCTAssertEqual(NativeStage1Update.decide(candidate, records: leftover), .restage)
    }

    func testTheResultIsAValidTranscriptForTheApprovedPlan() async throws {
      let (base, plan) = try NativePreservedInstallJournalTests.transcript()
      let candidate = try await Self.candidate()
      let staged = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeStage1Update.transcript(base, planDigest: plan.planDigest, staged: candidate))
      XCTAssertEqual(staged.plan, plan)
      XCTAssertEqual(staged.completion, .awaitingRecovery)
      XCTAssertEqual(staged.checkpoints.map(\.identifier), [NativeStage1Update.checkpoint])
      let unchanged = try AppleInstallerTrustCore().validateEngineTranscript(
        NativeStage1Update.transcript(base, planDigest: plan.planDigest, staged: nil))
      XCTAssertEqual(unchanged.completion, .installed)
      XCTAssertTrue(unchanged.checkpoints.isEmpty)
    }

    // MARK: Staging

    /// A stub System volume with Recovery's inputs, owned by this test.
    func stub(files: [String: Data] = payloadFiles()) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "stage1-update-" + UUID().uuidString)
      let data = root.appendingPathComponent(NativeStage1Update.installData)
      for (name, bytes) in files {
        let url = data.appendingPathComponent("AuraPayloads/" + name)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
      }
      try Self.configuration().write(to: data.appendingPathComponent("install-config.json"))
      try Self.manifest().write(to: data.appendingPathComponent("AuraPayloads/manifest.json"))
      let state = root.appendingPathComponent("Aurora/Recovery/State")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      try Self.receipt().write(to: state.appendingPathComponent("installation.json"))
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      return root
    }

    func staging(_ root: URL) throws -> NativeStage1UpdateStaging {
      NativeStage1UpdateStaging(
        system: try NativeHandoffFileTree(root, protected: true, owner: getuid()),
        systemRoot: root, owner: getuid())
    }

    func testStagingReplacesOnlyRecoverysStage1AndItsRecords() async throws {
      let root = try stub()
      let staging = try staging(root)
      let records = try staging.records(binding: Self.binding)
      let candidate = try await Self.candidate()
      let confined = Data("confined stage 2".utf8)
      try await staging.stage(candidate, records: records, stage2Baseline: confined)

      let data = root.appendingPathComponent(NativeStage1Update.installData)
      let payloads = data.appendingPathComponent("AuraPayloads")
      XCTAssertEqual(
        try Data(contentsOf: payloads.appendingPathComponent("raw/aura-raw.bin")), candidate.raw)
      XCTAssertEqual(
        try Data(contentsOf: payloads.appendingPathComponent("macho/aura-boot.macho")),
        candidate.machO)
      XCTAssertEqual(
        try Data(contentsOf: payloads.appendingPathComponent("raw/boot.bin")), confined)
      for (name, bytes) in Self.vendor {
        XCTAssertEqual(try Data(contentsOf: payloads.appendingPathComponent(name)), bytes, name)
      }
      let config =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: data.appendingPathComponent("install-config.json")))
        as! [String: Any]
      XCTAssertEqual(config["stage2Path"] as? String, "m1n1/boot-ctxr.bin")
      XCTAssertEqual(config["systemUUID"] as? String, Self.binding.systemUUID)
      let manifest =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: payloads.appendingPathComponent("manifest.json")))
        as! [String: Any]
      XCTAssertEqual(manifest["defaultMode"] as? String, "macho")
      XCTAssertEqual(
        (manifest["modes"] as? [String: [String: String]])?["macho"]?["espPath"],
        "m1n1/boot-ctxr.bin")
      let files = try XCTUnwrap(manifest["files"] as? [String: [String: Any]])
      XCTAssertEqual(files["macho/aura-boot.macho"]?["sha256"] as? String, candidate.enrolledSHA256)
      XCTAssertEqual(manifest["vendorFirmware"] as? [String], Self.vendor.keys.sorted())
      // The receipt is Recovery's: it changes only once the new Stage 1 is enrolled.
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent(NativeStage1Update.receiptPath)),
        try Self.receipt())
      // Recovery now sees the staged Stage 1 as an update, and nothing is left beside it.
      let restaged = try staging.records(binding: Self.binding)
      XCTAssertEqual(NativeStage1Update.decide(candidate, records: restaged), .update)
      let siblings = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Aurora/Recovery").path)
      XCTAssertEqual(Set(siblings), ["InstallData", "State"])
    }

    func testStagingStopsWithoutChangesWhenRecoverysCopyWasAltered() async throws {
      let root = try stub()
      let staging = try staging(root)
      let records = try staging.records(binding: Self.binding)
      let tar = root.appendingPathComponent(
        NativeStage1Update.installData + "/AuraPayloads/vendorfw/firmware.tar")
      try Data("altered".utf8).write(to: tar)
      let before = try Data(
        contentsOf: root.appendingPathComponent(
          NativeStage1Update.installData + "/install-config.json"))
      do {
        try await staging.stage(try await Self.candidate(), records: records, stage2Baseline: nil)
        XCTFail("staged over an altered Recovery copy")
      } catch {
        XCTAssertEqual(error as? NativeStage1UpdateError, .changedInstallation)
      }
      XCTAssertEqual(
        try Data(
          contentsOf: root.appendingPathComponent(
            NativeStage1Update.installData + "/install-config.json")), before)
      let siblings = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Aurora/Recovery").path)
      XCTAssertEqual(Set(siblings), ["InstallData", "State"])
    }

    // MARK: Authorization and failures

    final class Rejecting: MachineOwnerCredentialValidating {
      func validate(_ authorization: MachineOwnerAuthorization) throws {
        throw MachineOwnerCredentialValidationError.rejected
      }
    }

    final class Recording: ImportedEngineHandoffExecuting, @unchecked Sendable {
      var calls = 0
      func execute(
        _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
        operation: EngineHandoffOperation
      ) async throws -> Data {
        calls += 1
        return Data()
      }
    }

    func testARejectedPasswordStopsTheUpdateBeforeAnyPackageIsRead() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "stage1-update-helper-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let executor = Recording()
      let server = ClosedEngineHelperServer(
        workingDirectory: root, executor: executor, credentialValidator: Rejecting())
      let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      let directory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do {
        _ = try await server.submit(
          packageDirectory: directory,
          authorization: MachineOwnerAuthorization(username: "owner", password: Data("pw".utf8)),
          operation: .updateStage1)
        XCTFail("a rejected password reached the update")
      } catch {
        XCTAssertEqual(error as? ClosedEngineHelperError, .invalidMachineOwnerCredentials)
      }
      XCTAssertEqual(executor.calls, 0)
      XCTAssertEqual(EngineHandoffOperation(rawValue: "update-stage1"), .updateStage1)
      // An update writes no install.conf.
      XCTAssertFalse(
        InstallConfRecordPolicy.shouldRecord(operation: .updateStage1, nextAction: .enterRecovery))
    }

    struct FakeUpdate: NativeStage1UpdateExecuting {
      let result: Result<Data, NativeStage1UpdateFailure>
      func execute(
        _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization
      ) async throws -> Data { try result.get() }
    }

    static func package(_ intent: ImportedInstallationIntent = .reinstall)
      -> ImportedEngineHandoffPackage
    {
      let root = URL(fileURLWithPath: "/nonexistent/aurora-stage1-update")
      return ImportedEngineHandoffPackage(
        packageURL: root, manifestURL: root.appendingPathComponent("manifest.json"),
        requestURL: root.appendingPathComponent("request.json"),
        identityURL: root.appendingPathComponent("identity.json"),
        metadataURL: root.appendingPathComponent("metadata.json"),
        payloadURL: root.appendingPathComponent("payload.zip"),
        bindingDigest: "sha256:" + String(repeating: "a", count: 64),
        planDigest: String(repeating: "b", count: 64), deviceIdentifier: "apple,j700",
        storeIdentifier: "disk0", installationIntent: intent)
    }

    func notice(_ failure: NativeStage1UpdateFailure) async throws -> EngineFailureNotice {
      let executor = PinnedAsahiEngineExecutor(
        effectiveUserID: { 0 }, stage1Update: FakeUpdate(result: .failure(failure)))
      do {
        _ = try await executor.execute(
          Self.package(),
          authorization: MachineOwnerAuthorization(
            username: "owner", password: Data("secret".utf8)),
          operation: .updateStage1, installConf: nil)
      } catch PinnedAsahiEngineExecutionError.engineFailed(let report) {
        XCTAssertFalse(report.redactedStandardErrorTail.contains("secret"))
        return report.notice
      }
      throw XCTSkip("the update did not fail")
    }

    func testTheExecutorRunsOnlyTheUpdateAndSaysWhyItStopped() async throws {
      let executor = PinnedAsahiEngineExecutor(
        effectiveUserID: { 0 }, stage1Update: FakeUpdate(result: .success(Data("done".utf8))))
      let authorization = try MachineOwnerAuthorization(
        username: "owner", password: Data("pw".utf8))
      let result = try await executor.execute(
        Self.package(), authorization: authorization, operation: .updateStage1, installConf: nil)
      XCTAssertEqual(result, Data("done".utf8))
      // Only a Reset package can be used to update Stage 1.
      do {
        _ = try await executor.execute(
          Self.package(.fresh), authorization: authorization, operation: .updateStage1,
          installConf: nil)
        XCTFail("a fresh installation's package updated Stage 1")
      } catch {
        XCTAssertEqual(error as? PinnedAsahiEngineExecutionError, .nativeReinstallUnavailable)
      }

      let before = try await notice(
        NativeStage1UpdateFailure(
          underlying: NativeStage1UpdateError.missingStage2(path: "m1n1/boot-ctxr.bin"),
          diskChanged: false))
      XCTAssertEqual(before.reason, .bootLoaderUpdateRefused)
      XCTAssertTrue(before.diskUnchanged)
      XCTAssertEqual(
        before.summary, NativeStage1UpdateError.missingStage2(path: "m1n1/boot-ctxr.bin").summary)
      let authorizationFailed = try await notice(
        NativeStage1UpdateFailure(
          underlying: NativeHandoffValidationError.authorizationFailed, diskChanged: true))
      XCTAssertFalse(authorizationFailed.diskUnchanged)
      XCTAssertTrue(authorizationFailed.summary.contains("password"), authorizationFailed.summary)
      let changed = try await notice(
        NativeStage1UpdateFailure(
          underlying: NativePreservedInstallError.changedLayout, diskChanged: false))
      XCTAssertEqual(changed.summary, NativeStage1UpdateError.changedInstallation.summary)
      for error in [
        NativeStage1UpdateError.setupUnfinished, .changedInstallation, .wrongBootMode,
        .unsupportedStage1, .stage1TooLarge(bytes: 70 << 20),
        .notEnoughSpace(requiredBytes: 200 << 20, availableBytes: 1),
        .missingStage2(path: "m1n1/boot-ctxr.bin"),
      ] {
        XCTAssertLessThanOrEqual(
          error.summary.count, EngineFailureNotice.maximumSummaryCharacters, "\(error)")
      }
    }
  }
#endif
