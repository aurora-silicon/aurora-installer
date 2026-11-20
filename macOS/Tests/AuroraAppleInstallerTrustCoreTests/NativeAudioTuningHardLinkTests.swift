// Synthetic data only: no Apple tuning file is used or stored by these
// tests. The tree is shaped like the macOS 27 Tunings layout, where the
// sealed system volume gives identical files several names (hard links).
#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeAudioTuningHardLinkTests: XCTestCase {
    private typealias Inputs = NativeAudioTuningInputs
    private var directory: URL!

    override func setUpWithError() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aurora-tuning-links-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
      try FileManager.default.removeItem(at: directory)
    }

    private func write(_ path: String, _ data: Data, in root: URL? = nil) throws {
      let url = (root ?? directory!).appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      XCTAssertEqual(chmod(url.path, 0o644), 0)
    }

    private func hardLink(_ path: String, to other: String, in root: URL? = nil) throws {
      let base = root ?? directory!
      let url = base.appendingPathComponent(other)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      XCTAssertEqual(link(base.appendingPathComponent(path).path, url.path), 0)
    }

    private func plist(_ value: Any) throws -> Data {
      try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func links(_ path: String, in root: URL? = nil) -> nlink_t {
      var info = stat()
      guard lstat((root ?? directory!).appendingPathComponent(path).path, &info) == 0 else {
        return 0
      }
      return info.st_nlink
    }

    /// A macOS 27 tree whose selection files each carry a second name, as
    /// `Config/AID<n>.plist` does on the sealed system volume.
    private func sealedLayout(in root: URL? = nil) throws {
      try write("Tunings/AID37/ADM/config.plist", Data("synthetic adm".utf8), in: root)
      try write(
        "Tunings/AID37/DSP/Strips/aid37-aufx-spp3-appl.plist", Data("synthetic spp3".utf8),
        in: root)
      let entry: [String: Any] = [
        "AID37": [
          "Built-in Speaker": [
            "48k - General": [
              "Output": [
                ["Hardware": [["Graph": ["Path": "AID37/DSP/Strips/aid37-aufx-spp3-appl.plist"]]]]
              ]
            ]
          ]
        ]
      ]
      try write("Tunings/AID37/DSP/DSPDatabase.plist", plist(entry), in: root)
      try write("Tunings/Config/AID37.plist", plist(["Volume": ["Max": 0]]), in: root)
      // The same bytes under other names, as the sealed volume dedups them.
      try hardLink("Tunings/Config/AID37.plist", to: "Tunings/Config/AID38.plist", in: root)
      try hardLink("Tunings/Config/AID37.plist", to: "Tunings/Config/AID39.plist", in: root)
      try hardLink("Tunings/Config/AID37.plist", to: "Tunings/Config/AID40.plist", in: root)
      try hardLink(
        "Tunings/AID37/DSP/DSPDatabase.plist", to: "Tunings/AID38/DSP/DSPDatabase.plist",
        in: root)
      try hardLink(
        "Tunings/AID37/ADM/config.plist", to: "Tunings/AID38/ADM/config.plist", in: root)
    }

    private func makeTree(
      _ root: URL? = nil, readOnlyVolume: Bool,
      mountedReadOnly: (@Sendable (Int32) -> Bool)? = nil
    ) throws -> NativeHandoffFileTree {
      if let mountedReadOnly {
        return try NativeHandoffFileTree(
          root ?? directory!, protected: true, owner: geteuid(), readOnlyVolume: readOnlyVolume,
          mountedReadOnly: mountedReadOnly)
      }
      return try NativeHandoffFileTree(
        root ?? directory!, protected: true, owner: geteuid(), readOnlyVolume: readOnlyVolume)
    }

    private func folderFiles(_ tree: NativeHandoffFileTree, root: URL? = nil) throws
      -> [String: Data]
    {
      let snapshot = try NativeFirmwareInputFiles.snapshot(
        root: root ?? directory!, prefix: "Tunings/AID37", tree: tree, owner: geteuid())
      return try Inputs.admittedFiles(snapshot).files
    }

    private func assertUnsafeFile<T>(
      _ body: @autoclosure () throws -> T, file: StaticString = #filePath,
      line: UInt = #line
    ) {
      XCTAssertThrowsError(try body(), file: file, line: line) {
        XCTAssertEqual($0 as? NativeStubFileError, .unsafeFile, file: file, line: line)
      }
    }

    /// The J713 failure: `Config/AID37.plist` has four names on the sealed
    /// volume, and the single-name rule refused it as `unsafeFile`.
    func testTheSingleNameRuleIsWhatRefusedTheSealedConfig() throws {
      try sealedLayout()
      XCTAssertEqual(links("Tunings/Config/AID37.plist"), 4)
      let tree = try makeTree(readOnlyVolume: true, mountedReadOnly: { _ in true })
      let descriptor = try tree.fileDescriptor("Tunings/Config/AID37.plist")
      defer { close(descriptor) }
      assertUnsafeFile(
        try NativeStubFileStore.identity(descriptor, owner: geteuid(), maximum: 1 << 20))
      XCTAssertNoThrow(
        try NativeStubFileStore.identity(
          descriptor, owner: geteuid(), maximum: 1 << 20, admitsHardLinks: true))
    }

    func testHardLinkedSelectionFilesAreReadFromAReadOnlyVolume() throws {
      try sealedLayout()
      let tree = try makeTree(readOnlyVolume: true, mountedReadOnly: { _ in true })
      let files = try folderFiles(tree)
      XCTAssertEqual(files["ADM/config.plist"], Data("synthetic adm".utf8))
      let selected = try Inputs.selection(
        tree, prefix: "Tunings", acousticID: 37, files: files, owner: geteuid())
      XCTAssertEqual(selected.databaseSource, "AID37/DSP/DSPDatabase.plist")
      XCTAssertEqual(
        selected.selection["Config/AID37.plist"],
        try Data(contentsOf: directory.appendingPathComponent("Tunings/Config/AID37.plist")))
      XCTAssertEqual(
        selected.selection["DeviceDSPDatabase.plist"],
        try Data(
          contentsOf: directory.appendingPathComponent("Tunings/AID37/DSP/DSPDatabase.plist")))
      let snapshot = Inputs.Snapshot(
        acousticID: 37, thieleSmall: nil, files: files, build: "00A000",
        selection: selected.selection, databaseSource: selected.databaseSource,
        maskLattice: SyntheticLattice.table)
      let package = try Inputs.files(snapshot, prefix: Inputs.packagePrefix)
      XCTAssertNotNil(package["apple/audio-tuning/Config/AID37.plist"])
      XCTAssertNotNil(package["apple/audio-tuning/manifest.json"])
    }

    /// A tree for a read-only volume whose file turns out to sit on a
    /// writable filesystem keeps the single-name rule: the real `fstatfs`
    /// check sees the writable temporary directory.
    func testAWritableFilesystemKeepsTheSingleNameRule() throws {
      try sealedLayout()
      let tree = try makeTree(readOnlyVolume: true)
      let descriptor = try tree.fileDescriptor("Tunings/Config/AID37.plist")
      XCTAssertFalse(NativeHandoffFileTree.isReadOnly(descriptor))
      XCTAssertFalse(tree.admitsHardLinks(descriptor))
      close(descriptor)
      assertUnsafeFile(
        try Inputs.selection(
          tree, prefix: "Tunings", acousticID: 37,
          files: ["ADM/config.plist": Data(), "DSP/Strips/aid37-aufx-spp3-appl.plist": Data()],
          owner: geteuid()))
      assertUnsafeFile(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid()))
      XCTAssertThrowsError(try folderFiles(tree))
    }

    /// Staging, leases and caches are not read-only volume trees: even a
    /// filesystem that reports read-only does not admit a second name there.
    func testOnlyReadOnlyVolumeTreesAdmitHardLinks() throws {
      try sealedLayout()
      let tree = try makeTree(readOnlyVolume: false, mountedReadOnly: { _ in true })
      let descriptor = try tree.fileDescriptor("Tunings/Config/AID37.plist")
      XCTAssertFalse(tree.admitsHardLinks(descriptor))
      close(descriptor)
      assertUnsafeFile(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid()))
      XCTAssertThrowsError(
        try tree.read("Tunings/Config/AID37.plist", maximum: 1 << 20))
      // The stub store's own identity reads (staging, receipts) never admit
      // a second name, whatever its tree.
      let sealed = try makeTree(readOnlyVolume: true, mountedReadOnly: { _ in true })
      assertUnsafeFile(
        try NativeStubFileStore(tree: sealed, owner: geteuid()).identity(
          "Tunings/Config/AID37.plist"))
    }

    /// A second name is the only rule relaxed: ownership, write access and
    /// file type still hold on a read-only volume.
    func testAHardLinkedFileStillNeedsItsOwnerModeAndType() throws {
      try sealedLayout()
      let tree = try makeTree(readOnlyVolume: true, mountedReadOnly: { _ in true })
      let config = directory.appendingPathComponent("Tunings/Config/AID37.plist").path
      XCTAssertEqual(chmod(config, 0o664), 0)
      assertUnsafeFile(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid()))
      XCTAssertEqual(chmod(config, 0o644), 0)
      assertUnsafeFile(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid() &+ 1))
      XCTAssertNoThrow(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid()))
      // A symbolic link is still never followed.
      try FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent("Tunings/Config/AID41.plist").path,
        withDestinationPath: "AID37.plist")
      XCTAssertThrowsError(
        try NativeFirmwareInputFiles.read(
          tree, path: "Tunings/Config/AID41.plist", maximum: 1 << 20, owner: geteuid()))
    }

    /// The same tree on a real read-only mount: a UDRO disk image attached
    /// read-only, so `fstatfs` reports `MNT_RDONLY` for each file.
    func testARealReadOnlyMountAdmitsHardLinkedTuning() throws {
      guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else {
        throw XCTSkip("hdiutil is not available")
      }
      let source = directory.appendingPathComponent("source", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      XCTAssertEqual(chmod(source.path, 0o755), 0)
      try sealedLayout(in: source)
      let image = directory.appendingPathComponent("tunings.dmg")
      let mount = directory.appendingPathComponent("mount", isDirectory: true)
      try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
      try hdiutil([
        "create", "-quiet", "-srcfolder", source.path, "-format", "UDRO", "-fs", "APFS",
        "-volname", "AuroraTuningLinks", image.path,
      ])
      try hdiutil([
        "attach", "-quiet", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-owners", "on",
        "-mountpoint", mount.path, image.path,
      ])
      defer { try? hdiutil(["detach", "-force", mount.path]) }
      var info = stat()
      XCTAssertEqual(lstat(mount.path, &info), 0)
      guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
        throw XCTSkip("the image's root is not owned by this user")
      }
      guard links("Tunings/Config/AID37.plist", in: mount) > 1 else {
        throw XCTSkip("hdiutil did not keep the hard links")
      }

      let sealed = try makeTree(mount, readOnlyVolume: true)
      let descriptor = try sealed.fileDescriptor("Tunings/Config/AID37.plist")
      XCTAssertTrue(NativeHandoffFileTree.isReadOnly(descriptor))
      XCTAssertTrue(sealed.admitsHardLinks(descriptor))
      close(descriptor)
      let files = try folderFiles(sealed, root: mount)
      let selected = try Inputs.selection(
        sealed, prefix: "Tunings", acousticID: 37, files: files, owner: geteuid())
      XCTAssertEqual(
        selected.selection["Config/AID37.plist"],
        try Data(contentsOf: source.appendingPathComponent("Tunings/Config/AID37.plist")))

      // The same mount read through a tree not made for a read-only volume
      // keeps the single-name rule.
      let staging = try makeTree(mount, readOnlyVolume: false)
      assertUnsafeFile(
        try NativeFirmwareInputFiles.read(
          staging, path: "Tunings/Config/AID37.plist", maximum: 1 << 20, owner: geteuid()))
    }

    /// Runs hdiutil with a deadline, so a stuck attach fails the test.
    private func hdiutil(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = Date().addingTimeInterval(120)
      while process.isRunning, Date() < deadline { usleep(50_000) }
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        XCTFail("hdiutil \(arguments.first ?? "") timed out")
        throw CocoaError(.executableLoad)
      }
      guard process.terminationStatus == 0 else {
        throw XCTSkip("hdiutil \(arguments.first ?? "") failed (\(process.terminationStatus))")
      }
    }
  }
#endif
