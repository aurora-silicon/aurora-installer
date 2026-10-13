#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class PackageInstalledAppRetirementTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var aside: URL!

    override func setUpWithError() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      applications = root.appendingPathComponent("Applications", isDirectory: true)
      aside = root.appendingPathComponent("private", isDirectory: true)
      // The aside directory is left for the retirement to create, closed to
      // everyone else, as it does in production.
      try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: root)
    }

    func testRemovesIdlePackageInstalledCopiesUnderEitherName() throws {
      try makeBundle("Current")
      try makeBundle("Legacy")

      let results = retirement().run()

      XCTAssertEqual(results, ["Current.app": .removed, "Legacy.app": .removed])
      XCTAssertFalse(exists("Current.app"))
      XCTAssertFalse(exists("Legacy.app"))
    }

    func testReportsAbsentBundles() {
      XCTAssertEqual(retirement().run(), ["Current.app": .absent, "Legacy.app": .absent])
    }

    func testKeepsALink() throws {
      try makeBundle("Elsewhere")
      try FileManager.default.createSymbolicLink(
        at: applications.appendingPathComponent("Current.app"),
        withDestinationURL: applications.appendingPathComponent("Elsewhere.app"))

      XCTAssertEqual(retirement().run()["Current.app"], .keptLink)
      XCTAssertTrue(exists("Elsewhere.app"))
    }

    func testKeepsABundleWithAnotherIdentifier() throws {
      try makeBundle("Current", identifier: "someone.else")

      XCTAssertEqual(retirement().run()["Current.app"], .keptForeignIdentifier("someone.else"))
      XCTAssertTrue(exists("Current.app"))
    }

    func testKeepsACopyThePersonPutThere() throws {
      try makeBundle("Current")
      // The package installs as root; this copy belongs to the test user.
      let results = retirement(packageOwner: getuid() == 0 ? 501 : 0).run()

      XCTAssertEqual(results["Current.app"], .keptNotInstalledByPackage)
      XCTAssertTrue(exists("Current.app"))
    }

    func testKeepsARunningCopy() throws {
      try makeBundle("Current")
      let running = applications.appendingPathComponent("Current.app/Contents/MacOS/app").path

      XCTAssertEqual(retirement(running: [running]).run()["Current.app"], .keptRunning)
      XCTAssertTrue(exists("Current.app"))
    }

    func testAProcessBesideTheBundleDoesNotCountAsRunningFromIt() throws {
      try makeBundle("Current")
      let beside = applications.appendingPathComponent("Current.app-other/Contents/MacOS/app").path

      XCTAssertEqual(retirement(running: [beside]).run()["Current.app"], .removed)
    }

    func testKeepsSomethingThatIsNotABundle() throws {
      try Data().write(to: applications.appendingPathComponent("Current.app"))
      try FileManager.default.createDirectory(
        at: applications.appendingPathComponent("Legacy.app"), withIntermediateDirectories: true)

      XCTAssertEqual(
        retirement().run(), ["Current.app": .keptNotABundle, "Legacy.app": .keptNotABundle])
    }

    func testOnlyLooksAtTheFixedNames() throws {
      try makeBundle("Unrelated")

      _ = retirement().run()

      XCTAssertTrue(exists("Unrelated.app"))
    }

    func testDeletesOnlyWhatItMovedEvenIfTheNameIsRetakenMeanwhile() throws {
      try makeBundle("Current")
      let race = Race { try? self.makeBundle("Current", identifier: "someone.else") }

      let results = retirement(runningExecutablePaths: { race.paths() }).run()

      XCTAssertEqual(results["Current.app"], .removed)
      // The newcomer took the name after the move; it is not what was checked,
      // so it is left alone.
      XCTAssertTrue(exists("Current.app"))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: aside.path), "an empty aside is removed")
    }

    func testAKeptBundleStaysAsideRatherThanReplaceANewcomer() throws {
      try makeBundle("Current")
      let running = applications.appendingPathComponent("Current.app/Contents/MacOS/app").path
      let race = Race(running: [running]) {
        try? self.makeBundle("Current", identifier: "newcomer")
      }

      let results = retirement(runningExecutablePaths: { race.paths() }).run()

      guard case .keptRemovalFailed(let reason) = results["Current.app"] else {
        return XCTFail("expected it kept aside, got \(String(describing: results["Current.app"]))")
      }
      XCTAssertTrue(reason.contains("name taken"), reason)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: aside.path).count, 1)
      var status = stat()
      XCTAssertEqual(lstat(aside.path, &status), 0)
      XCTAssertEqual(status.st_mode & 0o077, 0, "the aside directory is closed to everyone else")
    }

    func testOnlyThisAppAsThePackageInstalledItIsEverMoved() throws {
      try makeBundle("Current", identifier: "someone.else")
      try makeBundle("Legacy")
      let results = retirement(packageOwner: getuid() == 0 ? 501 : 0).run()

      XCTAssertEqual(results["Current.app"], .keptForeignIdentifier("someone.else"))
      XCTAssertEqual(results["Legacy.app"], .keptNotInstalledByPackage)
      XCTAssertTrue(exists("Current.app"))
      XCTAssertTrue(exists("Legacy.app"))
      // The aside directory is made only once a bundle passes the identity
      // check, so neither was ever moved.
      XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    func testTheAsideDirectoryIsOutsideWhatSelfUninstallDeletes() {
      let state = InstallerProductIdentity.helperWorkingDirectory
      let aside = state + ".aside"
      XCTAssertFalse(aside.hasPrefix(state + "/"))
      XCTAssertEqual(URL(fileURLWithPath: aside).deletingLastPathComponent().path, "/var/db")
    }

    func testAnUnverifiableProcessListKeepsTheBundle() throws {
      try makeBundle("Current")
      let results = retirement(runningExecutablePaths: { nil }).run()
      XCTAssertEqual(results["Current.app"], .keptRunning)
      XCTAssertTrue(exists("Current.app"))
    }

    func testRunningExecutablePathsIncludesThisProcess() {
      let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
      let paths = PackageInstalledAppRetirement.runningExecutablePaths()
      XCTAssertFalse(paths.isEmpty)
      XCTAssertTrue(
        paths.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == own },
        "\(own) not among \(paths.count) processes")
    }

    // MARK: Fixtures

    private func retirement(
      packageOwner: uid_t = getuid(), running: [String] = []
    ) -> PackageInstalledAppRetirement {
      retirement(packageOwner: packageOwner, runningExecutablePaths: { running })
    }

    private func retirement(
      packageOwner: uid_t = getuid(), runningExecutablePaths: @escaping @Sendable () -> [String]?
    ) -> PackageInstalledAppRetirement {
      PackageInstalledAppRetirement(
        applicationsDirectory: applications,
        privateDirectory: aside,
        appNames: ["Current", "Legacy"],
        bundleIdentifier: "com.example.installer",
        packageOwner: packageOwner,
        runningExecutablePaths: runningExecutablePaths)
    }

    /// Runs `swap` once, the moment the retirement first looks for running
    /// processes after moving the bundle aside, then reports `running`.
    private final class Race: @unchecked Sendable {
      private let lock = NSLock()
      private var calls = 0
      private let swap: () -> Void
      private let running: [String]
      init(running: [String] = [], swap: @escaping () -> Void) {
        self.running = running
        self.swap = swap
      }
      func paths() -> [String] {
        let call = lock.withLock { () -> Int in
          calls += 1
          return calls
        }
        // Call 1 is the check before the move; call 2 the first after it.
        if call == 2 { swap() }
        return call >= 2 ? running : []
      }
    }

    private func makeBundle(_ name: String, identifier: String = "com.example.installer") throws {
      let contents = applications.appendingPathComponent("\(name).app/Contents", isDirectory: true)
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
      try info.write(to: contents.appendingPathComponent("Info.plist"))
      try Data().write(to: contents.appendingPathComponent("MacOS/app"))
    }

    private func exists(_ name: String) -> Bool {
      var status = stat()
      return lstat(applications.appendingPathComponent(name).path, &status) == 0
    }
  }
#endif
