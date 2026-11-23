#if os(macOS)
  import Darwin
  import Foundation
  @testable import RecoveryAccountCore
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// The root of a volume the installer created must not be writable by
  /// group or others before anything is written under it.
  final class NativeOwnedVolumeRootTests: XCTestCase {
    /// A folder as APFS creates a volume root: group-writable, mode 0775.
    private func volumeRoot(mode: mode_t = 0o775) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try Data("media".utf8).write(to: root.appendingPathComponent(".IAPhysicalMedia"))
      XCTAssertEqual(chmod(root.appendingPathComponent(".IAPhysicalMedia").path, 0o644), 0)
      XCTAssertEqual(chmod(root.path, mode), 0)
      return root
    }

    private func remove(_ root: URL) {
      _ = chflags(root.path, 0)
      try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) -> mode_t {
      var status = stat()
      XCTAssertEqual(lstat(url.path, &status), 0)
      return status.st_mode & 0o7777
    }

    private func tree(
      _ root: URL, owned: Bool = true, readOnly: Bool = false,
      verifyMount: @escaping @Sendable (Int32, URL, String) throws -> Void = { _, _, _ in }
    ) throws -> NativeHandoffFileTree {
      try NativeHandoffFileTree(
        root, protected: true, owner: geteuid(), volumeRoot: true, ownedVolumeRoot: owned,
        volumeDevice: "disk8s1", verifyMount: verifyMount, mountedReadOnly: { _ in readOnly })
    }

    func testAGroupWritableOwnedRootBecomesOwnerOnly0755AfterItsMountIsVerified() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let opened = try tree(
        root,
        verifyMount: { fd, _, _ in
          // Nothing is changed before the descriptor is known to be the volume's root.
          var status = stat()
          XCTAssertEqual(fstat(fd, &status), 0)
          XCTAssertEqual(status.st_mode & 0o7777, 0o775)
        })
      var status = stat()
      XCTAssertEqual(lstat(root.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o7777, 0o755)
      XCTAssertEqual(status.st_uid, geteuid())
      XCTAssertEqual(status.st_gid, geteuid() == 0 ? 0 : getegid())
      XCTAssertEqual(try opened.read(".IAPhysicalMedia", maximum: 64), Data("media".utf8))
      // A root that is already safe is left as it is.
      XCTAssertEqual(chmod(root.path, 0o700), 0)
      _ = try tree(root)
      XCTAssertEqual(mode(root), 0o700)
    }

    func testAnOwnedRootIsNotChangedWhenItsMountIsRefused() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      XCTAssertThrowsError(
        try tree(
          root, verifyMount: { _, _, _ in throw NativeHandoffValidationError.invalidTarget }))
      XCTAssertEqual(mode(root), 0o775)
    }

    func testAGroupWritableOwnedRootThatCannotBeChangedIsRefused() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      // An immutable folder refuses the owner and mode change.
      XCTAssertEqual(chflags(root.path, UInt32(UF_IMMUTABLE)), 0)
      XCTAssertThrowsError(try tree(root)) {
        XCTAssertEqual($0 as? NativeHandoffValidationError, .unsafePath)
      }
      XCTAssertEqual(mode(root), 0o775)
      // The same root passes as a volume the installer does not own, which
      // shows the refusal above is the owned-root rule.
      _ = try tree(root, owned: false)
      XCTAssertEqual(mode(root), 0o775)
    }

    func testAWorldWritableOwnedRootIsRefusedAndLeftAlone() throws {
      let root = try volumeRoot(mode: 0o777)
      defer { remove(root) }
      XCTAssertThrowsError(try tree(root))
      XCTAssertEqual(mode(root), 0o777)
    }

    func testAReadOnlyMountIsReadAsItIsAndProtectedBeforeTheFirstWrite() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      // Read-only: the root can't be changed, and nothing in it can be renamed.
      let opened = try tree(root, readOnly: true)
      XCTAssertEqual(mode(root), 0o775)
      XCTAssertEqual(try opened.read(".IAPhysicalMedia", maximum: 64), Data("media".utf8))
      XCTAssertFalse(try opened.isAbsent(".IAPhysicalMedia"))
      XCTAssertEqual(mode(root), 0o775)
      // The same tree after the volume is remounted writable: the first
      // write makes the root safe, and refuses when it can't.
      XCTAssertEqual(chflags(root.path, UInt32(UF_IMMUTABLE)), 0)
      XCTAssertThrowsError(try opened.createDirectory("Aurora/Recovery"))
      XCTAssertThrowsError(try opened.writableParent("aura"))
      XCTAssertThrowsError(try opened.relativeLink("Restore", target: "Aurora/Restore"))
      XCTAssertEqual(chflags(root.path, 0), 0)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Aurora").path))
      XCTAssertEqual(mode(root), 0o775)
      try opened.createDirectory("Aurora/Recovery")
      XCTAssertEqual(mode(root), 0o755)
      XCTAssertEqual(mode(root.appendingPathComponent("Aurora/Recovery")), 0o755)
    }

    func testTheMediaMarkerIsRenamedOnlyUnderAProtectedRoot() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let core = root.appendingPathComponent("System/Library/CoreServices")
      try FileManager.default.createDirectory(
        at: core, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
      try Data("version".utf8).write(to: core.appendingPathComponent("SystemVersion.plist"))
      XCTAssertEqual(chmod(root.path, 0o775), 0)
      let opened = try tree(root, readOnly: true)
      XCTAssertEqual(chflags(root.path, UInt32(UF_IMMUTABLE)), 0)
      XCTAssertThrowsError(try opened.prepareForStartup())
      XCTAssertEqual(chflags(root.path, 0), 0)
      XCTAssertFalse(try opened.isAbsent(".IAPhysicalMedia"))
      try opened.prepareForStartup()
      XCTAssertEqual(mode(root), 0o755)
      XCTAssertEqual(
        try opened.read("IAPhysicalMedia-disabled.plist", maximum: 64), Data("media".utf8))
      XCTAssertTrue(try opened.isAbsent(".IAPhysicalMedia"))
    }

    func testAVolumeRootTheInstallerDoesNotOwnKeepsItsMode() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let opened = try tree(root, owned: false)
      try opened.createDirectory("Aurora/Recovery")
      XCTAssertEqual(mode(root), 0o775)
    }

    func testRollbackMetadataReachesTheOpenedFileNotWhatItsNameBecame() throws {
      let root = try volumeRoot(mode: 0o755)
      defer { remove(root) }
      let marker = root.appendingPathComponent(".IAPhysicalMedia")
      let other = root.appendingPathComponent("other")
      try Data("other".utf8).write(to: other)
      XCTAssertEqual(chmod(other.path, 0o644), 0)

      // The name now leads elsewhere: refused, and the other file is untouched.
      try FileManager.default.removeItem(at: marker)
      try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
      XCTAssertThrowsError(
        try RecoveryFileTransaction.setMetadata(
          marker, owner: (geteuid(), getegid()), mode: 0o600, flags: UInt32(UF_NODUMP)))
      XCTAssertThrowsError(try RecoveryFileTransaction.setMetadata(marker, flags: 0))
      var status = stat()
      XCTAssertEqual(lstat(other.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o7777, 0o644)
      XCTAssertEqual(status.st_flags & UInt32(UF_NODUMP), 0)

      // A second name for another file: refused where the file was just written.
      try FileManager.default.removeItem(at: marker)
      XCTAssertEqual(Darwin.link(other.path, marker.path), 0)
      XCTAssertThrowsError(
        try RecoveryFileTransaction.setMetadata(marker, mode: 0o600, singleName: true))
      XCTAssertEqual(mode(other), 0o644)

      // The file itself takes owner, mode and flags.
      try FileManager.default.removeItem(at: marker)
      try Data("media".utf8).write(to: marker)
      try RecoveryFileTransaction.setMetadata(
        marker, owner: (geteuid(), getegid()), mode: 0o640, flags: UInt32(UF_NODUMP),
        singleName: true)
      XCTAssertEqual(lstat(marker.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o7777, 0o640)
      XCTAssertNotEqual(status.st_flags & UInt32(UF_NODUMP), 0)
      try RecoveryFileTransaction.setMetadata(marker, flags: 0)
    }

    func testAMarkerRollbackRestoresBytesModeAndFlagsAndRefusesALinkedName() throws {
      let root = try volumeRoot(mode: 0o755)
      defer { remove(root) }
      let marker = root.appendingPathComponent(".IAPhysicalMedia")
      XCTAssertEqual(chflags(marker.path, UInt32(UF_NODUMP)), 0)
      let transaction = try RecoveryFileTransaction(
        directory: root.appendingPathComponent("snapshot"), files: [marker])
      try transaction.clearImmutableFlags()
      try Data("changed".utf8).write(to: marker, options: .atomic)
      XCTAssertEqual(chmod(marker.path, 0o600), 0)
      try transaction.restore()
      var status = stat()
      XCTAssertEqual(lstat(marker.path, &status), 0)
      XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(status.st_mode & 0o7777, 0o644)
      XCTAssertNotEqual(status.st_flags & UInt32(UF_NODUMP), 0)
      XCTAssertEqual(try Data(contentsOf: marker), Data("media".utf8))

      // A link under the marker's name is not a regular file: nothing goes through it.
      let other = root.appendingPathComponent("other")
      try Data("other".utf8).write(to: other)
      XCTAssertEqual(chmod(other.path, 0o644), 0)
      try FileManager.default.removeItem(at: marker)
      try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
      XCTAssertThrowsError(try transaction.restore())
      XCTAssertThrowsError(try transaction.clearImmutableFlags())
      XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))
      XCTAssertEqual(mode(other), 0o644)
    }
  }
#endif
