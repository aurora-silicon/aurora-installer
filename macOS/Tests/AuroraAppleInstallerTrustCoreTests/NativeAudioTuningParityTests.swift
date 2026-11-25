// Synthetic data only: the fixture (tests/fixtures/audio-tuning-parity) is
// a made-up system volume written by tests/audio_tuning_parity.py, and the
// lsm2 readback here is generated. No Apple tuning file is used or stored.
#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// The native installer and the Python collector write the same speaker
  /// tuning bundle for the same Mac, byte for byte.
  final class NativeAudioTuningParityTests: XCTestCase {
    private typealias Inputs = NativeAudioTuningInputs
    private typealias Fill = NativeLSM2Fill

    private static let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = repository.appendingPathComponent(
      "tests/fixtures/audio-tuning-parity", isDirectory: true)
    private static let script = repository.appendingPathComponent("tests/audio_tuning_parity.py")

    /// The cases of tests/audio_tuning_parity.py (CASES).
    private struct Case {
      let acoustic: UInt32
      let thieleSmall: Data?
      let build: String
      let speaker: UInt32?
      let identity: Bool
    }
    private static let cases: [String: Case] = [
      "aid97": Case(
        acoustic: 97, thieleSmall: Data([2, 0, 22, 6, 1, 9]), build: "00A001", speaker: 3,
        identity: true),
      "aid98": Case(acoustic: 98, thieleSmall: nil, build: "00A002", speaker: nil, identity: false),
      "aid99": Case(
        acoustic: 99, thieleSmall: Data([7, 7, 7]), build: "25Z999", speaker: 65535,
        identity: false),
    ]

    private var directory: URL!

    override func setUpWithError() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aurora-tuning-parity-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
      try FileManager.default.removeItem(at: directory)
    }

    /// The fixture copied with the modes a sealed volume has (no group or
    /// world write), owned by this user; its link stays a link.
    private func copiedRoot() throws -> URL {
      let root = directory.appendingPathComponent("root", isDirectory: true)
      try FileManager.default.copyItem(
        at: Self.fixture.appendingPathComponent("root", isDirectory: true), to: root)
      for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
        let path = root.appendingPathComponent(relative).path
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        switch info.st_mode & S_IFMT {
        case S_IFDIR: XCTAssertEqual(chmod(path, 0o755), 0)
        case S_IFREG: XCTAssertEqual(chmod(path, 0o644), 0)
        default: break
        }
      }
      XCTAssertEqual(chmod(root.path, 0o755), 0)
      return root
    }

    /// The generated readback of tests/audio_tuning_parity.py (readback).
    private static func readback(
      _ path: String, _ effect: NSDictionary, _ files: [String: Data]
    ) throws
      -> Fill.Readback
    {
      let preset = try XCTUnwrap(effect["aupreset"] as? NSDictionary)
      let saved = try Fill.presetIDs(XCTUnwrap(preset["data"] as? Data))
      let ids = Fill.baseIDs.union(saved.subtracting(Fill.baseIDs)).sorted(by: >)
      let names: [UInt32: String] = [
        0: "", 1: "Synth\u{e9}tique \u{2713} \"q\" \\ \u{1F600} \t",
        2: String(repeating: "x", count: 1024),
      ]
      return Fill.Readback(
        unitVersion: 0x0001_0203, componentSHA256: String(repeating: "5a", count: 32),
        published: ids.map {
          Fill.Parameter(
            id: $0, name: names[$0] ?? "Synthetic \($0)",
            bits: UInt32(truncatingIfNeeded: UInt64($0) &* 2_654_435_761) & 0x3FFF_FFFF)
        })
    }

    /// The native bundle for one case, by path relative to the bundle.
    private func native(_ name: String, root: URL) throws -> [String: Data] {
      let entry = try XCTUnwrap(Self.cases[name])
      var acoustic = Data()
      for shift in stride(from: 0, to: 32, by: 8) {
        acoustic.append(UInt8(entry.acoustic >> shift & 0xff))
      }
      var services: [[String: Any]] = [["device UID": "Codec"]]
      if let speaker = entry.speaker {
        services.append(["device UID": "Speaker", "speakerID": NSNumber(value: speaker)])
      }
      let device = Inputs.Device(
        acousticID: try XCTUnwrap(Inputs.acousticID(acoustic)), thieleSmall: entry.thieleSmall,
        build: entry.build, speakerID: Inputs.speakerID(services),
        board: entry.identity ? Inputs.board(Data("J999AP\u{0}".utf8)) : nil,
        unitID: entry.identity
          ? Inputs.unitID(Data("SYNTHETIC0A".utf8) + Data(repeating: 0, count: 21)) : nil)
      let tree = try NativeHandoffFileTree(root, protected: true, owner: geteuid())
      let snapshot = try Inputs.snapshot(
        root: root, tree: tree, owner: geteuid(), device: device, readback: Self.readback)
      return try Inputs.files(XCTUnwrap(snapshot), prefix: "")
    }

    private static func digests(_ bundle: [String: Data]) -> [String: String] {
      bundle.mapValues(NativeStubFileStore.hash)
    }

    func testEachCaseIsTheBundleThePythonCollectorWrites() throws {
      let expected = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: Self.fixture.appendingPathComponent("expected.json")))
          as? [String: [String: String]])
      XCTAssertEqual(Set(expected.keys), Set(Self.cases.keys))
      let root = try copiedRoot()
      for name in Self.cases.keys.sorted() {
        let bundle = try native(name, root: root)
        let want = try XCTUnwrap(expected[name])
        XCTAssertEqual(Self.digests(bundle), want, name)
        for (path, digest) in Self.digests(bundle) where want[path] != digest {
          XCTFail(
            "\(name): \(path) differs: \(String(decoding: bundle[path] ?? Data(), as: UTF8.self))")
        }
      }
    }

    /// The Python collector itself, run on the same tree, when python3 is
    /// installed (it is on the CI runners): every file, byte for byte.
    func testThePythonCollectorWritesTheSameBytes() throws {
      let probe = Process()
      probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      probe.arguments = ["python3", "-c", "import plistlib"]
      probe.standardOutput = FileHandle.nullDevice
      probe.standardError = FileHandle.nullDevice
      do {
        try probe.run()
        probe.waitUntilExit()
      } catch {
        throw XCTSkip("python3 is not available")
      }
      guard probe.terminationStatus == 0 else { throw XCTSkip("python3 is not available") }
      let root = try copiedRoot()
      for name in Self.cases.keys.sorted() {
        let output = directory.appendingPathComponent("python-" + name, isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
          "python3", "-I", Self.script.path, "collect", root.path, name, output.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, name)
        var python = [String: Data]()
        for relative in try FileManager.default.subpathsOfDirectory(atPath: output.path) {
          var isDirectory: ObjCBool = false
          let url = output.appendingPathComponent(relative)
          guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
          else { continue }
          python[relative] = try Data(contentsOf: url)
        }
        let bundle = try native(name, root: root)
        XCTAssertEqual(Set(bundle.keys), Set(python.keys), name)
        for (path, data) in bundle where python[path] != data {
          XCTFail(
            "\(name): \(path) differs\nnative: \(String(decoding: data, as: UTF8.self))\n"
              + "python: \(String(decoding: python[path] ?? Data(), as: UTF8.self))")
        }
      }
    }

    func testTheFillIsBoundToItsBundle() throws {
      let root = try copiedRoot()
      let bundle = try native("aid97", root: root)
      let manifest = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(bundle["manifest.json"])) as? [String: Any])
      let record = try XCTUnwrap(manifest["lsm2_param_fill"] as? [String: Any])
      XCTAssertEqual(record["path"] as? String, "lsm2-param-fill.bin")
      XCTAssertEqual(record["unit_versions"] as? [Int], [0x0001_0203])
      let fill = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(bundle["lsm2-param-fill.bin"]))
          as? [String: Any])
      let capture = try XCTUnwrap((fill["presets"] as? [[String: Any]])?.first)
      // 58 base IDs missing; the saved append-map ID is published, not filled.
      XCTAssertEqual((capture["fill_ids"] as? [Int])?.count, 58)
      XCTAssertFalse((capture["fill_ids"] as? [Int])?.contains(21512) ?? true)
      // A full preset needs no fill and never loads the unit.
      XCTAssertNil(try native("aid98", root: root)["lsm2-param-fill.bin"])
      // A fill for another build, unit or configuration is refused.
      let data = try XCTUnwrap(bundle["lsm2-param-fill.bin"])
      var files = [String: Data]()
      for (path, value) in bundle where path.hasPrefix("AID97/") || path.hasPrefix("Common/") {
        files[path] = value
      }
      let unit = try XCTUnwrap(manifest["unit_id"] as? String)
      XCTAssertNoThrow(
        try Fill.record(data, aid: "AID97", build: "00A001", unit: unit, files: files))
      XCTAssertThrowsError(
        try Fill.record(data, aid: "AID97", build: "00A002", unit: unit, files: files))
      XCTAssertThrowsError(
        try Fill.record(
          data, aid: "AID97", build: "00A001", unit: String(repeating: "1", count: 64),
          files: files))
      XCTAssertThrowsError(
        try Fill.record(data, aid: "AID97", build: "00A001", unit: nil, files: files))
      var changed = files
      changed["AID97/DSP/Strips/aid97-aufx-spp3-appl.plist"] = Data("changed".utf8)
      XCTAssertThrowsError(
        try Fill.record(data, aid: "AID97", build: "00A001", unit: unit, files: changed))
    }

    func testAFailedReadbackLeavesOnlyTheFillOut() throws {
      let root = try copiedRoot()
      let entry = try XCTUnwrap(Self.cases["aid97"])
      let tree = try NativeHandoffFileTree(root, protected: true, owner: geteuid())
      let device = Inputs.Device(
        acousticID: entry.acoustic, thieleSmall: entry.thieleSmall, build: entry.build,
        speakerID: entry.speaker, board: "j999",
        unitID: Inputs.unitID(Data("SYNTHETIC0A".utf8)))
      let readers: [Fill.Reader] = [
        { _, _, _ in throw Fill.Failure("synthetic failure") },
        { path, effect, files in
          // One missing base ID not published.
          let full = try Self.readback(path, effect, files)
          return Fill.Readback(
            unitVersion: full.unitVersion, componentSHA256: full.componentSHA256,
            published: full.published.filter { $0.id != 0 })
        },
        { path, effect, files in
          // A missing ID with a non-finite value.
          let full = try Self.readback(path, effect, files)
          return Fill.Readback(
            unitVersion: full.unitVersion, componentSHA256: full.componentSHA256,
            published: full.published.map {
              $0.id == 0 ? Fill.Parameter(id: 0, name: "", bits: 0x7f80_0000) : $0
            })
        },
      ]
      for reader in readers {
        let snapshot = try XCTUnwrap(
          Inputs.snapshot(
            root: root, tree: tree, owner: geteuid(), device: device, readback: reader))
        XCTAssertNil(snapshot.paramFill)
        let bundle = try Inputs.files(snapshot, prefix: "")
        XCTAssertNil(bundle["lsm2-param-fill.bin"])
        XCTAssertNotNil(bundle["lsm2-mask-lattice.bin"])
      }
      // Without the unit there is no fill either.
      var anonymous = device
      anonymous.unitID = nil
      let snapshot = try XCTUnwrap(
        Inputs.snapshot(
          root: root, tree: tree, owner: geteuid(), device: anonymous, readback: Self.readback))
      XCTAssertNil(snapshot.paramFill)
    }

    /// The unit is hosted only when its component is the restore image's:
    /// the installed component's digest is checked before the reader runs,
    /// and the readback's after. Anything else leaves the fill out.
    func testOnlyThePinnedComponentIsHosted() throws {
      let pinned = String(repeating: "5a", count: 32)
      let other = String(repeating: "6b", count: 32)
      final class Calls: @unchecked Sendable { var count = 0 }
      let calls = Calls()
      let reader: Fill.Reader = { path, effect, files in
        calls.count += 1
        return try Self.readback(path, effect, files)
      }
      let root = try copiedRoot()
      let entry = try XCTUnwrap(Self.cases["aid97"])
      let tree = try NativeHandoffFileTree(root, protected: true, owner: geteuid())
      let device = Inputs.Device(
        acousticID: entry.acoustic, thieleSmall: entry.thieleSmall, build: entry.build,
        speakerID: entry.speaker, board: "j999",
        unitID: Inputs.unitID(Data("SYNTHETIC0A".utf8)))
      func fill(_ readback: @escaping Fill.Reader) throws -> Data? {
        try XCTUnwrap(
          Inputs.snapshot(
            root: root, tree: tree, owner: geteuid(), device: device, readback: readback)
        ).paramFill
      }
      // The installed component differs: the unit is never loaded.
      XCTAssertNil(try fill(Fill.pinned(reader, componentSHA256: pinned, installed: { other })))
      XCTAssertEqual(calls.count, 0)
      // No pinned component, or an unreadable installed one.
      XCTAssertNil(try fill(Fill.pinned(reader, componentSHA256: nil, installed: { pinned })))
      XCTAssertNil(
        try fill(
          Fill.pinned(
            reader, componentSHA256: pinned, installed: { throw Fill.Failure("unreadable") })))
      XCTAssertEqual(calls.count, 0)
      // The hosted unit reports another component.
      XCTAssertNil(try fill(Fill.pinned(reader, componentSHA256: other, installed: { other })))
      XCTAssertGreaterThan(calls.count, 0)
      // The same component: the same fill as an unchecked readback.
      XCTAssertEqual(
        try fill(Fill.pinned(reader, componentSHA256: pinned, installed: { pinned })),
        try fill(Self.readback))
      XCTAssertNotNil(try fill(Self.readback))
    }

    func testSavedIDsOutsideTheSchemaAreRefused() throws {
      let base = Fill.baseIDs.sorted()
      func strip(_ ids: [UInt32]) throws -> Data {
        var data = Data()
        for word in [UInt32(0), 0, UInt32(ids.count)] {
          data += withUnsafeBytes(of: word.bigEndian) { Data($0) }
        }
        for id in ids {
          data += withUnsafeBytes(of: id.bigEndian) { Data($0) }
          data += withUnsafeBytes(of: Float(1).bitPattern.bigEndian) { Data($0) }
        }
        let effect: [String: Any] = [
          "unit": ["subtype": NSNumber(value: Fill.subtype)], "aupreset": ["data": data],
        ]
        return try PropertyListSerialization.data(
          fromPropertyList: ["strips": [["effects": [effect]]]], format: .binary, options: 0)
      }
      let unit = String(repeating: "1", count: 64)
      // 21512 is in the append map; 99999 is not.
      for (ids, ok) in [
        (Array(base.dropFirst(3)) + [21512], true), (Array(base.dropFirst(3)) + [99999], false),
      ] {
        let files = ["AID1/x.austrip": try strip(ids)]
        if ok {
          XCTAssertNotNil(
            try Fill.collect(
              files, aid: "AID1", build: "00A001", unit: unit, readback: Self.readback))
        } else {
          XCTAssertThrowsError(
            try Fill.collect(
              files, aid: "AID1", build: "00A001", unit: unit, readback: Self.readback))
        }
      }
      XCTAssertThrowsError(
        try Fill.presetIDs(Data([0, 0, 0, 1] + [UInt8](repeating: 0, count: 8))))
      XCTAssertThrowsError(try Fill.presetIDs(Data(count: 11)))
    }

    func testTheSchemaSizes() {
      XCTAssertEqual(Fill.baseIDs.count, 1021)
      XCTAssertTrue(Fill.baseIDs.isDisjoint(with: Fill.extensionIDs))
    }

    // MARK: The isolated readback process

    private func worker(_ body: String) throws -> URL {
      let url = directory.appendingPathComponent("worker-" + UUID().uuidString)
      try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
      XCTAssertEqual(chmod(url.path, 0o755), 0)
      return url
    }

    func testTheReadbackRunsInAChildOverPipes() throws {
      let effect: NSDictionary = ["aupreset": ["data": Data(count: 1 << 20)]]
      let files = ["AID1/x.austrip": Data(count: 4 << 20)]
      let answer =
        #"{"unit_version":7,"component_sha256":"\#(String(repeating: "a", count: 64))","#
        + #""published":[{"id":1,"name":"n","bits":0}]}"#
      let ok = try worker(
        "test \"$1\" = --lsm2-readback || exit 9\ncat >/dev/null\nprintf '%s' '\(answer)'")
      let result = try Fill.isolated(ok)("AID1/x.austrip", effect, files)
      XCTAssertEqual(result.unitVersion, 7)
      XCTAssertEqual(result.published, [Fill.Parameter(id: 1, name: "n", bits: 0)])
      // A child that fails, answers garbage or never reads its input is a
      // failed readback, and the caller survives (no SIGPIPE).
      for body in ["exit 3", "cat >/dev/null; echo not json", "echo '{}'"] {
        XCTAssertThrowsError(try Fill.isolated(worker(body))("AID1/x.austrip", effect, files), body)
      }
    }

    // MARK: Encoders

    func testRealsAndTypesEncodeAsPlistlibDoes() throws {
      // A binary property list's float32 real is widened, as plistlib does.
      guard case .real(let widened) = try NativePythonEncoding.plist(NSNumber(value: Float(0.1)))
      else { return XCTFail("a float32 number is not a real") }
      XCTAssertEqual(widened.bitPattern, Double(Float(0.1)).bitPattern)
      XCTAssertEqual(NativePythonEncoding.repr(Double(Float(0.1))), "0.10000000149011612")
      for (value, text) in [
        (1e16, "1e+16"), (1e15, "1000000000000000.0"), (1e-05, "1e-05"), (0.0001, "0.0001"),
        (-0.0, "-0.0"), (5e-324, "5e-324"), (3.0, "3.0"), (Double.infinity, "inf"),
        (123456789.125, "123456789.125"), (1.7976931348623157e308, "1.7976931348623157e+308"),
      ] {
        XCTAssertEqual(NativePythonEncoding.repr(value), text)
      }
      guard case .bool(true) = try NativePythonEncoding.plist(NSNumber(value: true)) else {
        return XCTFail("a boolean is not a bool")
      }
      XCTAssertThrowsError(try NativePythonEncoding.escaped("a\u{1}b"))
      XCTAssertEqual(try NativePythonEncoding.escaped("a\r\nb\rc&<>"), "a\nb\nc&amp;&lt;&gt;")
      XCTAssertEqual(
        NativePythonEncoding.quoted("\u{e9}\u{1F600}\u{7f}\"\\/"),
        #""\u00e9\ud83d\ude00\u007f\"\\/""#)
    }

    /// The real lsm2 unit on this Mac, when macOS has it: hosted in this
    /// process through the public API, never rendered. Only the outcome is
    /// recorded, never a value.
    func testTheSystemUnitCanBeHosted() throws {
      guard FileManager.default.fileExists(atPath: Fill.componentPath) else {
        throw XCTSkip("no AudioDSP component")
      }
      let fourCC = { (text: String) in text.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
      var header = Data()
      for word in [UInt32(0), 0, 0] { header += withUnsafeBytes(of: word.bigEndian) { Data($0) } }
      let unit: [String: Any] = [
        "type": NSNumber(value: fourCC("aufx")), "subtype": NSNumber(value: Fill.subtype),
        "manufacturer": NSNumber(value: fourCC("appl")),
      ]
      var preset = unit
      preset["version"] = NSNumber(value: 0)
      preset["name"] = "Synthetic"
      preset["data"] = header
      let effect: NSDictionary = ["unit": unit, "aupreset": preset, "displayname": "Synthetic"]
      do {
        let result = try Fill.readParameters(path: "AID1/x.austrip", effect: effect, files: [:])
        XCTAssertTrue(Fill.validDigest(result.componentSHA256))
        XCTAssertEqual(Set(result.published.map(\.id)).count, result.published.count)
        print("lsm2 hosting: \(result.published.count) parameters published")
      } catch let failure as Fill.Failure {
        // Some runners' macOS may lack the unit; a clean failure is fine,
        // a crash is not.
        print("lsm2 hosting: \(failure)")
      }
    }
  }
#endif
