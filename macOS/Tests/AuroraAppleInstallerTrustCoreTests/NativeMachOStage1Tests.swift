#if os(macOS)
  import AuroraFirmware
  import Foundation
  import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeMachOStage1Tests: XCTestCase, @unchecked Sendable {
    /// A minimal boot object laid out as aura's tools/macho_boot_object.py lays
    /// one out: `raw` at the start of __TEXT_EXEC, entered at its offset 0x800.
    static func object(wrapping raw: Data) -> Data {
      let base: UInt64 = 0xFFFF_FE00_0700_4000
      let code = UInt64((raw.count + 0x3FFF) & ~0x3FFF)
      let segments: [(String, UInt64, UInt64)] = [
        ("__TEXT", 0, 0x8000), ("__PRELINK_TEXT", 0x8000, 0x8000), ("__TEXT_EXEC", 0x10000, code),
        ("__PRELINK_INFO", 0x10000 + code, 0x4000), ("__DATA", 0x14000 + code, 0x4000),
        ("__LINKEDIT", 0x18000 + code, 0x4000),
      ]
      func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
      }
      var commands: [UInt8] = []
      for (name, offset, size) in segments {
        commands += le(UInt32(0x19)) + le(UInt32(72))
        commands += Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
        commands += le(base + offset) + le(size) + le(offset) + le(size)
        commands += le(UInt32(1)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(0))
      }
      var registers = [UInt64](repeating: 0, count: 34)
      registers[32] = base + 0x10800
      commands += le(UInt32(5)) + le(UInt32(16 + 34 * 8)) + le(UInt32(6)) + le(UInt32(0x44))
      for register in registers { commands += le(register) }
      var bytes = le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0xC000_0002))
      bytes += le(UInt32(12)) + le(UInt32(segments.count + 1)) + le(UInt32(commands.count))
      bytes += le(UInt32(0)) + le(UInt32(0)) + commands
      var result = Data(bytes + [UInt8](repeating: 0, count: Int(0x1C000 + code) - bytes.count))
      result.replaceSubrange(0x10000..<(0x10000 + raw.count), with: raw)
      return result
    }

    func testChipPredicateSplitsTheInspectionPolicyTableAtM4() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let chips = try policy.chipMinimum.keys.map { try XCTUnwrap(UInt64($0)) }
      XCTAssertFalse(chips.isEmpty)
      // The table's M4-generation and later chips: T6040 (M4 Pro), T6041 (M4 Max),
      // T6050 (M5 Pro and Max), T8132 (M4), T8140 (A18 Pro), T8142 (M5) and T8152 (M6).
      XCTAssertEqual(
        Set(chips.filter { AuraStage1Format.usesExecuteWindow(chipID: $0) }),
        [0x6040, 0x6041, 0x6050, 0x8132, 0x8140, 0x8142, 0x8152])
      for chip in chips where !AuraStage1Format.usesExecuteWindow(chipID: chip) {
        XCTAssertTrue(chip < 0x6040 || (0x8000..<0x8130).contains(chip), String(chip, radix: 16))
      }
    }

    func testMachOStage1IsFilledFromTheEnrolledRawStage1() async throws {
      let fixture = try await NativeESPFileTests.Fixture(machO: true)
      try await fixture.prepare()
      let receipt = try JSONDecoder().decode(
        NativeESPFilesExecution.Receipt.self, from: Data(contentsOf: fixture.receipt))
      let system = fixture.images.base.mounts.appendingPathComponent("disk8s1")
      let raw = try Data(
        contentsOf: system.appendingPathComponent(NativeESPFilesExecution.stage1Path))
      let machO = try Data(
        contentsOf: system.appendingPathComponent(NativeESPFilesExecution.stage1MachOPath))
      let object = try XCTUnwrap(fixture.plan.stage1MachO)
      XCTAssertEqual(machO, try MachOBootObject.fill(object, raw: fixture.plan.stage1, filled: raw))
      XCTAssertEqual(machO.subdata(in: 0x10000..<(0x10000 + raw.count)), raw)
      XCTAssertEqual(receipt.stage1MachO?.bytes, machO.count)
      XCTAssertEqual(receipt.stage1MachO?.sha256, NativeStubFileStore.hash(machO))
      // A padded Stage 1 chainloads the confined Stage 2 on this ESP.
      for image in [machO, raw] {
        let configuration = try Stage1Configuration.read(image)
        XCTAssertEqual(configuration.stage2Path, "m1n1/boot-ctxr.bin")
        XCTAssertEqual(configuration.espUUID, receipt.espUUID.lowercased())
      }
      let before = try Data(contentsOf: fixture.receipt)
      try await fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }

    func testRetargetingAFilledStage1MatchesFillingItForThatPath() async throws {
      let plan = try await NativeESPFileTests.plan()
      func filled(_ path: String) throws -> Data {
        try NativeBootChain.fillStage1(
          plan.stage1, uuid: "3ce364b1-1de6-4418-a00d-5b2d95884ad7", path: path,
          windowMilliseconds: 5000)
      }
      XCTAssertEqual(
        try Stage1Configuration.retargeted(
          filled("m1n1/boot.bin"), stage2Path: "m1n1/boot-ctxr.bin"),
        try filled("m1n1/boot-ctxr.bin"))
      let object = Self.object(wrapping: plan.stage1)
      let carried = try MachOBootObject.fill(
        object, raw: plan.stage1, filled: filled("m1n1/boot.bin"))
      XCTAssertEqual(
        try Stage1Configuration.retargeted(carried, stage2Path: "m1n1/boot-ctxr.bin"),
        try MachOBootObject.fill(object, raw: plan.stage1, filled: filled("m1n1/boot-ctxr.bin")))
    }

    func testAnUnpaddedStage1ReceiptRecordsTheObject() async throws {
      let fixture = try await NativeESPFileTests.Fixture()
      try await fixture.prepare()
      let bootBin = fixture.images.base.mounts.appendingPathComponent(
        "disk8s1/" + NativeESPFilesExecution.stage1Path)
      XCTAssertEqual(
        try Stage1Configuration.read(Data(contentsOf: bootBin)).stage2Path, "m1n1/boot.bin")
      let receipt =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: fixture.receipt)) as! [String: Any]
      XCTAssertEqual(
        Set(receipt.keys),
        [
          "plan", "firmware", "groupUUID", "espUUID", "files", "icon", "stage1", "stage1MachO",
          "executeWindow",
        ])
      XCTAssertEqual(receipt["executeWindow"] as? Bool, false)
      let system = fixture.images.base.mounts.appendingPathComponent("disk8s1")
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: system.appendingPathComponent(NativeESPFilesExecution.stage1MachOPath).path))
    }

    func testAnObjectForAnotherStage1IsRefused() async throws {
      let fixture = try await NativeESPFileTests.Fixture(machOSource: {
        var other = $0
        other[0x100] ^= 0xFF
        return other
      })
      do {
        try await fixture.prepare()
        XCTFail("A Mach-O object for another Stage 1 was filled")
      } catch {}
    }

    /// `raw` with aura's load header, as padding requires, and its trailer kept last.
    static func loadable(_ raw: Data) -> Data {
      func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
      }
      var image = Data(raw.dropLast(8))
      image.append(Data(count: MachOBootObject.loadHeaderOffset - image.count))
      image.append(contentsOf: Array("AURALOAD".utf8) + le(UInt32(1)) + le(UInt32(1)))
      image.append(contentsOf: le(UInt64(0x18000)) + le(UInt64(0)))
      return image + raw.suffix(8)
    }

    /// The fixture payload with its Stage 1 made `loadable`, and with
    /// `esp/aurora/stage1.macho` and `extra` added by zip(1).
    static func payload(
      extra: [String] = ["esp/m1n1/boot-ctxr.bin"], extraBytes: [String: Int] = [:],
      machO: @escaping (Data) -> Data
    ) async throws -> (Data, Data, Data) {
      let (metadata, payload, _) = try NativeESPFileTests.inputs()
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let member = try XCTUnwrap(archive.members.first { $0.name == "esp/aurora/stage1.bin" })
      let raw = loadable(try await archive.read(member, maximumBytes: 64 << 20))
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-macho-payload-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let object = machO(raw)
      let path = directory.appendingPathComponent("esp/aurora/stage1.macho")
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try object.write(to: path)
      let stage1 = directory.appendingPathComponent("esp/aurora/stage1.bin")
      try raw.write(to: stage1)
      for name in extra {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: extraBytes[name] ?? 16).write(to: file)
      }
      let zip = directory.appendingPathComponent("payload.zip")
      try payload.write(to: zip)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments =
        ["-q", "-X", "-0", zip.path, "esp/aurora/stage1.macho", "esp/aurora/stage1.bin"] + extra
      process.currentDirectoryURL = directory
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
      return (metadata, try Data(contentsOf: zip), object)
    }

    func testAdmissionPairsTheObjectWithTheCommonStage1OnlyWhenAsked() async throws {
      let (metadata, payload, object) = try await Self.payload { Self.object(wrapping: $0) }
      for machO in [false, true] {
        let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
        let plan = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive, device: "apple,j700", firmware: "26.6.2",
          executeWindow: machO)
        // Every Mac enrolls the object; only the window decides padding and Stage 2.
        XCTAssertEqual(try XCTUnwrap(plan).stage1MachO, object)
        XCTAssertEqual(try XCTUnwrap(plan).executeWindow, machO)
        XCTAssertEqual(
          try XCTUnwrap(plan).stage2Path, machO ? "m1n1/boot-ctxr.bin" : "m1n1/boot.bin")
        XCTAssertEqual(
          try XCTUnwrap(plan).entries.first { $0.member.name == "esp/aurora/stage1.macho" }?.path,
          "aurora/stage1.macho")
        XCTAssertEqual(
          try XCTUnwrap(plan).entries.contains { $0.path == "m1n1/boot-ctxr.bin" }, machO)
      }
      let (_, mismatched, _) = try await Self.payload {
        var other = $0
        other[0x100] ^= 0xFF
        return Self.object(wrapping: other)
      }
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: mismatched))
      do {
        _ = try await NativeESPPayloadPlan.make(
          metadata: metadata, archive: archive, device: "apple,j700", firmware: "26.6.2",
          executeWindow: true)
        XCTFail("A Mach-O object for another Stage 1 was admitted")
      } catch let error as NativeBootChainError {
        XCTAssertEqual(error, .invalidStage1)
      }
    }

    private func admit(
      _ payload: Data, metadata: Data, machO: Bool, device: String = "apple,j700",
      firmware: String = "26.6.2"
    ) async throws -> NativeBootChainAdmission {
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      return try await NativeBootChain.admit(
        metadata: metadata, archive: archive, deviceIdentifier: device, firmware: firmware,
        executeWindow: machO)
    }

    func testNoChipHasARawOrBoardStage1Fallback() async throws {
      // No Mach-O object in the payload: refused on every chip, never the raw image.
      let (metadata, plain, _) = try NativeESPFileTests.inputs(withObject: false)
      for machO in [true, false] {
        do {
          _ = try await admit(plain, metadata: metadata, machO: machO)
          XCTFail("The raw Stage 1 was admitted (window \(machO))")
        } catch {
          XCTAssertEqual(error as? NativeBootChainError, .missingMachOStage1)
        }
      }
      // A firmware the common Stage 1 isn't qualified on has no board fallback either:
      // stage1-j700.bin and stage1-j613.bin have no boot object.
      let (_, withObject, _) = try await Self.payload { Self.object(wrapping: $0) }
      for machO in [true, false] {
        do {
          _ = try await admit(withObject, metadata: metadata, machO: machO, firmware: "1.0")
          XCTFail("Fell back to the board's raw Stage 1 (window \(machO))")
        } catch {
          XCTAssertEqual(error as? NativeBootChainError, .missingMachOStage1)
        }
      }
    }

    func testAnM1ToM3MacStagesTheUnpaddedMachOObject() async throws {
      let (metadata, payload, object) = try await Self.payload { Self.object(wrapping: $0) }
      for device in ["apple,j700", "apple,j413", "apple,j316s"] {
        let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
        let admitted = try? await NativeBootChain.admit(
          metadata: metadata, archive: archive, deviceIdentifier: device, firmware: "26.6.2",
          executeWindow: false)
        // The fixture qualifies the common Stage 1 for j700ap only; others are refused, not raw.
        guard let admitted else { continue }
        XCTAssertEqual(admitted.stage1MachOMember, NativeBootChain.commonStage1MachO, device)
        XCTAssertFalse(admitted.executeWindow, device)
        XCTAssertNil(admitted.expandedStage1Bytes, device)
        XCTAssertEqual(admitted.stage2Path, "m1n1/boot.bin", device)
      }
      let fixture = try await NativeESPFileTests.Fixture()
      XCTAssertFalse(fixture.plan.executeWindow)
      try await fixture.prepare()
      let receipt = try JSONDecoder().decode(
        NativeESPFilesExecution.Receipt.self, from: Data(contentsOf: fixture.receipt))
      let system = fixture.images.base.mounts.appendingPathComponent("disk8s1")
      let enrolled = try Data(
        contentsOf: system.appendingPathComponent(NativeESPFilesExecution.stage1MachOPath))
      try MachOBootObject.check(enrolled)
      XCTAssertEqual(receipt.stage1MachO?.sha256, NativeStubFileStore.hash(enrolled))
      XCTAssertEqual(receipt.executeWindow, false)
      XCTAssertEqual(try Stage1Configuration.read(enrolled).stage2Path, "m1n1/boot.bin")
      // Its size is the object's own: nothing is padded.
      XCTAssertEqual(enrolled.count, try XCTUnwrap(fixture.plan.stage1MachO).count)
      _ = object
    }

    func testAMachOChipGetsBothStage2FilesAndARawChipOnlyItsOwn() async throws {
      let (metadata, payload, _) = try await Self.payload { Self.object(wrapping: $0) }
      let machO = try await admit(payload, metadata: metadata, machO: true)
      XCTAssertEqual(machO.stage2Path, "m1n1/boot-ctxr.bin")
      XCTAssertEqual(machO.espLayout["esp/m1n1/boot-ctxr.bin"], "m1n1/boot-ctxr.bin")
      XCTAssertEqual(machO.espLayout.values.filter { $0 == "m1n1/boot.bin" }.count, 1)
      let raw = try await admit(payload, metadata: metadata, machO: false)
      XCTAssertEqual(raw.stage2Path, "m1n1/boot.bin")
      XCTAssertNil(raw.espLayout["esp/m1n1/boot-ctxr.bin"])
      XCTAssertFalse(raw.espLayout.values.contains("m1n1/boot-ctxr.bin"))
      XCTAssertEqual(raw.espLayout.values.filter { $0 == "m1n1/boot.bin" }.count, 1)
    }

    func testABoardsOwnConfinedStage2WinsOverTheSharedOne() async throws {
      let (metadata, payload, _) = try await Self.payload(
        extra: ["esp/m1n1/boot-ctxr.bin", "esp/m1n1/boot-ctxr-j700.bin"]
      ) { Self.object(wrapping: $0) }
      let layout = try await admit(payload, metadata: metadata, machO: true).espLayout
      XCTAssertEqual(layout["esp/m1n1/boot-ctxr-j700.bin"], "m1n1/boot-ctxr.bin")
      XCTAssertNil(layout["esp/m1n1/boot-ctxr.bin"])
      XCTAssertEqual(layout.values.filter { $0 == "m1n1/boot-ctxr.bin" }.count, 1)
      // Another board's file is never installed.
      let (_, other, _) = try await Self.payload(extra: ["esp/m1n1/boot-ctxr-j999.bin"]) {
        Self.object(wrapping: $0)
      }
      do {
        _ = try await admit(other, metadata: metadata, machO: true)
        XCTFail("Installed another board's confined Stage 2")
      } catch {
        XCTAssertEqual(error as? NativeBootChainError, .missingConfinedStage2)
      }
    }

    func testAConfinedStage2LargerThanAurasSlotIsRefused() async throws {
      let name = "esp/m1n1/boot-ctxr.bin"
      let (metadata, fits, _) = try await Self.payload(extraBytes: [name: 16 << 20]) {
        Self.object(wrapping: $0)
      }
      _ = try await admit(fits, metadata: metadata, machO: true)
      let (_, large, _) = try await Self.payload(extraBytes: [name: (16 << 20) + 1]) {
        Self.object(wrapping: $0)
      }
      do {
        _ = try await admit(large, metadata: metadata, machO: true)
        XCTFail("A Stage 2 larger than the slot was admitted")
      } catch {
        XCTAssertEqual(error as? NativeBootChainError, .confinedStage2TooLarge)
      }
      // A raw chip never receives the file, so its size is no concern there.
      _ = try await admit(large, metadata: metadata, machO: false)
    }

    func testAdmissionRefusesAnObjectRecoveryCouldNotPad() async throws {
      let (metadata, payload, object) = try await Self.payload { Self.object(wrapping: $0) }
      let admitted = try await admit(payload, metadata: metadata, machO: true)
      let padded = try MachOBootObject.expandExecuteWindow(object)
      XCTAssertEqual(admitted.expandedStage1Bytes, padded.size)
      XCTAssertGreaterThan(try XCTUnwrap(admitted.expandedStage1Bytes), 146 << 20)
      let raw = try await admit(payload, metadata: metadata, machO: false)
      XCTAssertNil(raw.expandedStage1Bytes)
      XCTAssertEqual(raw.stage1MachOMember, NativeBootChain.commonStage1MachO)
      // No aura load header: it fills, but Recovery would refuse to pad it.
      let (_, unpaddable, _) = try await Self.payload {
        var other = $0
        other.replaceSubrange(
          MachOBootObject.loadHeaderOffset..<(MachOBootObject.loadHeaderOffset + 8),
          with: Data(count: 8))
        return Self.object(wrapping: other)
      }
      do {
        _ = try await admit(unpaddable, metadata: metadata, machO: true)
        XCTFail("Admitted an object that can't be padded")
      } catch {
        XCTAssertEqual(error as? NativeBootChainError, .invalidStage1)
      }
    }

    func testEnrollmentSpaceCountsThePaddedObjectsWholeSizeBeforePartitioning() throws {
      let expanded: UInt64 = 153_190_400
      let reserve = NativeEnrollmentSpace.recoveryDataBytes
      XCTAssertNoThrow(
        try NativeEnrollmentSpace.require(
          stubBytes: 5_999_951_872, restoredBytes: 3 << 30, expandedStage1: expanded))
      let exact = 1 << 30 + reserve + expanded
      XCTAssertNoThrow(
        try NativeEnrollmentSpace.require(
          stubBytes: exact, restoredBytes: 1 << 30, expandedStage1: expanded))
      XCTAssertThrowsError(
        try NativeEnrollmentSpace.require(
          stubBytes: exact - 1, restoredBytes: 1 << 30, expandedStage1: expanded)
      ) {
        XCTAssertEqual(
          $0 as? NativeStubFileError,
          .noRoomForStage1(requiredBytes: exact, stubBytes: exact - 1))
      }
      XCTAssertThrowsError(
        try NativeEnrollmentSpace.require(
          stubBytes: .max, restoredBytes: .max, expandedStage1: expanded))
      let (reason, summary) = NativeInstallerExecutor.preflightFailure(
        stage: .stubFiles,
        error: NativeStubFileError.noRoomForStage1(requiredBytes: 2, stubBytes: 1))
      XCTAssertEqual(reason, .planIntegrity)
      XCTAssertTrue(summary.contains("Nothing on the disk changed"), summary)
    }

    /// `metadata` with the `aurora_macho_boot` declaration the assembler writes.
    static func declaring(_ metadata: Data, stage1: Bool, confined: [String]) throws -> Data {
      var document = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
      var templates = document["os_list"] as! [[String: Any]]
      templates[0]["aurora_macho_boot"] = [
        "kind": "padded-ctxr-v1",
        "stage1_member": stage1 ? "esp/aurora/stage1.macho" as Any : NSNull(),
        "confined_members": confined,
      ]
      document["os_list"] = templates
      return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    func testMetadataThatDeclaresTheMachOFilesMustMatchThePayload() async throws {
      let (metadata, payload, _) = try await Self.payload { Self.object(wrapping: $0) }
      let matching = try Self.declaring(
        metadata, stage1: true, confined: ["esp/m1n1/boot-ctxr.bin"])
      for machO in [true, false] {
        _ = try await admit(payload, metadata: matching, machO: machO)
      }
      for (stage1, confined) in [
        (false, ["esp/m1n1/boot-ctxr.bin"]), (true, []),
        (true, ["esp/m1n1/boot-ctxr.bin", "esp/m1n1/boot-ctxr-j700.bin"]),
      ] {
        let wrong = try Self.declaring(metadata, stage1: stage1, confined: confined)
        do {
          _ = try await admit(payload, metadata: wrong, machO: false)
          XCTFail("Metadata that disagrees with its payload was admitted: \(confined)")
        } catch {
          XCTAssertEqual(error as? NativePayloadPreflightError, .invalidMetadata)
        }
      }
    }

    func testMetadataRefusesAMachOMacBeforeAnythingLargeDownloads() throws {
      let (metadata, _, _) = try NativeESPFileTests.inputs()
      func refusal(_ metadata: Data, device: String = "apple,j700", firmware: String = "26.6.2")
        throws -> NativeBootChainError?
      {
        try NativeBootChain.machORefusal(
          metadata: metadata, deviceIdentifier: device, firmware: firmware)
      }
      // Metadata from before the declaration only tells the Stage 1 qualification.
      XCTAssertNil(try refusal(metadata))
      XCTAssertEqual(try refusal(metadata, firmware: "1.0"), .missingMachOStage1)
      func declared(_ stage1: Bool, _ confined: [String]) throws -> Data {
        try Self.declaring(metadata, stage1: stage1, confined: confined)
      }
      XCTAssertEqual(try refusal(declared(false, ["esp/m1n1/boot-ctxr.bin"])), .missingMachOStage1)
      XCTAssertEqual(try refusal(declared(true, [])), .missingConfinedStage2)
      XCTAssertEqual(
        try refusal(declared(true, ["esp/m1n1/boot-ctxr-j616s.bin"])), .missingConfinedStage2)
      XCTAssertNil(try refusal(declared(true, ["esp/m1n1/boot-ctxr-j700.bin"])))
      XCTAssertNil(try refusal(declared(true, ["esp/m1n1/boot-ctxr.bin"])))
      // A declaration this installer can't read refuses the metadata.
      XCTAssertThrowsError(try refusal(declared(true, ["esp/m1n1/other.bin"])))
      // M1 to M3 need the boot object too, but no confined Stage 2.
      func standard(_ metadata: Data, firmware: String = "26.6.2") throws -> NativeBootChainError? {
        try NativeBootChain.machORefusal(
          metadata: metadata, deviceIdentifier: "apple,j700", firmware: firmware,
          executeWindow: false)
      }
      XCTAssertNil(try standard(metadata))
      XCTAssertEqual(try standard(metadata, firmware: "1.0"), .missingMachOStage1)
      XCTAssertEqual(try standard(declared(false, [])), .missingMachOStage1)
      XCTAssertNil(try standard(declared(true, [])))
    }

    func testAReleaseWithoutTheMachOFilesSaysSoInPlainWords() {
      for error in [
        NativeBootChainError.missingMachOStage1, .missingConfinedStage2, .confinedStage2TooLarge,
      ] {
        for (reason, summary) in [
          NativeInstallerExecutor.payloadFailure(error),
          NativeInstallerExecutor.preflightFailure(stage: .espFiles, error: error),
        ] {
          XCTAssertEqual(reason, .deviceUnsupported)
          XCTAssertEqual(summary, NativeBootChainError.releaseLacksMachOSummary)
          XCTAssertFalse(summary.contains(String(describing: error)), summary)
        }
        XCTAssertEqual(
          NativeInstallerExecutor.preservedSummary(for: error),
          NativeBootChainError.releaseLacksMachOSummary)
        // A reset shows the same unsupported-Mac screen.
        XCTAssertEqual(NativeInstallerExecutor.preservedReason(for: error), .deviceUnsupported)
      }
      XCTAssertTrue(
        NativeBootChainError.releaseLacksMachOSummary.contains("doesn't support this Mac yet"))
      // A file that failed a check still reads as one.
      XCTAssertEqual(
        NativeInstallerExecutor.payloadFailure(NativeBootChainError.invalidStage1).0,
        .planIntegrity)
    }

    func testAPayloadWithoutTheConfinedStage2IsRefusedOnAMachOChip() async throws {
      let (metadata, payload, _) = try await Self.payload(extra: []) { Self.object(wrapping: $0) }
      do {
        _ = try await admit(payload, metadata: metadata, machO: true)
        XCTFail("A padded Stage 1 was admitted with nothing to load")
      } catch {
        XCTAssertEqual(error as? NativeBootChainError, .missingConfinedStage2)
      }
      // The dry run still reports the rest of the chain for such a payload.
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let reported = try await NativeBootChain.admit(
        metadata: metadata, archive: archive, deviceIdentifier: "apple,j700", firmware: "26.6.2",
        executeWindow: true, requireConfinedStage2: false)
      XCTAssertEqual(reported.stage1MachOMember, NativeBootChain.commonStage1MachO)
    }

    func testRecoveryPayloadRecordsTheChipsBootMode() async throws {
      for machO in [false, true] {
        let fixture = try await NativeInstallationFinishingTests.Fixture(machO: machO)
        _ = try await fixture.prepareVendor()
        try await fixture.prepareRecovery()
        let data = fixture.system.appendingPathComponent("Aurora/Recovery/InstallData")
        let config =
          try JSONSerialization.jsonObject(
            with: Data(contentsOf: data.appendingPathComponent("install-config.json")))
          as! [String: Any]
        let manifest =
          try JSONSerialization.jsonObject(
            with: Data(contentsOf: data.appendingPathComponent("AuraPayloads/manifest.json")))
          as! [String: Any]
        let mode = machO ? "macho" : "macho-standard"
        let stage2Path = machO ? "m1n1/boot-ctxr.bin" : "m1n1/boot.bin"
        XCTAssertEqual(config["bootMode"] as? String, mode)
        XCTAssertEqual(config["stage2Path"] as? String, stage2Path)
        XCTAssertEqual(manifest["defaultMode"] as? String, mode)
        XCTAssertEqual(manifest["nestedVirtualization"] != nil, !machO)
        if !machO { XCTAssertEqual(manifest["nestedVirtualization"] as? Bool, false) }
        let modes = try XCTUnwrap(manifest["modes"] as? [String: [String: String]])
        XCTAssertEqual(modes, [mode: ["espPath": stage2Path]])
        // The saved Stage 2 is the file this Mac's Stage 1 loads.
        XCTAssertEqual(
          try Data(contentsOf: data.appendingPathComponent("AuraPayloads/raw/boot.bin")),
          try Data(contentsOf: fixture.esp.esp.appendingPathComponent(stage2Path)))
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        // Every Mac's Recovery payload carries the boot object it enrolls.
        XCTAssertNotNil(files["macho/aura-boot.macho"])
        let staged = data.appendingPathComponent("AuraPayloads/macho/aura-boot.macho")
        XCTAssertEqual(
          try Data(contentsOf: staged),
          try Data(
            contentsOf: fixture.system.appendingPathComponent(
              NativeESPFilesExecution.stage1MachOPath)))
        XCTAssertEqual(
          try Data(contentsOf: data.appendingPathComponent("AuraPayloads/raw/aura-raw.bin")),
          try Data(
            contentsOf: fixture.system.appendingPathComponent(NativeESPFilesExecution.stage1Path)))
      }
    }
  }
#endif
