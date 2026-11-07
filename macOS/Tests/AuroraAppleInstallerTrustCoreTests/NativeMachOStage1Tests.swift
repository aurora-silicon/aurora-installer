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
      // The table's M4-generation and later chips: T6040 (M4 Pro), T6050 (M5 Pro
      // and Max) and T8140 (A18 Pro).
      XCTAssertEqual(
        Set(chips.filter { AuraStage1Format.usesMachO(chipID: $0) }), [0x6040, 0x6050, 0x8140])
      for chip in chips where !AuraStage1Format.usesMachO(chipID: chip) {
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
      let before = try Data(contentsOf: fixture.receipt)
      try await fixture.prepare()
      XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
    }

    func testRawStage1ReceiptKeepsItsFormerShape() async throws {
      let fixture = try await NativeESPFileTests.Fixture()
      try await fixture.prepare()
      let receipt =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: fixture.receipt)) as! [String: Any]
      XCTAssertEqual(
        Set(receipt.keys), ["plan", "firmware", "groupUUID", "espUUID", "files", "icon", "stage1"])
      let system = fixture.images.base.mounts.appendingPathComponent("disk8s1")
      XCTAssertFalse(
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

    /// The fixture payload with `esp/aurora/stage1.macho` added by zip(1).
    static func payload(machO: @escaping (Data) -> Data) async throws -> (Data, Data, Data) {
      let (metadata, payload, _) = try NativeESPFileTests.inputs()
      let archive = try await IPSWArchive.open(NativeRawImageWriterTests.Source(bytes: payload))
      let member = try XCTUnwrap(archive.members.first { $0.name == "esp/aurora/stage1.bin" })
      let raw = try await archive.read(member, maximumBytes: 64 << 20)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aurora-macho-payload-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let object = machO(raw)
      let path = directory.appendingPathComponent("esp/aurora/stage1.macho")
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try object.write(to: path)
      let zip = directory.appendingPathComponent("payload.zip")
      try payload.write(to: zip)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments = ["-q", "-X", "-0", zip.path, "esp/aurora/stage1.macho"]
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
          machOStage1: machO)
        XCTAssertEqual(try XCTUnwrap(plan).stage1MachO, machO ? object : nil)
        XCTAssertEqual(
          try XCTUnwrap(plan).entries.first { $0.member.name == "esp/aurora/stage1.macho" }?.path,
          "aurora/stage1.macho")
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
          machOStage1: true)
        XCTFail("A Mach-O object for another Stage 1 was admitted")
      } catch let error as NativeBootChainError {
        XCTAssertEqual(error, .invalidStage1)
      }
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
        let mode = machO ? "macho" : "raw"
        XCTAssertEqual(config["bootMode"] as? String, mode)
        XCTAssertEqual(config["stage2Path"] as? String, "m1n1/boot.bin")
        XCTAssertEqual(manifest["defaultMode"] as? String, mode)
        XCTAssertEqual(manifest["nestedVirtualization"] as? Bool, false)
        let modes = try XCTUnwrap(manifest["modes"] as? [String: [String: String]])
        XCTAssertEqual(
          modes,
          machO
            ? ["raw": ["espPath": "m1n1/boot.bin"], "macho": ["espPath": "m1n1/boot.bin"]]
            : ["raw": ["espPath": "m1n1/boot.bin"]])
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        XCTAssertEqual(files["macho/aura-boot.macho"] != nil, machO)
        let staged = data.appendingPathComponent("AuraPayloads/macho/aura-boot.macho")
        XCTAssertEqual(FileManager.default.fileExists(atPath: staged.path), machO)
        if machO {
          XCTAssertEqual(
            try Data(contentsOf: staged),
            try Data(
              contentsOf: fixture.system.appendingPathComponent(
                NativeESPFilesExecution.stage1MachOPath)))
        }
        XCTAssertEqual(
          try Data(contentsOf: data.appendingPathComponent("AuraPayloads/raw/aura-raw.bin")),
          try Data(
            contentsOf: fixture.system.appendingPathComponent(NativeESPFilesExecution.stage1Path)))
      }
    }
  }
#endif
