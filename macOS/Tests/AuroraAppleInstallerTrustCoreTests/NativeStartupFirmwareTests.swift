#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class NativeStartupFirmwareTests: XCTestCase {
    private static let build = "26B123"
    private static let manifest = Data("fixture manifest".utf8)

    private func policy(models: [String]?) throws -> NativeInspectionPolicy {
      var object =
        try JSONSerialization.jsonObject(with: Data(NativeInspectionPolicySource.json.utf8))
        as! [String: Any]
      var entries = object["firmware"] as! [[String: Any]]
      let index = try XCTUnwrap(
        entries.firstIndex { ($0["pin"] as? [String: Any])?["build"] as? String == Self.build })
      entries[index]["models"] = models ?? NSNull()
      object["firmware"] = entries
      return try JSONDecoder().decode(
        NativeInspectionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func choose(
      _ device: String, _ hardware: NativeInspectionHardware, policy: NativeInspectionPolicy,
      supported: [String]? = nil
    ) throws -> NativeFirmwareSelection {
      var template: [String: Any] = [
        "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
        "partitions": [["size": "1GiB"]],
      ]
      if let supported { template["supported_fw"] = supported }
      return try NativeFirmwareSelection.choose(
        deviceIdentifier: device, facts: .init(deviceIdentifier: device, hardware: hardware),
        metadata: NativeInstallationMetadata(
          data: JSONSerialization.data(withJSONObject: ["os_list": [template]])),
        policy: policy)
    }

    /// An M2 MacBook Air on macOS 27.2 (26B123).
    private let air272 = NativeInspectionHardware(
      chipID: 0x8112, bootVersion: "mBoot-20457.41.3", macOSVersion: "27.2",
      recoveryVersion: "26.2.123.0.0,0")

    // MARK: Policy

    func testTheSealedPinNamesTheUniversal26B123ImageAndNoBoardYet() throws {
      let sealed = try NativeInspectionPolicy.sealed()
      let pinned = sealed.firmware.filter { $0.pin != nil }
      XCTAssertEqual(pinned.count, 1)
      let entry = try XCTUnwrap(pinned.first)
      XCTAssertEqual(entry.version, "27.2")
      XCTAssertEqual(entry.pin?.build, Self.build)
      XCTAssertEqual(entry.pin?.sourceBytes, 25_595_669_503)
      XCTAssertEqual(
        entry.sourceURL,
        "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/"
          + "UniversalMac_27.2_26B123_Restore.ipsw")
      XCTAssertEqual(entry.minimumBoot, "mBoot-20457.41.3")
      XCTAssertEqual(entry.minimumMacOS, "27.2")
      XCTAssertEqual(entry.models, ["j413"])
      // It is last, so it wins wherever a board qualifies for it.
      XCTAssertEqual(sealed.firmware.last?.pin?.build, Self.build)
      // The M2 on macOS 27.2 gets the 27.2 stub.
      XCTAssertEqual(try choose("apple,j413", air272, policy: sealed).version, "27.2")
    }

    func testAQualifiedBoardOnMacOS272TakesThePinnedImage() throws {
      let qualified = try policy(models: ["j413"])
      let selection = try choose("apple,j413", air272, policy: qualified)
      XCTAssertEqual(selection.version, "27.2")
      XCTAssertEqual(selection.pin?.build, Self.build)
      XCTAssertEqual(selection.stubBytes, 5_999_951_872)
      XCTAssertEqual(
        selection.sourceURL.lastPathComponent, "UniversalMac_27.2_26B123_Restore.ipsw")
      // A release that lists only older firmware keeps it.
      XCTAssertEqual(
        try choose("apple,j413", air272, policy: qualified, supported: ["13.5"]).version, "13.5")
      // Below macOS 27.2 the Mac keeps 13.5 rather than being told to update.
      let air270 = NativeInspectionHardware(
        chipID: 0x8112, bootVersion: "mBoot-20457.1.29", macOSVersion: "27.0",
        recoveryVersion: "26.1.428.0.0,0")
      XCTAssertEqual(try choose("apple,j413", air270, policy: qualified).version, "13.5")
      // Other boards never take it.
      let pro = NativeInspectionHardware(
        chipID: 0x6000, bootVersion: "mBoot-20457.41.3", macOSVersion: "27.2",
        recoveryVersion: "26.2.123.0.0,0")
      XCTAssertEqual(try choose("apple,j316s", pro, policy: qualified).version, "13.5")
    }

    func testAPinMayNotAdmitEveryBoardOrAnotherFile() throws {
      // A null model list would admit every Mac; the qualification test
      // refuses it in the source, and a mismatched file name is refused here.
      var object =
        try JSONSerialization.jsonObject(with: Data(NativeInspectionPolicySource.json.utf8))
        as! [String: Any]
      var entries = object["firmware"] as! [[String: Any]]
      let index = try XCTUnwrap(entries.firstIndex { $0["pin"] != nil })
      entries[index]["models"] = ["j413"]
      entries[index]["sourceURL"] =
        "https://updates.cdn-apple.com/2026FallFCS/c202a724-db7e-4d56-917b-110aa0226507/"
        + "UniversalMac_27.2.1_26B131_Restore.ipsw"
      object["firmware"] = entries
      let renamed = try JSONDecoder().decode(
        NativeInspectionPolicy.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertThrowsError(try choose("apple,j413", air272, policy: renamed)) {
        XCTAssertEqual($0 as? NativeFirmwareSelectionError, .invalidSource)
      }
    }

    func testThe27_2_1ImageIsRefusedBySizeManifestAndBuild() throws {
      let pin = NativeFirmwarePin(
        build: Self.build, sourceBytes: 25_595_669_503,
        manifestSHA256: SHA256Digest(hashing: Self.manifest).rawValue)
      let selection = NativeFirmwareSelection(
        version: "27.2",
        sourceURL: URL(
          string: "https://updates.cdn-apple.com/x/UniversalMac_27.2_26B123_Restore.ipsw")!,
        stubBytes: 5_999_951_872, pin: pin)
      XCTAssertNoThrow(try selection.requirePinnedSource(bytes: 25_595_669_503))
      // 26B131's image is 25,595,954,706 bytes.
      XCTAssertThrowsError(try selection.requirePinnedSource(bytes: 25_595_954_706)) {
        XCTAssertEqual($0 as? NativeFirmwareSelectionError, .pinnedSourceMismatch(build: "26B123"))
      }
      XCTAssertNoThrow(try selection.requirePinnedManifest(Self.manifest, buildNumber: "26B123"))
      XCTAssertThrowsError(
        try selection.requirePinnedManifest(Data("other".utf8), buildNumber: "26B123"))
      XCTAssertThrowsError(
        try selection.requirePinnedManifest(Self.manifest, buildNumber: "26B131"))
      // An unpinned selection checks nothing more than before.
      let open = NativeFirmwareSelection(
        version: "13.5", sourceURL: selection.sourceURL, stubBytes: 2_499_805_184)
      XCTAssertNoThrow(try open.requirePinnedSource(bytes: 1))
      XCTAssertNoThrow(try open.requirePinnedManifest(Data(), buildNumber: "22G74"))
    }

    func testAPinMismatchIsReportedAsAFirmwareFailureThatChangedNothing() {
      let (reason, summary) = NativeInstallerExecutor.preflightFailure(
        stage: .stubFiles, error: NativeFirmwareSelectionError.pinnedSourceMismatch(build: "26B123")
      )
      XCTAssertEqual(reason, .firmwarePreparation)
      XCTAssertTrue(summary.contains("26B123"))
      XCTAssertTrue(summary.contains("Nothing on the disk changed"))
    }

    // MARK: Slots

    private let target = NativeFirmwareSelection(
      version: "27.2",
      sourceURL: URL(
        string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/"
          + "UniversalMac_27.2_26B123_Restore.ipsw")!,
      stubBytes: 5_999_951_872,
      pin: NativeFirmwarePin(
        build: "26B123", sourceBytes: 25_595_669_503,
        manifestSHA256: "sha256:" + String(repeating: "0", count: 64)))

    private func installation(build: String? = "22G74", version: String? = "13.5")
      -> NativeStartupFirmwareSlot.Installation
    {
      .init(
        title: "Aurora Fedora Remix", espUUID: "A1B2C3D4-0000-4000-8000-000000000001",
        stubBytes: 2_499_805_184, endOffset: 300 << 30, build: build, version: version)
    }

    private let gib: UInt64 = 1 << 30

    func testAnM2On13_5GetsASlotRightAfterItsPartitions() throws {
      let space = NativeStartupFirmwareSlot.Space(
        free: [.init(offset: 40 * gib, size: 7 * gib), .init(offset: 300 * gib, size: 20 * gib)],
        macOSShrinkableBytes: 100 * gib)
      let decision = try NativeStartupFirmwareSlot.decide(
        installation: installation(), slots: [], target: target, space: space)
      guard case .create(let plan) = decision else { return XCTFail("\(decision)") }
      XCTAssertEqual(plan.build, "26B123")
      XCTAssertEqual(plan.title, "Aurora Fedora Remix 27.2")
      // The 6 GB stub size is already a whole number of MiB.
      XCTAssertEqual(plan.bytes, 5_999_951_872)
      // The extent after the installation wins over a smaller one elsewhere.
      XCTAssertEqual(plan.placement, .free(.init(offset: 300 * gib, size: 20 * gib)))
      XCTAssertEqual(plan.firmwareDirectory, "aurora/firmware/26B123")
      XCTAssertEqual(
        plan.steps,
        [
          .createContainer(bytes: plan.bytes, title: plan.title),
          .restoreStub(build: "26B123", version: "27.2"),
          .stageRecovery(espUUID: "A1B2C3D4-0000-4000-8000-000000000001"),
          .writeSlotFirmware(directory: "aurora/firmware/26B123"),
          .enrollInRecovery(title: plan.title),
        ])
      XCTAssertEqual(plan.steps.filter(\.byOwner).count, 1)
      XCTAssertEqual(plan.steps.last?.byOwner, true)
    }

    func testWithoutFreeSpaceMacOSShrinksOrTheMoveIsRefused() throws {
      let small = NativeStartupFirmwareSlot.Space(
        free: [.init(offset: 40 * gib, size: 2 * gib)], macOSShrinkableBytes: 50 * gib)
      guard
        case .create(let plan) = try NativeStartupFirmwareSlot.decide(
          installation: installation(), slots: [], target: target, space: small)
      else { return XCTFail() }
      XCTAssertEqual(plan.placement, .shrinkMacOS(bytes: plan.bytes))
      XCTAssertEqual(plan.steps.first, .shrinkMacOS(bytes: plan.bytes))

      let none = NativeStartupFirmwareSlot.Space(
        free: [.init(offset: 40 * gib, size: 2 * gib)], macOSShrinkableBytes: 3 * gib)
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(), slots: [], target: target, space: none)
      ) {
        guard
          case .notEnoughSpace(let required, let available) =
            $0 as? NativeStartupFirmwareSlot.Refusal
        else { return XCTFail("\($0)") }
        XCTAssertGreaterThanOrEqual(required, 5_999_951_872)
        XCTAssertEqual(available, 3 * gib)
      }
    }

    func testAnUnalignedExtentIsUsedFromItsAlignedStart() throws {
      let bytes = try NativeInspectionMath.alignUp(target.stubBytes)
      // Exactly the slot plus less than one alignment unit of slack in front.
      let offset: UInt64 = 10 * gib + 4096
      let extent = NativeStartupFirmwareSlot.Extent(offset: offset, size: bytes + 4096)
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.place(
          bytes: bytes, after: 0, space: .init(free: [extent], macOSShrinkableBytes: 0)))
      let roomy = NativeStartupFirmwareSlot.Extent(offset: offset, size: bytes + (1 << 20))
      XCTAssertEqual(
        try NativeStartupFirmwareSlot.place(
          bytes: bytes, after: 0, space: .init(free: [roomy], macOSShrinkableBytes: 0)),
        .free(.init(offset: 10 * gib + (1 << 20), size: bytes)))
    }

    func testCurrentExistingAndConflictingSlots() throws {
      let space = NativeStartupFirmwareSlot.Space(free: [], macOSShrinkableBytes: 100 * gib)
      XCTAssertEqual(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(build: "26B123", version: "27.2"), slots: [],
          target: target, space: space),
        .current)
      let slot = NativeStartupFirmwareSlot.Slot(
        title: "Aurora Fedora Remix 27.2", build: "26B123", storeIdentifier: "disk0s6")
      XCTAssertEqual(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(), slots: [slot], target: target, space: space),
        .slotExists(slot))
      let other = NativeStartupFirmwareSlot.Slot(
        title: "Aurora Fedora Remix 27.2", build: "26B131", storeIdentifier: "disk0s6")
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(), slots: [other], target: target, space: space)
      ) { XCTAssertEqual($0 as? NativeStartupFirmwareSlot.Refusal, .otherSlot(other)) }
    }

    func testOnlyAPinnedNewerBuildForAKnownInstallation() throws {
      let space = NativeStartupFirmwareSlot.Space(free: [], macOSShrinkableBytes: 100 * gib)
      let unpinned = NativeFirmwareSelection(
        version: "27.2", sourceURL: target.sourceURL, stubBytes: target.stubBytes)
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(), slots: [], target: unpinned, space: space)
      ) { XCTAssertEqual($0 as? NativeStartupFirmwareSlot.Refusal, .notPinned) }
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(build: nil), slots: [], target: target, space: space)
      ) { XCTAssertEqual($0 as? NativeStartupFirmwareSlot.Refusal, .unknownCurrentFirmware) }
      // A J873g's 27.0 stub never moves down, and a newer one is left alone.
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.decide(
          installation: installation(build: "27A100", version: "28.0"), slots: [],
          target: target, space: space)
      ) {
        XCTAssertEqual(
          $0 as? NativeStartupFirmwareSlot.Refusal,
          .olderFirmware(current: "28.0", selected: "27.2"))
      }
    }

    func testStubInfoIsReadFromTheInstallersOwnFile() throws {
      let data = try JSONSerialization.data(withJSONObject: [
        "system_version": ["ProductVersion": "13.5", "ProductBuildVersion": "22G74"],
        "manifest_info": ["build_number": "22G74", "variant": "macOS Customer"],
      ])
      let info = NativeStartupFirmwareSlot.Installation.stubInfo(data)
      XCTAssertEqual(info.build, "22G74")
      XCTAssertEqual(info.version, "13.5")
      XCTAssertNil(NativeStartupFirmwareSlot.Installation.stubInfo(nil).build)
      XCTAssertNil(NativeStartupFirmwareSlot.Installation.stubInfo(Data("[]".utf8)).build)
      let hostile = try JSONSerialization.data(withJSONObject: [
        "manifest_info": ["build_number": "../../x"]
      ])
      XCTAssertNil(NativeStartupFirmwareSlot.Installation.stubInfo(hostile).build)
    }

    func testTheSlotIndexMapsTheDeviceTreeVersionToTheBuild() throws {
      let first = try NativeStartupFirmwareSlot.slotIndex(
        existing: nil, version: "27.2", build: "26B123")
      XCTAssertEqual(
        String(decoding: first, as: UTF8.self), #"{"schema":1,"slots":{"27.2.0":"26B123"}}"#)
      let second = try NativeStartupFirmwareSlot.slotIndex(
        existing: first, version: "13.5", build: "22G74")
      XCTAssertEqual(
        String(decoding: second, as: UTF8.self),
        #"{"schema":1,"slots":{"13.5.0":"22G74","27.2.0":"26B123"}}"#)
      XCTAssertEqual(NativeStartupFirmwareSlot.deviceTreeVersion("14.8.3"), "14.8.3")
      XCTAssertNil(NativeStartupFirmwareSlot.deviceTreeVersion("27.2 beta"))
      XCTAssertThrowsError(
        try NativeStartupFirmwareSlot.slotIndex(
          existing: Data("{}".utf8), version: "27.2", build: "26B123"))
    }

    // MARK: Live

    /// Reads Apple's 26B123 image: its size, its manifest's digest and each
    /// lab board's build identity must be the pinned ones. Writes nothing.
    func testOptInLivePinnedImagePlansEveryLabBoard() async throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_FIRMWARE_PIN"] == "1" else {
        throw XCTSkip("Explicit live firmware-pin probe only")
      }
      let policy = try NativeInspectionPolicy.sealed()
      let entry = try XCTUnwrap(policy.firmware.first { $0.pin?.build == Self.build })
      let pin = try XCTUnwrap(entry.pin)
      let url = try XCTUnwrap(URL(string: entry.sourceURL))
      let source = try await IPSWHTTPRangeReader.discover(url: url)
      XCTAssertEqual(UInt64(source.sizeBytes), pin.sourceBytes)
      let archive = try await IPSWArchive.open(NativeWindowedRangeReader(source))
      let selection = NativeFirmwareSelection(
        version: entry.version, sourceURL: url, stubBytes: 5_999_951_872, pin: pin)
      // M1 Pro, M2, M4 Pro and the MacBook Neo.
      for (device, board, chip) in [
        ("j316s", 0x0A, 0x6000), ("j413", 0x28, 0x8112), ("j616s", 0x06, 0x6040),
        ("j700", 0x64, 0x8140),
      ] as [(String, UInt64, UInt64)] {
        let plan = try await NativeStubFilePlan(
          archive: archive, source: selection, deviceClass: device + "ap", boardID: board,
          chipID: chip, admitRecords: false)
        let info = try XCTUnwrap(
          JSONSerialization.jsonObject(with: plan.stubInfo) as? [String: Any])
        let manifest = try XCTUnwrap(info["manifest_info"] as? [String: Any])
        XCTAssertEqual(manifest["build_number"] as? String, Self.build, device)
      }
    }
  }
#endif
