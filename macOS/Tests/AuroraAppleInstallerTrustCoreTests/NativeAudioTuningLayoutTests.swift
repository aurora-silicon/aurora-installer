// Synthetic data only: no Apple tuning file is used or stored by these
// tests. The trees are shaped like the macOS 26 and macOS 27 layouts.
#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeAudioTuningLayoutTests: XCTestCase {
    private typealias Inputs = NativeAudioTuningInputs
    private var directory: URL!

    override func setUpWithError() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aurora-tuning-layout-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
      try FileManager.default.removeItem(at: directory)
    }

    private func write(_ path: String, _ data: Data) throws {
      let url = directory.appendingPathComponent("Tunings/" + path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }

    private func plist(_ value: Any, binary: Bool = false) throws -> Data {
      try PropertyListSerialization.data(
        fromPropertyList: value, format: binary ? .binary : .xml, options: 0)
    }

    /// An entry shaped like macOS's: modes holding {"Path": ...} references
    /// relative to the Tunings root, with Apple's irregular mode names.
    private func entry(
      _ aid: String = "AID35",
      speaker: [String] = ["AID35/DSP/Strips/aid35-aufx-spp3-appl.plist"],
      headphone: [String] = ["Common/Graphs/builtin_headphone_out.dspg"]
    ) -> [String: Any] {
      func mode(_ paths: [String]) -> [String: Any] {
        [
          "Output": [["Hardware": paths.map { ["Graph": ["Path": $0]] }]],
          "UnderlyingDeviceProperties": [["Selector": "spid", "Value": 65535]],
        ]
      }
      return [
        aid: [
          "Built-in Speaker": ["48k - General": mode(speaker), "48k - Dictation ": mode([])],
          "Built-in Headphone": ["48k - Movie- SSI": mode(headphone)],
        ] as [String: Any]
      ]
    }

    /// The common part of both layouts: the folder, the volume config,
    /// shared graphs and a loudness manager that lists another AID.
    private func base(loudness: [String] = ["AID44"]) throws {
      try write("AID35/ADM/config.plist", Data("synthetic adm".utf8))
      try write("AID35/DSP/Strips/aid35-aufx-spp3-appl.plist", Data("synthetic spp3".utf8))
      try write("Config/AID35.plist", plist(["Volume": ["Max": 0]]))
      try write("Common/Graphs/builtin_headphone_out.dspg", Data("synthetic hp graph".utf8))
      try write("Common/Strips/shared_speaker.austrip", Data("synthetic shared strip".utf8))
      try write("GenericDSPDatabase.plist", plist(["Generic": [String: Any]()]))
      try write(
        "DRC/loudness-manager.plist",
        plist(["Format": ["Default": [String: Any]()], "Supported_Hardware": loudness]))
    }

    private func folderFiles() throws -> [String: Data] {
      let root = directory.appendingPathComponent("Tunings/AID35")
      var files = [String: Data]()
      for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
        let url = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { continue }
        files[relative] = try Data(contentsOf: url)
      }
      return files
    }

    private func select() throws -> (Inputs.Selection, [String: Data]) {
      let tree = try NativeHandoffFileTree(directory, protected: true, owner: geteuid())
      let files = try folderFiles()
      return (
        try Inputs.selection(
          tree, prefix: "Tunings", acousticID: 35, files: files, owner: geteuid()),
        files
      )
    }

    private func snapshot(_ selected: Inputs.Selection, _ files: [String: Data])
      -> Inputs.Snapshot
    {
      Inputs.Snapshot(
        acousticID: 35, thieleSmall: Data([2, 0, 22, 6]), files: files, build: "00A000",
        selection: selected.selection, databaseSource: selected.databaseSource,
        sharedFiles: selected.sharedFiles, loudnessManager: selected.loudnessManager,
        maskLattice: SyntheticLattice.table, machineModel: "j413",
        unitIDHash: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func manifestObject(_ files: [String: Data]) throws -> [String: Any] {
      try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(files["apple/audio-tuning/manifest.json"])) as? [String: Any])
    }

    func testMacOS27ReadsTheEntryFromTheFolderByteForByte() throws {
      try base()
      let folderDatabase = try plist(entry(), binary: true)
      try write("AID35/DSP/DSPDatabase.plist", folderDatabase)
      let (selected, files) = try select()
      XCTAssertEqual(selected.databaseSource, "AID35/DSP/DSPDatabase.plist")
      XCTAssertEqual(selected.selection["DeviceDSPDatabase.plist"], folderDatabase)
      XCTAssertNotNil(selected.selection["Config/AID35.plist"])
      // Headphone-only shared files and a loudness manager for another AID
      // stay out.
      XCTAssertEqual(selected.sharedFiles, [:])
      XCTAssertNil(selected.loudnessManager)

      let package = try Inputs.files(snapshot(selected, files), prefix: Inputs.packagePrefix)
      XCTAssertEqual(package["apple/audio-tuning/DeviceDSPDatabase.plist"], folderDatabase)
      XCTAssertEqual(package["apple/audio-tuning/AID35/DSP/DSPDatabase.plist"], folderDatabase)
      XCTAssertFalse(
        package.keys.contains {
          $0.hasPrefix("apple/audio-tuning/Common/") || $0.hasPrefix("apple/audio-tuning/DRC/")
            || $0.contains("Generic")
        })
      let manifest = try manifestObject(package)
      XCTAssertEqual(
        manifest["device_dsp_database_source"] as? String, "AID35/DSP/DSPDatabase.plist")
      XCTAssertEqual(manifest["device_dsp_database"] as? String, "DeviceDSPDatabase.plist")
      XCTAssertEqual((manifest["shared_files"] as? [Any])?.count, 0)
      XCTAssertNil(manifest["loudness_manager"])
      XCTAssertEqual(manifest["schema"] as? Int, 2)
      // Apple's mode names are kept exactly, trailing space included.
      let decoded = try XCTUnwrap(
        PropertyListSerialization.propertyList(
          from: XCTUnwrap(package["apple/audio-tuning/DeviceDSPDatabase.plist"]), format: nil)
          as? [String: [String: [String: Any]]])
      XCTAssertNotNil(decoded["AID35"]?["Built-in Speaker"]?["48k - Dictation "])
      XCTAssertNotNil(decoded["AID35"]?["Built-in Headphone"]?["48k - Movie- SSI"])
    }

    func testMacOS26ReducesTheSharedDatabaseToThisMac() throws {
      try base()
      var both = entry()
      both.merge(entry("AID44", speaker: [], headphone: [])) { a, _ in a }
      try write("DeviceDSPDatabase.plist", plist(both))
      let (selected, files) = try select()
      XCTAssertEqual(selected.databaseSource, "DeviceDSPDatabase.plist")
      let reduced = try XCTUnwrap(
        PropertyListSerialization.propertyList(
          from: XCTUnwrap(selected.selection["DeviceDSPDatabase.plist"]), format: nil)
          as? [String: Any])
      XCTAssertEqual(Array(reduced.keys), ["AID35"])
      let manifest = try manifestObject(
        Inputs.files(snapshot(selected, files), prefix: Inputs.packagePrefix))
      XCTAssertEqual(manifest["device_dsp_database_source"] as? String, "DeviceDSPDatabase.plist")
    }

    func testFolderEntryWinsOverTheSharedDatabase() throws {
      try base()
      try write("DeviceDSPDatabase.plist", plist(entry(speaker: [])))
      let folderDatabase = try plist(entry(), binary: true)
      try write("AID35/DSP/DSPDatabase.plist", folderDatabase)
      let (selected, _) = try select()
      XCTAssertEqual(selected.databaseSource, "AID35/DSP/DSPDatabase.plist")
      XCTAssertEqual(selected.selection["DeviceDSPDatabase.plist"], folderDatabase)
    }

    func testFolderDatabaseWithOtherKeysIsReducedToTheEntry() throws {
      try base()
      var extra = entry()
      extra["Version"] = "synthetic"
      try write("AID35/DSP/DSPDatabase.plist", plist(extra, binary: true))
      let (selected, _) = try select()
      let reduced = try XCTUnwrap(
        PropertyListSerialization.propertyList(
          from: XCTUnwrap(selected.selection["DeviceDSPDatabase.plist"]), format: nil)
          as? [String: Any])
      XCTAssertEqual(Array(reduced.keys), ["AID35"])
    }

    func testSharedReferencesAndTheListingLoudnessManagerAreCollected() throws {
      try base(loudness: ["AID35", "AID44"])
      try write(
        "AID35/DSP/DSPDatabase.plist",
        plist(
          entry(speaker: [
            "AID35/DSP/Strips/aid35-aufx-spp3-appl.plist", "Common/Strips/shared_speaker.austrip",
          ]), binary: true))
      let (selected, files) = try select()
      XCTAssertEqual(
        selected.sharedFiles,
        ["Common/Strips/shared_speaker.austrip": Data("synthetic shared strip".utf8)])
      XCTAssertNotNil(selected.loudnessManager)
      let package = try Inputs.files(snapshot(selected, files), prefix: Inputs.fallbackPrefix)
      XCTAssertEqual(
        package["audio-tuning/Common/Strips/shared_speaker.austrip"],
        Data("synthetic shared strip".utf8))
      XCTAssertEqual(package["audio-tuning/DRC/loudness-manager.plist"], selected.loudnessManager)
      let manifest = try manifestObject(
        Inputs.files(snapshot(selected, files), prefix: Inputs.packagePrefix))
      let shared = try XCTUnwrap(manifest["shared_files"] as? [[String: Any]])
      XCTAssertEqual(shared.map { $0["path"] as? String }, ["Common/Strips/shared_speaker.austrip"])
      XCTAssertEqual(
        shared.first?["sha256"] as? String,
        NativeStubFileStore.hash(Data("synthetic shared strip".utf8)))
      let loudness = try XCTUnwrap(manifest["loudness_manager"] as? [String: Any])
      XCTAssertEqual(loudness["path"] as? String, "DRC/loudness-manager.plist")
      // Shared files stay out of `files`, as in the Python collector.
      let records = try XCTUnwrap(manifest["files"] as? [[String: Any]])
      XCTAssertFalse(records.contains { ($0["path"] as? String)?.hasPrefix("Common/") == true })
    }

    func testBadReferencesFailTheCollection() throws {
      try base()
      for paths in [
        ["GenericDSPDatabase.plist"], ["AID44/DSP/Strips/other.plist"],
        ["AID35/DSP/Strips/missing.plist"], ["Common/Strips/missing.austrip"],
        ["AID35/../AID44/x.plist"],
      ] {
        try write("AID35/DSP/DSPDatabase.plist", plist(entry(speaker: paths), binary: true))
        XCTAssertThrowsError(try select(), "\(paths)")
      }
    }

    func testSharedReferenceThroughALinkFails() throws {
      try base()
      try FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent("Tunings/Common/Strips/linked.austrip").path,
        withDestinationPath: "shared_speaker.austrip")
      try write(
        "AID35/DSP/DSPDatabase.plist",
        plist(entry(speaker: ["Common/Strips/linked.austrip"]), binary: true))
      XCTAssertThrowsError(try select())
    }
  }
#endif
