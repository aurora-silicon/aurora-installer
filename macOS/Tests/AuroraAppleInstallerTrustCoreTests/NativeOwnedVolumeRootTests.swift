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
      verifyMount: @escaping @Sendable (Int32, URL, String) throws -> Void = { _, _, _ in },
      mountFlags: @escaping @Sendable (Int32) -> UInt32? = { _ in 0 },
      enableOwnership: @escaping @Sendable (String) throws -> Void = { _ in
        XCTFail("Ownership was enabled on a mount that honours it")
      },
      writableACL: @escaping @Sendable (Int32) -> Bool = { _ in false }
    ) throws -> NativeHandoffFileTree {
      try NativeHandoffFileTree(
        root, protected: true, owner: geteuid(), volumeRoot: true, ownedVolumeRoot: owned,
        volumeDevice: "disk8s1", verifyMount: verifyMount, mountedReadOnly: { _ in readOnly },
        mountFlags: mountFlags, enableOwnership: enableOwnership, writableACL: writableACL)
    }

    /// A mount whose ownership is ignored until `enableOwnership` runs, if
    /// `honoured` says it takes effect; records the devices it ran for.
    private final class OwnershipMount: @unchecked Sendable {
      private let lock = NSLock()
      private var ignored: Bool
      private var calls = [String]()
      let honoured: Bool
      init(honoured: Bool, ignored: Bool = true) {
        self.honoured = honoured
        self.ignored = ignored
      }
      var devices: [String] { lock.withLock { calls } }
      func flags(_: Int32) -> UInt32? {
        let local = UInt32(MNT_LOCAL)
        return lock.withLock { ignored ? local | UInt32(MNT_IGNORE_OWNERSHIP) : local }
      }
      func enable(_ device: String) throws {
        lock.withLock {
          calls.append(device)
          if honoured { ignored = false }
        }
      }
      /// Someone mounts the volume again with ownership ignored.
      func remount() { lock.withLock { ignored = true } }
    }

    private func inode(_ url: URL) -> ino_t {
      var status = stat()
      XCTAssertEqual(lstat(url.path, &status), 0)
      return status.st_ino
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

    func testAnOwnedRootOnAMountThatIgnoresOwnershipIsMadeToHonourItFirst() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let mount = OwnershipMount(honoured: true)
      let opened = try tree(
        root, mountFlags: { mount.flags($0) }, enableOwnership: { try mount.enable($0) })
      XCTAssertEqual(mount.devices, ["disk8s1"])
      XCTAssertEqual(mode(root), 0o755)
      try opened.createDirectory("Aurora/Recovery")
      XCTAssertEqual(mount.devices, ["disk8s1"])
    }

    func testAnOwnedRootWhoseMountStillIgnoresOwnershipIsRefusedAndLeftAlone() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let mount = OwnershipMount(honoured: false)
      XCTAssertThrowsError(
        try tree(root, mountFlags: { mount.flags($0) }, enableOwnership: { try mount.enable($0) })
      ) { XCTAssertEqual($0 as? NativeHandoffValidationError, .unsafePath) }
      XCTAssertEqual(mount.devices, ["disk8s1"])
      XCTAssertEqual(mode(root), 0o775)
      // A failing diskutil is a refusal too.
      XCTAssertThrowsError(
        try tree(
          root, mountFlags: { mount.flags($0) },
          enableOwnership: { _ in throw NativeHandoffValidationError.invalidTarget }))
      XCTAssertEqual(mode(root), 0o775)
      // Mount flags that can't be read prove nothing either.
      XCTAssertThrowsError(
        try tree(root, mountFlags: { _ in nil }, enableOwnership: { _ in }))
      XCTAssertEqual(mode(root), 0o775)
      // A volume root the installer does not own is not held to the rule.
      _ = try tree(root, owned: false, mountFlags: { mount.flags($0) })
      XCTAssertEqual(mount.devices, ["disk8s1"])
      XCTAssertFalse(NativeHandoffFileTree.ignoresOwnership(UInt32(MNT_LOCAL)))
      XCTAssertTrue(NativeHandoffFileTree.ignoresOwnership(UInt32(MNT_IGNORE_OWNERSHIP)))
      XCTAssertTrue(NativeHandoffFileTree.ignoresOwnership(nil))
    }

    func testAnOwnedRootRemountedToIgnoreOwnershipIsNotWritten() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      let mount = OwnershipMount(honoured: false, ignored: false)
      let opened = try tree(root, readOnly: true, mountFlags: { mount.flags($0) })
      mount.remount()
      XCTAssertThrowsError(try opened.createDirectory("Aurora"))
      XCTAssertEqual(mode(root), 0o775)
      XCTAssertTrue(try opened.isAbsent("Aurora"))
    }

    func testAnOwnedRootOrFolderWithAWriteAccessEntryIsRefused() throws {
      let root = try volumeRoot()
      defer { remove(root) }
      XCTAssertThrowsError(try tree(root, writableACL: { _ in true })) {
        XCTAssertEqual($0 as? NativeHandoffValidationError, .unsafePath)
      }
      XCTAssertEqual(mode(root), 0o775)
      let folder = root.appendingPathComponent("Aurora")
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
      let marked = inode(folder)
      let opened = try tree(
        root,
        writableACL: { fd in
          var status = stat()
          return fstat(fd, &status) == 0 && status.st_ino == marked
        })
      XCTAssertThrowsError(try opened.createDirectory("Aurora/Recovery"))
      XCTAssertThrowsError(try opened.requireProtected(["Aurora"], folders: ["Aurora"]))
      XCTAssertTrue(try opened.isAbsent("System"))
      try opened.createDirectory("System/Library")
      // A folder made here carries none.
      let fd = open(folder.path, O_RDONLY | O_CLOEXEC)
      defer { close(fd) }
      XCTAssertGreaterThanOrEqual(fd, 0)
      XCTAssertFalse(NativeHandoffFileTree.hasWriteACL(fd))
    }

    /// The Recovery app update works by path under these names; each one on
    /// the way must be the owner's alone, whatever the root was before.
    func testTheRecoveryAppUpdateRefusesEntriesLeftWhileTheRootWasWritable() throws {
      let fm = FileManager.default
      let root = try volumeRoot()
      defer { remove(root) }
      let state = root.appendingPathComponent("Aurora/Recovery/State")
      try fm.createDirectory(
        at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
      for name in ["Aurora", "Aurora/Recovery", "Aurora/Recovery/State"] {
        XCTAssertEqual(chmod(root.appendingPathComponent(name).path, 0o755), 0)
      }
      try Data("receipt".utf8).write(to: state.appendingPathComponent("installation.json"))
      let opened = try tree(root)
      try RecoveryAccountHandoff.requireProtectedAppUpdatePaths(opened)

      func refused(_ change: () throws -> Void, _ undo: () throws -> Void) throws {
        try change()
        XCTAssertThrowsError(try RecoveryAccountHandoff.requireProtectedAppUpdatePaths(opened))
        try undo()
        try RecoveryAccountHandoff.requireProtectedAppUpdatePaths(opened)
      }
      // A group-writable folder at any depth.
      for name in ["Aurora", "Aurora/Recovery", "Aurora/Recovery/State"] {
        let path = root.appendingPathComponent(name).path
        try refused(
          { XCTAssertEqual(chmod(path, 0o775), 0) }, { XCTAssertEqual(chmod(path, 0o755), 0) })
      }
      // A link in place of a folder on the way.
      let recovery = root.appendingPathComponent("Aurora/Recovery")
      let elsewhere = root.appendingPathComponent("elsewhere")
      try refused(
        {
          try fm.moveItem(at: recovery, to: elsewhere)
          try fm.createSymbolicLink(at: recovery, withDestinationURL: elsewhere)
        },
        {
          try fm.removeItem(at: recovery)
          try fm.moveItem(at: elsewhere, to: recovery)
        })
      // A top-level marker or launcher others can write, or that has another name.
      let marker = root.appendingPathComponent(".IAPhysicalMedia")
      try refused(
        { XCTAssertEqual(chmod(marker.path, 0o664), 0) },
        { XCTAssertEqual(chmod(marker.path, 0o644), 0) })
      let alias = root.appendingPathComponent("aura")
      try refused(
        { XCTAssertEqual(Darwin.link(marker.path, alias.path), 0) },
        { try fm.removeItem(at: alias) })
      // A folder in place of a file, or the reverse.
      let receipt = state.appendingPathComponent("installation.json")
      try refused(
        {
          try fm.removeItem(at: receipt)
          try fm.createDirectory(at: receipt, withIntermediateDirectories: false)
        },
        {
          try fm.removeItem(at: receipt)
          try Data("receipt".utf8).write(to: receipt)
        })
      let app = root.appendingPathComponent("Aurora Installer.app")
      try refused(
        { try Data("app".utf8).write(to: app) }, { try fm.removeItem(at: app) })
    }

    func testTheRecoveryAppUpdateRefusesAFolderAnotherAccountOwns() throws {
      try XCTSkipUnless(geteuid() == 0, "Only root can give a folder to another account.")
      let root = try volumeRoot()
      defer { remove(root) }
      let aurora = root.appendingPathComponent("Aurora")
      try FileManager.default.createDirectory(
        at: aurora, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
      XCTAssertEqual(chown(aurora.path, 501, 20), 0)
      XCTAssertThrowsError(try RecoveryAccountHandoff.requireProtectedAppUpdatePaths(tree(root)))
    }
  }
#endif
