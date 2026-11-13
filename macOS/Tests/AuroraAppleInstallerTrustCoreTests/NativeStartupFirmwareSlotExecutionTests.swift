#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativeStartupFirmwareSlotExecutionTests: XCTestCase {
    private typealias Slot = NativeStartupFirmwareSlot
    private let gib: UInt64 = 1 << 30
    private let esp = "A1B2C3D4-0000-4000-8000-000000000001"

    private var installation: Slot.Installation {
      .init(
        title: "Aurora Fedora Remix", espUUID: esp, stubBytes: 2_499_805_184,
        endOffset: 300 << 30, build: "22G74", version: "13.5")
    }

    private var target: NativeFirmwareSelection {
      NativeFirmwareSelection(
        version: "27.2",
        sourceURL: URL(
          string: "https://updates.cdn-apple.com/x/UniversalMac_27.2_26B123_Restore.ipsw")!,
        stubBytes: 5_999_951_872,
        pin: NativeFirmwarePin(
          build: "26B123", sourceBytes: 25_595_669_503,
          manifestSHA256: "sha256:" + String(repeating: "0", count: 64)))
    }

    private func plan(shrink: Bool = false) throws -> Slot.Plan {
      let space = Slot.Space(
        free: shrink ? [] : [.init(offset: 300 * gib, size: 20 * gib)],
        macOSShrinkableBytes: 100 * gib)
      guard
        case .create(let plan) = try Slot.decide(
          installation: installation, slots: [], target: target, space: space)
      else { throw XCTSkip("no plan") }
      return plan
    }

    // MARK: Plan identity

    func testThePlanDigestNamesThePlacementAndTheInstallation() throws {
      let free = try plan()
      let shrink = try plan(shrink: true)
      let first = try Slot.digest(free, installation: installation)
      XCTAssertEqual(first, try Slot.digest(free, installation: installation))
      XCTAssertNotNil(SHA256Digest(rawValue: first))
      XCTAssertNotEqual(first, try Slot.digest(shrink, installation: installation))
      let other = Slot.Installation(
        title: installation.title, espUUID: "A1B2C3D4-0000-4000-8000-000000000002",
        stubBytes: installation.stubBytes, endOffset: installation.endOffset,
        build: installation.build, version: installation.version)
      XCTAssertNotEqual(first, try Slot.digest(free, installation: other))
    }

    // MARK: Recovery inputs

    private let installedConfig: [String: Any] = [
      "schema": 2, "volumeName": "Aurora Fedora Remix",
      "systemUUID": "11111111-1111-4111-8111-111111111111",
      "groupUUID": "22222222-2222-4222-8222-222222222222",
      "prebootUUID": "33333333-3333-4333-8333-333333333333",
      "espUUID": "a1b2c3d4-0000-4000-8000-000000000001",
      "bootMode": "macho-standard", "stage2Path": "aurora/aura.bin",
      "bootstrap": ["sourceGroupUUID": "44444444-4444-4444-8444-444444444444"],
      "allowCustomBootArguments": false,
    ]

    private let installedManifest: [String: Any] = [
      "schema": 2, "defaultMode": "macho-standard",
      "modes": ["macho-standard": ["espPath": "aurora/aura.bin"]],
      "vendorFirmware": ["vendorfw/firmware.tar"],
      "files": [
        "raw/aura-raw.bin": ["sha256": String(repeating: "a", count: 64), "bytes": 1],
        "raw/boot.bin": ["sha256": String(repeating: "b", count: 64), "bytes": 2],
        "macho/aura-boot.macho": ["sha256": String(repeating: "c", count: 64), "bytes": 3],
        "vendorfw/firmware.tar": ["sha256": String(repeating: "d", count: 64), "bytes": 4],
      ],
    ]

    private func data(_ object: [String: Any]) throws -> Data {
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func slotVolumes(title: String = "Aurora Fedora Remix 27.2") -> Slot.SlotVolumes {
      .init(
        title: title, systemUUID: "55555555-5555-4555-8555-555555555555",
        groupUUID: "66666666-6666-4666-8666-666666666666",
        prebootUUID: "77777777-7777-4777-8777-777777777777")
    }

    func testTheSlotsRecoveryNamesItsVolumesAndTheInstallationsEverythingElse() throws {
      let manifest = try data(installedManifest)
      let inputs = try Slot.recoveryInputs(
        configuration: data(installedConfig), manifest: manifest, installation: installation,
        slot: slotVolumes(), plan: plan())
      XCTAssertEqual(inputs.manifest, manifest)
      let config = try XCTUnwrap(
        JSONSerialization.jsonObject(with: inputs.configuration) as? [String: Any])
      XCTAssertEqual(config["volumeName"] as? String, "Aurora Fedora Remix 27.2")
      XCTAssertEqual(config["systemUUID"] as? String, "55555555-5555-4555-8555-555555555555")
      XCTAssertEqual(config["groupUUID"] as? String, "66666666-6666-4666-8666-666666666666")
      XCTAssertEqual(config["prebootUUID"] as? String, "77777777-7777-4777-8777-777777777777")
      for key in [
        "schema", "espUUID", "bootMode", "stage2Path", "bootstrap", "allowCustomBootArguments",
      ] {
        XCTAssertEqual(
          config[key] as? NSObject, installedConfig[key] as? NSObject, key)
      }
      XCTAssertEqual(Set(config.keys), Set(installedConfig.keys))
    }

    func testRecoveryInputsRefuseAnotherInstallationOrAReusedVolume() throws {
      let manifest = try data(installedManifest)
      var otherESP = installedConfig
      otherESP["espUUID"] = "A1B2C3D4-0000-4000-8000-000000000009"
      XCTAssertThrowsError(
        try Slot.recoveryInputs(
          configuration: data(otherESP), manifest: manifest, installation: installation,
          slot: slotVolumes(), plan: plan())
      ) { XCTAssertEqual($0 as? Slot.ExecutionError, .changedInstallation) }

      var extra = installedConfig
      extra["unexpected"] = true
      XCTAssertThrowsError(
        try Slot.recoveryInputs(
          configuration: data(extra), manifest: manifest, installation: installation,
          slot: slotVolumes(), plan: plan())
      ) { XCTAssertEqual($0 as? Slot.ExecutionError, .changedInstallation) }

      var noMachO = installedManifest
      var files = noMachO["files"] as! [String: Any]
      files["macho/aura-boot.macho"] = nil
      noMachO["files"] = files
      XCTAssertThrowsError(
        try Slot.recoveryInputs(
          configuration: data(installedConfig), manifest: data(noMachO),
          installation: installation, slot: slotVolumes(), plan: plan())
      ) { XCTAssertEqual($0 as? Slot.ExecutionError, .changedInstallation) }

      let reused = Slot.SlotVolumes(
        title: "Aurora Fedora Remix 27.2", systemUUID: "11111111-1111-4111-8111-111111111111",
        groupUUID: "66666666-6666-4666-8666-666666666666",
        prebootUUID: "77777777-7777-4777-8777-777777777777")
      for slot in [reused, slotVolumes(title: "Aurora Fedora Remix")] {
        XCTAssertThrowsError(
          try Slot.recoveryInputs(
            configuration: data(installedConfig), manifest: manifest, installation: installation,
            slot: slot, plan: plan())
        ) { XCTAssertEqual($0 as? Slot.ExecutionError, .changedSlot) }
      }
    }

    // MARK: Journal

    func testTheJournalRecordsEachInstallerStepInOrderThenWaitsForTheOwner() throws {
      let plan = try plan()
      var journal = try Slot.Journal.start(plan, installation: installation)
      var progress = try Slot.Journal.read(journal, plan: plan, installation: installation)
      XCTAssertEqual(progress.done, 0)
      XCTAssertEqual(progress.next(in: plan), 0)
      XCTAssertThrowsError(try Slot.Journal.completion(progress, plan: plan)) {
        XCTAssertEqual($0 as? Slot.ExecutionError, .unfinished(next: 0))
      }
      // create container, restore stub, stage Recovery, write firmware.
      for index in 0..<4 {
        journal += try Slot.Journal.step(progress, plan: plan, evidence: Data("\(index)".utf8))
        progress = try Slot.Journal.read(journal, plan: plan, installation: installation)
        XCTAssertEqual(progress.done, index + 1)
      }
      XCTAssertNil(progress.next(in: plan))
      XCTAssertEqual(plan.steps[progress.done].byOwner, true)
      XCTAssertThrowsError(try Slot.Journal.step(progress, plan: plan, evidence: Data()))
      journal += try Slot.Journal.completion(progress, plan: plan)
      progress = try Slot.Journal.read(journal, plan: plan, installation: installation)
      XCTAssertTrue(progress.completed)
      XCTAssertThrowsError(try Slot.Journal.completion(progress, plan: plan))
    }

    func testAResumedJournalContinuesWhereItStopped() throws {
      let plan = try plan(shrink: true)
      XCTAssertEqual(plan.steps.first, .shrinkMacOS(bytes: plan.bytes))
      var journal = try Slot.Journal.start(plan, installation: installation)
      for _ in 0..<2 {
        let progress = try Slot.Journal.read(journal, plan: plan, installation: installation)
        journal += try Slot.Journal.step(progress, plan: plan, evidence: Data("x".utf8))
      }
      let resumed = try Slot.Journal.read(journal, plan: plan, installation: installation)
      XCTAssertEqual(resumed.next(in: plan), 2)
      XCTAssertEqual(plan.steps[2], .restoreStub(build: "26B123", version: "27.2"))
    }

    func testAJournalForAnotherPlanOrWithChangedRecordsIsRefused() throws {
      let free = try plan()
      let shrink = try plan(shrink: true)
      let journal = try Slot.Journal.start(free, installation: installation)
      XCTAssertThrowsError(try Slot.Journal.read(journal, plan: shrink, installation: installation))

      let progress = try Slot.Journal.read(journal, plan: free, installation: installation)
      let step = try Slot.Journal.step(progress, plan: free, evidence: Data())
      // A torn last line, a dropped plan record and a repeated step.
      XCTAssertThrowsError(
        try Slot.Journal.read(journal + step.dropLast(), plan: free, installation: installation))
      XCTAssertThrowsError(try Slot.Journal.read(step, plan: free, installation: installation))
      XCTAssertThrowsError(
        try Slot.Journal.read(journal + step + step, plan: free, installation: installation))

      // A step recorded ahead of its turn.
      var skipped = try JSONSerialization.jsonObject(with: step.dropLast()) as! [String: Any]
      var payload = skipped["payload"] as! [String: Any]
      payload["index"] = 1
      payload["step"] = free.steps[1].record
      skipped["payload"] = payload
      var line = try JSONSerialization.data(withJSONObject: skipped, options: [.sortedKeys])
      line.append(10)
      XCTAssertThrowsError(
        try Slot.Journal.read(journal + line, plan: free, installation: installation)
      ) { XCTAssertEqual($0 as? Slot.ExecutionError, .outOfOrder(expected: 0, recorded: 1)) }
      XCTAssertThrowsError(try Slot.Journal.read(Data(), plan: free, installation: installation))
    }
  }
#endif
