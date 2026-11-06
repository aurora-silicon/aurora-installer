// Based on aurora-audio-dsp by saku (MIT). Synthetic data only: no Apple
// tuning file is used or stored by these tests.
#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeAudioTuningInputsTests: XCTestCase {
    private func snapshot(spts: Data? = Data([2, 0, 22, 6])) -> NativeAudioTuningInputs.Snapshot {
      NativeAudioTuningInputs.Snapshot(
        acousticID: 35, thieleSmall: spts,
        files: [
          "ADM/config.plist": Data("synthetic config".utf8),
          "DSP/Strips/aid35-aufx-spp3-appl.plist": Data("synthetic spp3".utf8),
        ], build: "00A000",
        selection: [
          "DeviceDSPDatabase.plist": Data("synthetic database entry".utf8),
          "Config/AID35.plist": Data("synthetic config".utf8),
        ], maskLattice: SyntheticLattice.table, velocityParameterMaximum: 1.75)
    }

    func testAcousticIDIsOneLittleEndianWord() {
      XCTAssertEqual(NativeAudioTuningInputs.acousticID(Data([0x23, 0, 0, 0])), 35)
      XCTAssertEqual(NativeAudioTuningInputs.acousticID(Data([0x2c, 0, 0, 0])), 44)
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0x23])))
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0, 0, 0, 0])))
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0xff, 0xff, 0xff, 0xff])))
      XCTAssertEqual(NativeAudioTuningInputs.folder(35), "AID35")
    }

    func testSidecarsAndEscapesAreNotTuning() {
      XCTAssertTrue(NativeAudioTuningInputs.admitted("DSP/Graphs/builtin_speaker_out.dspg"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("DSP/._builtin_speaker_out.dspg"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted(".DS_Store"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("../AID9/ADM/config.plist"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("/System/Library"))
    }

    func testFilesCarryTheFolderTheRecordAndAHashedManifest() throws {
      let files = try NativeAudioTuningInputs.files(
        snapshot(), prefix: NativeAudioTuningInputs.packagePrefix)
      XCTAssertEqual(
        Set(files.keys),
        [
          "apple/audio-tuning/AID35/ADM/config.plist",
          "apple/audio-tuning/AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
          "apple/audio-tuning/speaker-thiele-small.bin",
          "apple/audio-tuning/manifest.json",
          "apple/audio-tuning/DeviceDSPDatabase.plist",
          "apple/audio-tuning/Config/AID35.plist",
          "apple/audio-tuning/lsm2-mask-lattice.bin",
          "apple/audio-tuning/lsm2-metadata.json",
        ])
      let manifest = try JSONDecoder().decode(
        NativeAudioTuningInputs.Manifest.self,
        from: XCTUnwrap(files["apple/audio-tuning/manifest.json"]))
      XCTAssertEqual(manifest.schema, 2)
      XCTAssertTrue(manifest.complete)
      XCTAssertEqual(manifest.sourceFileCount, 2)
      XCTAssertEqual(
        manifest.sourceFileCount, manifest.files.filter { $0.path.hasPrefix("AID35/") }.count)
      XCTAssertEqual(manifest.acousticID, 35)
      XCTAssertEqual(manifest.aid, "AID35")
      XCTAssertEqual(manifest.macOSBuild, "00A000")
      XCTAssertEqual(manifest.basedOn, "aurora-audio-dsp by saku (MIT)")
      XCTAssertEqual(
        manifest.files.map(\.path),
        [
          "AID35/ADM/config.plist", "AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
          "Config/AID35.plist", "DeviceDSPDatabase.plist",
        ])
      XCTAssertEqual(manifest.deviceDSPDatabase, "DeviceDSPDatabase.plist")
      XCTAssertEqual(manifest.config, "Config/AID35.plist")
      for record in manifest.files {
        let data = try XCTUnwrap(files["apple/audio-tuning/" + record.path])
        XCTAssertEqual(record.bytes, data.count)
        XCTAssertEqual(record.sha256, NativeStubFileStore.hash(data))
      }
      XCTAssertEqual(manifest.speakerThieleSmall?.bytes, 4)
      XCTAssertEqual(files["apple/audio-tuning/lsm2-mask-lattice.bin"], SyntheticLattice.table)
      XCTAssertEqual(
        manifest.lsm2MaskLattice,
        NativeAudioTuningInputs.Manifest.Lattice(
          path: "lsm2-mask-lattice.bin", bytes: 800,
          sha256: NativeStubFileStore.hash(SyntheticLattice.table), version: 1,
          format: "u64le-exclusive-ends", entries: 100))
      let metadata = try XCTUnwrap(files["apple/audio-tuning/lsm2-metadata.json"])
      XCTAssertEqual(manifest.lsm2Metadata?.bytes, metadata.count)
      XCTAssertEqual(manifest.lsm2Metadata?.sha256, NativeStubFileStore.hash(metadata))
      let metadataObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: metadata) as? [String: Any])
      XCTAssertEqual(metadataObject["kind"] as? String, "aurora-lsm2-parameter-metadata")
      XCTAssertEqual(metadataObject["version"] as? Int, 1)
      XCTAssertEqual(metadataObject["velocity_parameter_max"] as? Double, 1.75)
    }

    func testNoValidLatticeIsNoBundle() throws {
      var damaged = SyntheticLattice.ends()
      damaged[99] = 320
      for lattice in [
        nil, Data(), SyntheticLattice.table.prefix(792), SyntheticLattice.pack(damaged),
      ] {
        var partial = snapshot()
        partial.maskLattice = lattice
        XCTAssertThrowsError(try NativeAudioTuningInputs.files(partial, prefix: "x/"))
        let source = partial
        let collected = try NativeAudioTuningInputs.collect({ _ in source }, owner: 0)
        XCTAssertTrue(collected.package.isEmpty && collected.fallback.isEmpty)
      }
    }

    func testNoValidVelocityParameterMaximumIsNoBundle() throws {
      for maximum in [nil, Float.nan, Float.infinity, 0, -1] as [Float?] {
        var partial = snapshot()
        partial.velocityParameterMaximum = maximum
        XCTAssertThrowsError(try NativeAudioTuningInputs.files(partial, prefix: "x/"))
        let source = partial
        let collected = try NativeAudioTuningInputs.collect({ _ in source }, owner: 0)
        XCTAssertTrue(collected.package.isEmpty && collected.fallback.isEmpty)
      }
    }

    func testALatticeFailureFromTheSourceIsNoBundle() throws {
      let collected = try NativeAudioTuningInputs.collect(
        { _ in throw NativeLSM2Lattice.Failure.candidates(slice: 0, found: 2) }, owner: 0)
      XCTAssertTrue(collected.package.isEmpty && collected.fallback.isEmpty)
    }

    func testDesktopWithoutCalibrationStillGetsItsTuning() throws {
      let files = try NativeAudioTuningInputs.files(
        snapshot(spts: nil), prefix: NativeAudioTuningInputs.fallbackPrefix)
      XCTAssertNotNil(files["audio-tuning/AID35/ADM/config.plist"])
      XCTAssertNil(files["audio-tuning/speaker-thiele-small.bin"])
      let manifest = try JSONDecoder().decode(
        NativeAudioTuningInputs.Manifest.self,
        from: XCTUnwrap(files["audio-tuning/manifest.json"]))
      XCTAssertNil(manifest.speakerThieleSmall)
    }

    func testTheDatabaseKeepsOnlyThisMacsEntry() throws {
      let database = try PropertyListSerialization.data(
        fromPropertyList: [
          "AID35": ["Built-in Speaker": ["48k - General": ["Graph": "synthetic.dspg"]]],
          "AID9": ["Built-in Speaker": ["48k - General": ["Graph": "other.dspg"]]],
        ], format: .binary, options: 0)
      let entry = try XCTUnwrap(NativeAudioTuningInputs.databaseEntry(database, acousticID: 35))
      let decoded = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: entry, format: nil) as? [String: Any])
      XCTAssertEqual(Set(decoded.keys), ["AID35"])
      XCTAssertNil(try NativeAudioTuningInputs.databaseEntry(database, acousticID: 44))
      XCTAssertThrowsError(
        try NativeAudioTuningInputs.databaseEntry(Data("not a plist".utf8), acousticID: 35))
    }

    func testSelectionNamesAreFixed() throws {
      var other = snapshot()
      other.selection["Config/AID9.plist"] = Data([1])
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(other, prefix: "x/"))
    }

    func testManifestKeysMatchThePythonWriter() throws {
      let files = try NativeAudioTuningInputs.files(snapshot(), prefix: "")
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(files["manifest.json"])) as? [String: Any])
      XCTAssertEqual(
        Set(object.keys),
        [
          "schema", "kind", "source_file_count", "complete", "acoustic_id", "aid",
          "macos_build", "speaker_thiele_small", "device_dsp_database", "config", "files",
          "based_on", "device_dsp_database_source", "shared_files", "lsm2_mask_lattice",
          "lsm2_metadata",
        ])
      XCTAssertEqual(object["device_dsp_database_source"] as? String, "DeviceDSPDatabase.plist")
      XCTAssertEqual((object["shared_files"] as? [Any])?.count, 0)
      XCTAssertEqual(object["complete"] as? Bool, true)
      XCTAssertEqual(object["source_file_count"] as? Int, 2)
    }

    func testAMissingSelectionFileIsNoBundle() throws {
      for name in ["DeviceDSPDatabase.plist", "Config/AID35.plist"] {
        var partial = snapshot()
        partial.selection[name] = nil
        XCTAssertThrowsError(try NativeAudioTuningInputs.files(partial, prefix: "x/"), name)
        let source = partial
        let collected = try NativeAudioTuningInputs.collect({ _ in source }, owner: 0)
        XCTAssertTrue(collected.package.isEmpty && collected.fallback.isEmpty, name)
      }
    }

    func testAShortSourceCountIsNoBundle() throws {
      var short = snapshot()
      short.sourceFileCount = 3
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(short, prefix: "x/"))
      let source = short
      let collected = try NativeAudioTuningInputs.collect({ _ in source }, owner: 0)
      XCTAssertTrue(collected.package.isEmpty && collected.fallback.isEmpty)
    }

    func testLinksAreCopiesAndUnresolvedLinksFailTheSet() throws {
      let base = NativeFirmwareInputFiles.Snapshot(
        files: ["ADM/config.plist": Data("synthetic".utf8), "._sidecar": Data([0])],
        links: ["ADM/alias.plist": "ADM/config.plist"])
      let (files, count) = try NativeAudioTuningInputs.admittedFiles(base)
      XCTAssertEqual(files["ADM/alias.plist"], Data("synthetic".utf8))
      XCTAssertEqual(count, 2)
      XCTAssertNil(files["._sidecar"])

      var dangling = base
      dangling.unresolved = ["ADM/gone.plist"]
      XCTAssertThrowsError(try NativeAudioTuningInputs.admittedFiles(dangling))
      // A sidecar link that resolves nowhere is not tuning data.
      var sidecar = base
      sidecar.unresolved = ["ADM/._gone.plist"]
      XCTAssertNoThrow(try NativeAudioTuningInputs.admittedFiles(sidecar))
      var missing = base
      missing.links["ADM/other.plist"] = "ADM/absent.plist"
      XCTAssertThrowsError(try NativeAudioTuningInputs.admittedFiles(missing))
    }

    func testTheSnapshotReportsDanglingAndDirectoryLinks() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tuning-\(UUID().uuidString)").resolvingSymlinksInPath()
      defer { try? FileManager.default.removeItem(at: root) }
      let folder = root.appendingPathComponent("AID35/ADM")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
      try Data("synthetic".utf8).write(to: folder.appendingPathComponent("config.plist"))
      try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("alias.plist").path,
        withDestinationPath: "config.plist")
      try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("gone.plist").path,
        withDestinationPath: "missing.plist")
      try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("dir").path, withDestinationPath: "Sub")
      let owner = geteuid()
      let snapshot = try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: "AID35",
        tree: NativeHandoffFileTree(root, protected: true, owner: owner), owner: owner)
      XCTAssertEqual(snapshot.links, ["ADM/alias.plist": "ADM/config.plist"])
      XCTAssertEqual(snapshot.unresolved, ["ADM/dir", "ADM/gone.plist"])
      XCTAssertThrowsError(try NativeAudioTuningInputs.admittedFiles(snapshot))
    }

    func testTheSpeakerIDComesFromTheOneSpeakerService() {
      let speaker: [String: Any] = [
        "device UID": "Speaker", "speakerID": NSNumber(value: UInt32(3)),
      ]
      let codec: [String: Any] = ["device UID": "Codec Output", "speakerID": NSNumber(value: 1)]
      XCTAssertEqual(NativeAudioTuningInputs.liveSpeakerID { [speaker, codec] }, 3)
      XCTAssertEqual(
        NativeAudioTuningInputs.speakerID([["device UID": "Speaker", "speakerID": 65535]]), 65535)
      XCTAssertEqual(
        NativeAudioTuningInputs.speakerID([
          ["device UID": "Speaker", "speakerID": NSNumber(value: UInt32.max)]
        ]), UInt32.max)
      // Absent, duplicated, malformed or out of range is unknown.
      XCTAssertNil(NativeAudioTuningInputs.liveSpeakerID { [] })
      XCTAssertNil(NativeAudioTuningInputs.speakerID([["device UID": "Speaker"]]))
      XCTAssertNil(NativeAudioTuningInputs.speakerID([codec]))
      XCTAssertNil(NativeAudioTuningInputs.speakerID([speaker, speaker]))
      for bad: Any in [
        "3", true, 3.0, Double(2.5), -1, Int64(UInt32.max) + 1, UInt64.max, Data([3, 0, 0, 0]),
      ] {
        XCTAssertNil(
          NativeAudioTuningInputs.speakerID([["device UID": "Speaker", "speakerID": bad]]),
          "\(bad)")
      }
    }

    func testTheManifestCarriesTheSpeakerID() throws {
      for id: UInt32? in [3, 65535, nil] {
        var source = snapshot()
        source.speakerID = id
        let files = try NativeAudioTuningInputs.files(source, prefix: "")
        let data = try XCTUnwrap(files["manifest.json"])
        let manifest = try JSONDecoder().decode(NativeAudioTuningInputs.Manifest.self, from: data)
        XCTAssertEqual(manifest.speakerID, id)
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["speaker_id"] as? Int, id.map(Int.init))
        // Re-encoding the decoded manifest gives the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(manifest), data)
      }
      // A manifest with speaker_id null decodes as unknown.
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(
            try NativeAudioTuningInputs.files(snapshot(), prefix: "")["manifest.json"]))
          as? [String: Any])
      object["speaker_id"] = NSNull()
      let decoded = try JSONDecoder().decode(
        NativeAudioTuningInputs.Manifest.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertNil(decoded.speakerID)
    }

    func testAnUnknownSpeakerIDNeverFailsCollection() throws {
      var unknown = snapshot()
      unknown.speakerID = nil
      let source = unknown
      let collected = try NativeAudioTuningInputs.collect({ _ in source }, owner: 0)
      // Two folder files, two selection files, calibration, lattice,
      // parameter metadata and manifest.
      XCTAssertEqual(collected.package.count, 8)
      var failing = snapshot()
      failing.speakerID = 3
      failing.selection["Config/AID35.plist"] = nil
      let broken = failing
      let none = try NativeAudioTuningInputs.collect({ _ in broken }, owner: 0)
      XCTAssertTrue(none.package.isEmpty && none.fallback.isEmpty)
    }

    func testUnitIDsAndBoards() {
      // A made-up serial number, NUL-padded as macOS pads it, and as aura
      // copies it into the Linux device tree (one NUL): the same unit.
      let serial = Data("SYNTHETIC0A".utf8)
      let want = NativeStubFileStore.hash(NativeAudioTuningInputs.unitIDDomain + serial)
      XCTAssertEqual(
        NativeAudioTuningInputs.unitID(serial + Data(repeating: 0, count: 21)), want)
      XCTAssertEqual(NativeAudioTuningInputs.unitID(serial + Data([0])), want)
      XCTAssertNotEqual(want, NativeStubFileStore.hash(serial))
      // The vector every implementation shares (Python, Rust, Swift).
      XCTAssertEqual(want, "22fea1b624a25cb3e103ed668fc37e1ef5c0d445e195029caf273827923c793d")
      for bad in [
        Data(), Data([0, 0]), Data("A B".utf8), Data([0x41, 0, 0x42]), Data([0xff]),
        Data(repeating: 0x41, count: 65),
      ] {
        XCTAssertNil(NativeAudioTuningInputs.unitID(bad))
      }
      XCTAssertEqual(NativeAudioTuningInputs.board(Data("J616s\u{0}".utf8)), "j616s")
      XCTAssertEqual(NativeAudioTuningInputs.board(Data("J413AP".utf8)), "j413")
      for bad in ["", "AP", "J 413", "Mac14,2", "J1234567890"] {
        XCTAssertNil(NativeAudioTuningInputs.board(Data(bad.utf8)), bad)
      }
    }

    func testTheManifestNamesTheBoardAndUnit() throws {
      let unit = try XCTUnwrap(NativeAudioTuningInputs.unitID(Data("SYNTHETIC0A".utf8)))
      var source = snapshot()
      source.board = "j616s"
      source.unitID = unit
      let files = try NativeAudioTuningInputs.files(source, prefix: "")
      let data = try XCTUnwrap(files["manifest.json"])
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["board"] as? String, "j616s")
      XCTAssertEqual(object["unit_id"] as? String, unit)
      for file in files.values {
        XCTAssertNil(file.range(of: Data("SYNTHETIC0A".utf8)))
      }
      // Unknown: both keys omitted, and the collection still succeeds.
      let plain = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(
            try NativeAudioTuningInputs.files(snapshot(), prefix: "")["manifest.json"]))
          as? [String: Any])
      XCTAssertNil(plain["board"])
      XCTAssertNil(plain["unit_id"])
      // Malformed values are no bundle.
      for (board, unitID) in [("J616s", unit), ("j616s", unit.uppercased()), ("j616s", "abc")] {
        var bad = snapshot()
        bad.board = board
        bad.unitID = unitID
        XCTAssertThrowsError(try NativeAudioTuningInputs.files(bad, prefix: ""))
      }
    }

    func testNoSnapshotIsNoFiles() throws {
      XCTAssertTrue(try NativeAudioTuningInputs.files(nil, prefix: "x/").isEmpty)
    }

    func testInvalidSnapshotsAreRejectedAndCollectionNeverStopsAnInstall() throws {
      var empty = snapshot()
      empty.files = [:]
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(empty, prefix: "x/"))
      var escaping = snapshot()
      escaping.files["../outside"] = Data([1])
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(escaping, prefix: "x/"))
      var oversized = snapshot()
      oversized.thieleSmall = Data(count: 8192)
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(oversized, prefix: "x/"))

      let invalid = escaping
      let rejected = try NativeAudioTuningInputs.collect({ _ in invalid }, owner: 0)
      XCTAssertTrue(rejected.package.isEmpty && rejected.fallback.isEmpty)
      struct Failure: Error {}
      let failed = try NativeAudioTuningInputs.collect({ _ in throw Failure() }, owner: 0)
      XCTAssertTrue(failed.package.isEmpty && failed.fallback.isEmpty)
      XCTAssertThrowsError(
        try NativeAudioTuningInputs.collect({ _ in throw CancellationError() }, owner: 0))
      let good = snapshot()
      let collected = try NativeAudioTuningInputs.collect({ _ in good }, owner: 0)
      XCTAssertEqual(collected.package.count, 8)
      XCTAssertEqual(collected.fallback.count, 8)
    }
  }
#endif
