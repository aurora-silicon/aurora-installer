#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class MacOSStagingSpaceTests: XCTestCase {
    typealias Read = NativeStubStagingRequirement.Read
    private let gib: UInt64 = 1 << 30
    /// A macOS container with 8.33 GiB free.
    private let lowFree: UInt64 = 8_944_269_393

    /// The macOS 13.5 restore image (UniversalMac_13.5_22G74, 12,893,195,726
    /// bytes) as the stub stage reads it for one board: every selected member's
    /// local record offset and stored size, from the image's ZIP directory.
    static let thirteenFiveReads: [Read] = [
      Read(name: "022-15462-082.dmg", recordOffset: 0, compressedSize: 651_410_105),
      Read(
        name: "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/BootabilityBrain",
        recordOffset: 12_218_293_948, compressedSize: 35),
      Read(
        name: "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Resources",
        recordOffset: 12_218_294_114, compressedSize: 28),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/A/BootabilityBrain",
        recordOffset: 12_218_294_476, compressedSize: 1_591_449),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/A/Resources/BYError.strings",
        recordOffset: 12_219_886_183, compressedSize: 1446),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/A/Resources/Info.plist",
        recordOffset: 12_219_887_780, compressedSize: 523),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/A/Resources/version.plist",
        recordOffset: 12_219_888_449, compressedSize: 261),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/A/_CodeSignature/CodeResources",
        recordOffset: 12_219_888_980, compressedSize: 328),
      Read(
        name: "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/Versions/Current",
        recordOffset: 12_219_889_462, compressedSize: 3),
      Read(
        name:
          "BootabilityBundle/Restore/Bootability/System/Library/CoreServices/RestoreVersion.plist",
        recordOffset: 12_219_889_850, compressedSize: 217),
      Read(
        name: "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache",
        recordOffset: 12_219_891_361, compressedSize: 2443),
      Read(
        name: "Firmware/022-15462-082.dmg.root_hash", recordOffset: 12_343_253_404,
        compressedSize: 68),
      Read(
        name: "Firmware/022-15462-082.dmg.trustcache", recordOffset: 12_343_253_558,
        compressedSize: 21184),
      Read(
        name: "Firmware/096-63007-081.dmg.root_hash", recordOffset: 12_395_518_440,
        compressedSize: 139),
      Read(
        name: "Firmware/096-63007-081.dmg.trustcache", recordOffset: 12_395_518_665,
        compressedSize: 295639),
      Read(
        name: "Firmware/AOP/aopfw-mac14jaop.im4p", recordOffset: 12_449_448_110,
        compressedSize: 385173),
      Read(
        name: "Firmware/J414S_InputDevice.im4p", recordOffset: 12_458_305_050, compressedSize: 55596
      ),
      Read(
        name: "Firmware/J414S_MtpFirmware.im4p", recordOffset: 12_458_360_727,
        compressedSize: 217393),
      Read(
        name: "Firmware/J414s_Multitouch.im4p", recordOffset: 12_458_644_594, compressedSize: 66313),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j180dap.im4m",
        recordOffset: 12_460_204_626, compressedSize: 3580),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j274ap.im4m",
        recordOffset: 12_460_208_319, compressedSize: 3520),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j293ap.im4m",
        recordOffset: 12_460_211_951, compressedSize: 3705),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j313ap.im4m",
        recordOffset: 12_460_215_768, compressedSize: 3642),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j314cap.im4m",
        recordOffset: 12_460_219_522, compressedSize: 3705),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j314sap.im4m",
        recordOffset: 12_460_223_340, compressedSize: 3649),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j316cap.im4m",
        recordOffset: 12_460_227_102, compressedSize: 3700),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j316sap.im4m",
        recordOffset: 12_460_230_915, compressedSize: 3651),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j375cap.im4m",
        recordOffset: 12_460_234_679, compressedSize: 3576),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j375dap.im4m",
        recordOffset: 12_460_238_368, compressedSize: 3693),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j413ap.im4m",
        recordOffset: 12_460_242_174, compressedSize: 3771),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j414cap.im4m",
        recordOffset: 12_460_246_057, compressedSize: 3768),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j414sap.im4m",
        recordOffset: 12_460_249_938, compressedSize: 3768),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j415ap.im4m",
        recordOffset: 12_460_253_819, compressedSize: 3767),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j416cap.im4m",
        recordOffset: 12_460_257_698, compressedSize: 3769),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j416sap.im4m",
        recordOffset: 12_460_261_580, compressedSize: 3766),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j456ap.im4m",
        recordOffset: 12_460_265_459, compressedSize: 3578),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j457ap.im4m",
        recordOffset: 12_460_269_149, compressedSize: 3577),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j473ap.im4m",
        recordOffset: 12_460_272_838, compressedSize: 3523),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j474sap.im4m",
        recordOffset: 12_460_276_473, compressedSize: 3526),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j475cap.im4m",
        recordOffset: 12_460_280_112, compressedSize: 3521),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j475dap.im4m",
        recordOffset: 12_460_283_746, compressedSize: 3578),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.j493ap.im4m",
        recordOffset: 12_460_287_437, compressedSize: 3767),
      Read(
        name: "Firmware/Manifests/restore/macOS Customer/apticket.vma2macosap.im4m",
        recordOffset: 12_460_291_316, compressedSize: 3040),
      Read(
        name: "Firmware/SmartIOFirmware_ASCv5.im4p", recordOffset: 12_482_858_094,
        compressedSize: 68351),
      Read(
        name: "Firmware/agx/armfw_g14s.im4p", recordOffset: 12_485_042_186, compressedSize: 188975),
      Read(
        name: "Firmware/all_flash/DeviceTree.j414sap.im4p", recordOffset: 12_485_830_622,
        compressedSize: 51829),
      Read(
        name: "Firmware/all_flash/applelogo@2x~mac-USBc.im4p", recordOffset: 12_507_589_379,
        compressedSize: 7256),
      Read(
        name: "Firmware/all_flash/iBoot.j414s.RELEASE.im4p", recordOffset: 12_516_526_094,
        compressedSize: 838154),
      Read(
        name: "Firmware/all_flash/iBootData.j414s.RELEASE.im4p", recordOffset: 12_525_665_341,
        compressedSize: 52186),
      Read(
        name: "Firmware/ane/t602x_ane0_fw_selene_rc4x.im4p", recordOffset: 12_673_086_677,
        compressedSize: 292825),
      Read(
        name: "Firmware/ave/AppleAVE2FW_H14S.im4p", recordOffset: 12_681_021_251,
        compressedSize: 511644),
      Read(
        name: "Firmware/dcp/t602xdcp.im4p", recordOffset: 12_691_923_298, compressedSize: 3_279_107),
      Read(
        name: "Firmware/isp_bni/adc-helios-rc4x.im4p", recordOffset: 12_754_570_063,
        compressedSize: 3_389_462),
      Read(
        name: "Firmware/pmp/t6020pmp.im4p", recordOffset: 12_765_763_359, compressedSize: 184438),
      Read(name: "PlatformSupport.plist", recordOffset: 12_772_034_317, compressedSize: 652),
      Read(name: "RestoreVersion.plist", recordOffset: 12_772_036_072, compressedSize: 217),
      Read(name: "SystemVersion.plist", recordOffset: 12_772_036_359, compressedSize: 301),
      Read(
        name: "kernelcache.release.mac14j", recordOffset: 12_849_201_638, compressedSize: 25_855_947
      ),
      Read(
        name: "usr/standalone/bootcaches.plist", recordOffset: 12_893_071_816, compressedSize: 1590),
    ]
    /// The members read while the stub plan is built.
    static let thirteenFivePlanning: [Read] = [
      Read(name: "BuildManifest.plist", recordOffset: 12_219_894_834, compressedSize: 443716),
      Read(
        name: "usr/standalone/bootcaches.plist", recordOffset: 12_893_071_816, compressedSize: 1590),
      Read(name: "SystemVersion.plist", recordOffset: 12_772_036_359, compressedSize: 301),
    ]

    func testThirteenFiveNeedsMoreThanEightGigabytesFree() {
      // No AEA member: only the cache's floor, its ranges and the last range.
      let stage = NativeStubStagingRequirement(
        cacheBytes: NativeStubStagingRequirement.cacheBytes(reading: Self.thirteenFiveReads),
        largestDecodeBytes: 0)
      XCTAssertEqual(stage.cacheBytes, 728_376_625)
      XCTAssertEqual(stage.requiredFreeBytes, 11_474_183_473)
      XCTAssertGreaterThan(stage.requiredFreeBytes, lowFree)
      let shortfall = MacOSFreeSpaceShortfall(
        requiredBytes: stage.requiredFreeBytes, availableBytes: lowFree)
      XCTAssertEqual(
        shortfall.summary,
        "macOS needs 11.5 GB free to prepare the installation and has 8.9 GB. "
          + "Free up 2.6 GB, then try again.")

      // Planning counts the reads that build the plan and keeps a margin for
      // what is written to macOS before the stage starts.
      let planning = NativeStubStagingRequirement(
        cacheBytes: NativeStubStagingRequirement.cacheBytes(
          reading: Self.thirteenFiveReads + Self.thirteenFivePlanning)
          + NativeStubStagingRequirement.directoryBytes,
        largestDecodeBytes: 0)
      let planned = planning.requiredFreeBytes + NativeStubStagingEstimator.planningMarginBytes
      XCTAssertEqual(planned, 12_557_937_290)
      XCTAssertGreaterThan(planned, stage.requiredFreeBytes)
    }

    /// Reads Apple's restore images the way planning does: the 13.5 figure
    /// matches the recorded layout, the 26.6 image's encrypted members are
    /// found, and the 14.8.3 update archive plans like a restore image.
    func testOptInLiveEstimatesMatchTheRecordedLayouts() async throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_STAGING_ESTIMATE"] == "1" else {
        throw XCTSkip("Explicit live restore-image probe only")
      }
      let cdn = "https://updates.cdn-apple.com/"
      for (path, version, device, board, chip, size, decoded, expected):
        (
          String, String, String, UInt64, UInt64, Int, UInt64, UInt64
        ) in [
          (
            "2023SummerFCS/fullrestores/032-69606/D3E05CDF-E105-434C-A4A1-4E3DC7668DD0/"
              + "UniversalMac_13.5_22G74_Restore.ipsw", "13.5", "apple,j414s", 0x04, 0x6020,
            12_893_195_726, 0, 12_557_937_290
          ),
          (
            "2026SummerFCS/fullrestores/140-65618/10445B26-DE2C-43EC-9149-0A831602E74B/"
              + "UniversalMac_26.6_25G72_Restore.ipsw", "26.6", "apple,j700", 0x64, 0x8140,
            19_772_077_142, 1_140_850_688, 24_134_721_063
          ),
          // The update archive every M3 Mac uses: nothing to decrypt.
          (
            "2025FallFCS/patches/089-71124/49AD260A-D47F-4B5E-A793-30446187196E/"
              + "com_apple_MobileAsset_MacSoftwareUpdate/"
              + "f6d1ac9149f6a06401ff87fae5b262c420bfc5f7.zip", "14.8.3", "apple,j613", 0x30,
            0x8122, 13_637_436_385, 0, 12_480_289_559
          ),
          (
            "2025FallFCS/patches/089-71124/49AD260A-D47F-4B5E-A793-30446187196E/"
              + "com_apple_MobileAsset_MacSoftwareUpdate/"
              + "f6d1ac9149f6a06401ff87fae5b262c420bfc5f7.zip", "14.8.3", "apple,j514s", 0x04,
            0x6030, 13_637_436_385, 0, 12_475_888_172
          ),
        ]
      {
        let url = try XCTUnwrap(URL(string: cdn + path))
        let source = try await IPSWHTTPRangeReader.discover(url: url)
        XCTAssertEqual(source.sizeBytes, size)
        let started = Date()
        let requirement = try await NativeStubStagingRequirement.estimate(
          source: source,
          firmware: NativeFirmwareSelection(version: version, sourceURL: url, stubBytes: 0),
          deviceIdentifier: device, boardID: board, chipID: chip)
        XCTAssertEqual(requirement.largestDecodeBytes, decoded, version)
        XCTAssertEqual(
          requirement.requiredFreeBytes + NativeStubStagingEstimator.planningMarginBytes, expected,
          version)
        print(
          "Live \(version) \(device) estimate: \(requirement.cacheBytes) bytes cached, "
            + "in \(Date().timeIntervalSince(started)) s")
      }
    }

    func testAFreeExtentPlanIsRefusedBeforeApprovalWithTheNumbers() throws {
      // The free extent next to macOS: a free plan never shrinks macOS, so
      // nothing but this check stood between it and the stub stage.
      let free = candidate(kind: "free", source: "disk0", length: 42_949_672_960)
      let recommendation = try InstallerAllocationRecommendation(inventory: inventory([free]))
      XCTAssertThrowsError(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: lowFree,
          outstandingDownloadBytes: 0, stagingBytes: 12_557_937_290)
      ) {
        let shortfall = $0 as? MacOSFreeSpaceShortfall
        XCTAssertEqual(
          shortfall,
          MacOSFreeSpaceShortfall(requiredBytes: 12_557_937_290, availableBytes: lowFree))
        XCTAssertEqual(
          shortfall?.summary,
          "macOS needs 12.6 GB free to prepare the installation and has 8.9 GB. "
            + "Free up 3.7 GB, then try again.")
      }
      // The download still to come counts as well.
      XCTAssertThrowsError(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 20 * gib,
          outstandingDownloadBytes: 9 * gib, stagingBytes: 12 * gib)
      ) {
        XCTAssertEqual(
          $0 as? MacOSFreeSpaceShortfall,
          MacOSFreeSpaceShortfall(requiredBytes: 21 * gib, availableBytes: 20 * gib))
      }
      XCTAssertEqual(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 14 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 12_557_937_290),
        recommendation)
    }

    func testShrinkingMacOSKeepsWhatTheStubStageNeedsOrRefuses() throws {
      let resize = candidate(
        kind: "resize", source: "disk0s2", length: 400 * gib, minimumContainer: 200 * gib)
      let recommendation = try InstallerAllocationRecommendation(
        inventory: inventory([resize]), targetBytes: 190 * gib)
      // 200 GiB above the container floor, less the 8 GiB drift margin.
      XCTAssertEqual(recommendation.maximumBytes, 192 * gib)
      XCTAssertEqual(recommendation.requestedLengthBytes, 190 * gib)
      // macOS has room for the largest size and the stage: nothing changes.
      XCTAssertEqual(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 230 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 24 * gib),
        recommendation)
      // Less room: the largest size comes down to what leaves the stage its
      // space, and the requested size with it.
      let limited = try MacOSStagingAdmission.admit(
        recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 200 * gib,
        outstandingDownloadBytes: 6 * gib, stagingBytes: 24 * gib)
      XCTAssertEqual(limited.maximumBytes, 170 * gib)
      XCTAssertEqual(limited.requestedLengthBytes, 170 * gib)
      XCTAssertEqual(limited.minimumBytes, recommendation.minimumBytes)
      // Below the smallest size the plan is refused with the whole need.
      XCTAssertThrowsError(
        try MacOSStagingAdmission.admit(
          recommendation, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 40 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 24 * gib)
      ) {
        XCTAssertEqual(
          $0 as? MacOSFreeSpaceShortfall,
          MacOSFreeSpaceShortfall(
            requiredBytes: 24 * gib + recommendation.minimumBytes, availableBytes: 40 * gib))
      }
      // Shrinking another container leaves macOS's free space as it is.
      let other = try InstallerAllocationRecommendation(
        inventory: inventory([
          candidate(
            kind: "resize", source: "disk0s4", length: 400 * gib, minimumContainer: 200 * gib)
        ]))
      XCTAssertEqual(
        try MacOSStagingAdmission.admit(
          other, macOSStoreIdentifier: "disk0s2", macOSFreeBytes: 30 * gib,
          outstandingDownloadBytes: 0, stagingBytes: 24 * gib),
        other)
    }

    func testDecodingAnEncryptedRecoveryImageNeedsItTwiceAboveTheDecodeFloor() {
      // A 1.14 GB encrypted Recovery image.
      let recovery: UInt64 = 1_140_850_688
      let stage = NativeStubStagingRequirement(
        cacheBytes: 1_440_999_687, largestDecodeBytes: recovery)
      XCTAssertEqual(
        stage.requiredFreeBytes,
        NativeStubStagingRequirement.floorBytes + NativeStubStagingRequirement.decodeHeadroomBytes
          + 1_440_999_687 + 2 * recovery)
      XCTAssertEqual(stage.requiredFreeBytes, 23_050_053_895)
      // Once the member is staged, the decoder's own check is what is left.
      XCTAssertEqual(
        NativeStubStagingRequirement.decodeFreeBytes(memberBytes: recovery),
        (10 << 30) + recovery + (8 << 30))
    }

    func testRecordAndShortTailWindowsAreCountedOnceWhereMembersShareThem() {
      let window = NativeStubRestoreCache.windowBytes
      let prefix = NativeStubStagingRequirement.prefixBytes
      // Two short members in one window share it.
      let close = NativeStubStagingRequirement.cacheBytes(reading: [
        Read(name: "a", recordOffset: 10 * window, compressedSize: 100),
        Read(name: "b", recordOffset: 10 * window + 200, compressedSize: 100),
        Read(name: "a", recordOffset: 10 * window, compressedSize: 100),
      ])
      XCTAssertEqual(close, 200 + 2 * prefix + UInt64(window))
      // A long member's body is kept as read, plus its record's window and the
      // two its short final range can straddle.
      let long = NativeStubStagingRequirement.cacheBytes(reading: [
        Read(name: "c", recordOffset: 0, compressedSize: 100 * window)
      ])
      XCTAssertEqual(long, UInt64(100 * window) + prefix + 3 * UInt64(window))
    }

    func testShortfallSummaryAddsUpStaysPrintableAndSurvivesTheNotice() {
      let shortfall = MacOSFreeSpaceShortfall(
        requiredBytes: 21_250_000_001, availableBytes: 8_999_999_999)
      XCTAssertEqual(
        shortfall.summary,
        "macOS needs 21.3 GB free to prepare the installation and has 8.9 GB. "
          + "Free up 12.4 GB, then try again.")
      XCTAssertTrue(MacOSFreeSpaceShortfall.isSummary(shortfall.summary))
      XCTAssertFalse(
        MacOSFreeSpaceShortfall.isSummary("Native disk preparation could not be verified."))
      let notice = EngineFailureNotice(
        reason: .macOSSpaceRequired, exitStatus: 1, diskUnchanged: true,
        summary: shortfall.summary)
      XCTAssertEqual(notice.summary, shortfall.summary)
      XCTAssertLessThan(shortfall.summary.count, EngineFailureNotice.maximumSummaryCharacters)
      // A need just above what is free still asks for a tenth more.
      XCTAssertEqual(
        MacOSFreeSpaceShortfall(requiredBytes: 12_000_000_001, availableBytes: 12_000_000_000)
          .summary,
        "macOS needs 12.1 GB free to prepare the installation and has 12.0 GB. "
          + "Free up 0.1 GB, then try again.")
    }

    func testWindowedReaderSharesShortReadsAndPassesLongOnesThrough() async throws {
      final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var reads = [Int]()
      }
      struct Source: FirmwareRangeReading {
        let counter: Counter
        var sizeBytes: Int { 8 << 20 }
        func read(offset: Int, count: Int) async throws -> Data {
          counter.lock.withLock { counter.reads.append(count) }
          return Data((offset..<(offset + count)).map { UInt8(truncatingIfNeeded: $0) })
        }
      }
      let counter = Counter()
      let reader = NativeWindowedRangeReader(Source(counter: counter))
      let first = try await reader.read(offset: 100, count: 30)
      let second = try await reader.read(offset: 4000, count: 30)
      XCTAssertEqual(first, Data((100..<130).map { UInt8(truncatingIfNeeded: $0) }))
      XCTAssertEqual(second, Data((4000..<4030).map { UInt8(truncatingIfNeeded: $0) }))
      // A short read across a window edge reads both windows once.
      let edge = try await reader.read(offset: (1 << 20) - 10, count: 20)
      XCTAssertEqual(
        edge, Data((((1 << 20) - 10)..<((1 << 20) + 10)).map { UInt8(truncatingIfNeeded: $0) }))
      _ = try await reader.read(offset: 1 << 20, count: 4 << 20)
      XCTAssertEqual(counter.reads, [1 << 20, 1 << 20, 4 << 20])
    }

    func testM3MacsPlanTheirStubFromTheUpdateArchiveAndRefuseOnlyADeltaImage() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let data = try JSONSerialization.data(withJSONObject: [
        "os_list": [
          [
            "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
            "partitions": [["size": "1GiB"]],
          ]
        ]
      ])
      let url = root.appendingPathComponent("metadata.json")
      try data.write(to: url)
      let metadata = StagedInstallerArtifact(
        artifact: try PinnedInstallerArtifact(
          role: "metadata", sourceURL: URL(string: "https://example.com/metadata.json")!,
          fileName: "metadata.json", expectedDigest: SHA256Digest(hashing: data).rawValue,
          expectedSizeBytes: UInt64(data.count)),
        fileURL: url, reusedExistingFile: false)
      // An M3 MacBook Air on macOS 15 and on macOS 26.6.2: the policy's last
      // compatible firmware for both is 14.8.3, which Apple ships only as an
      // update archive. Planning reads that archive like a restore image.
      let vectors = try NativeUpdateArchiveTests.vectors()
      let source = try NativeUpdateArchiveTests.updateArchive()
      for (device, board, hardware) in [
        (
          "apple,j615", UInt64(0x32),
          NativeInspectionHardware(
            chipID: 0x8122, bootVersion: "iBoot-11881.1.1", macOSVersion: "15.1",
            recoveryVersion: "24.1.0.0.0,0")
        ),
        (
          "apple,j613", UInt64(0x30),
          NativeInspectionHardware(
            chipID: 0x8122, bootVersion: "mBoot-18000.161.10", macOSVersion: "26.6.2",
            recoveryVersion: "25.7.83.0.0,0")
        ),
      ] {
        for name in ["full", "delta", "no-image", "delta-incomplete"] {
          let archive = try vectors.archive(name)
          let estimator = NativeStubStagingEstimator(
            facts: { .init(deviceIdentifier: device, hardware: hardware) }, boardID: { board },
            open: { url in
              XCTAssertEqual(url, source)
              return NativeStubFileTests.Source(bytes: archive)
            })
          do {
            let bytes = try await estimator.requiredFreeBytes(
              deviceIdentifier: device, metadata: metadata)
            XCTAssertEqual(name, "full", "\(device): \(name) was admitted")
            let expected = try await NativeStubStagingRequirement.estimate(
              source: NativeStubFileTests.Source(bytes: archive),
              firmware: NativeUpdateArchiveTests.selection(source), deviceIdentifier: device,
              boardID: board, chipID: 0x8122)
            XCTAssertEqual(
              bytes, expected.requiredFreeBytes + NativeStubStagingEstimator.planningMarginBytes,
              device)
            XCTAssertEqual(expected.largestDecodeBytes, 0, device)
          } catch {
            XCTAssertNotEqual(name, "full", "\(device): \(error)")
            XCTAssertEqual(
              error as? InstallerPlanPreparationError,
              .firmwareArchiveUnsupported(version: "14.8.3"), device)
          }
        }
      }
    }

    func testAMachOMacIsRefusedAtPlanningWhenTheReleaseLacksItsStartupSoftware() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      func staged(_ extra: [String: Any]) throws -> StagedInstallerArtifact {
        var template: [String: Any] = [
          "omarchy_target": "apple-silicon-full-os", "default_os_name": "Fixture",
          "partitions": [["size": "1GiB"]],
        ]
        template.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["os_list": [template]])
        let url = root.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url)
        return StagedInstallerArtifact(
          artifact: try PinnedInstallerArtifact(
            role: "metadata", sourceURL: URL(string: "https://example.com/metadata.json")!,
            fileName: "metadata.json", expectedDigest: SHA256Digest(hashing: data).rawValue,
            expectedSizeBytes: UInt64(data.count)),
          fileURL: url, reusedExistingFile: false)
      }
      struct Opened: Error {}
      let neo = NativeInspectionHardware(
        chipID: 0x8140, bootVersion: "mBoot-18000.161.10", macOSVersion: "26.6.2",
        recoveryVersion: "25.7.83.0.0,0")
      // Opening the restore image is as far as an admitted plan gets here.
      let estimator = NativeStubStagingEstimator(
        facts: { .init(deviceIdentifier: "apple,j700", hardware: neo) }, boardID: { 0x64 },
        open: { _ in throw Opened() })
      let qualified: [String: Any] = [
        "aurora_stage1": [
          "kind": "common-raw-v1", "qualified_machines": ["j700ap": ["26.6", "26.6.2"]],
        ]
      ]
      func declaring(_ stage1: Bool, _ confined: [String]) -> [String: Any] {
        qualified.merging([
          "aurora_macho_boot": [
            "kind": "padded-ctxr-v1",
            "stage1_member": stage1 ? "esp/aurora/stage1.macho" as Any : NSNull(),
            "confined_members": confined,
          ]
        ]) { _, new in new }
      }
      for (extra, refused) in [
        ([:], true), (declaring(true, []), true),
        (declaring(false, ["esp/m1n1/boot-ctxr.bin"]), true),
        (qualified, false), (declaring(true, ["esp/m1n1/boot-ctxr-j700.bin"]), false),
      ] as [([String: Any], Bool)] {
        // Before anything downloads: the restore image is never opened for this.
        let metadata = try staged(extra)
        func check() throws {
          try estimator.refuseUnstartableMachO(deviceIdentifier: "apple,j700", metadata: metadata)
        }
        if refused {
          XCTAssertThrowsError(try check()) {
            let error = $0 as? InstallerPlanPreparationError
            XCTAssertEqual(error, .releaseLacksMachOStartup, "\(extra)")
          }
        } else {
          XCTAssertNoThrow(try check(), "\(extra)")
        }
      }
      // An M3 Mac enrolls the unpadded object: it needs the object and its
      // qualification, but no confined Stage 2.
      let m3 = NativeStubStagingEstimator(
        facts: {
          .init(
            deviceIdentifier: "apple,j613",
            hardware: NativeInspectionHardware(
              chipID: 0x8122, bootVersion: "mBoot-18000.161.10", macOSVersion: "26.6.2",
              recoveryVersion: "25.7.83.0.0,0"))
        }, boardID: { 0x30 }, open: { _ in throw Opened() })
      let m3Qualified: [String: Any] = [
        "aurora_stage1": [
          "kind": "common-raw-v1", "qualified_machines": ["j613ap": ["14.8.3"]],
        ]
      ]
      for (extra, refused) in [
        ([:], true),
        (
          m3Qualified.merging([
            "aurora_macho_boot": [
              "kind": "padded-ctxr-v1", "stage1_member": NSNull(), "confined_members": [],
            ]
          ]) { _, new in new }, true
        ),
        (m3Qualified, false),
        (
          m3Qualified.merging([
            "aurora_macho_boot": [
              "kind": "padded-ctxr-v1", "stage1_member": "esp/aurora/stage1.macho",
              "confined_members": [],
            ]
          ]) { _, new in new }, false
        ),
      ] as [([String: Any], Bool)] {
        let metadata = try staged(extra)
        if refused {
          XCTAssertThrowsError(
            try m3.refuseUnstartableMachO(deviceIdentifier: "apple,j613", metadata: metadata),
            "\(extra)")
        } else {
          XCTAssertNoThrow(
            try m3.refuseUnstartableMachO(deviceIdentifier: "apple,j613", metadata: metadata),
            "\(extra)")
        }
      }
    }

    private func inventory(_ candidates: [ValidatedEngineCandidate]) -> ValidatedEngineInventory {
      ValidatedEngineInventory(
        layoutDigest: "sha256:" + String(repeating: "a", count: 64),
        systemStoreIdentifier: "disk0", candidates: candidates)
    }

    private func candidate(
      kind: String, source: String, length: UInt64, minimumContainer: UInt64 = 0
    ) -> ValidatedEngineCandidate {
      ValidatedEngineCandidate(
        kind: kind, sourceIdentifier: source, offsetBytes: 0, lengthBytes: length,
        minimumInstallBytes: 32 << 30, minimumContainerBytes: minimumContainer,
        identityDigest: nil, recommendedInstallBytes: nil)
    }
  }
#endif
