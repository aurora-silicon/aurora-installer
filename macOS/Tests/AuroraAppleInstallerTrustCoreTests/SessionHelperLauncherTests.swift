#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class SessionHelperLauncherTests: XCTestCase {
    // MARK: The helper's job

    func testTheJobIsTheEmbeddedOneRunFromTheCopy() throws {
      let job = try SessionHelperLauncher.job(
        embedded: try embeddedJob(), label: "helper.label",
        program: "/Library/PrivilegedHelperTools/helper.label")
      XCTAssertEqual(job["Label"] as? String, "helper.label")
      XCTAssertEqual(job["Program"] as? String, "/Library/PrivilegedHelperTools/helper.label")
      XCTAssertEqual(job["MachServices"] as? [String: Bool], ["helper.label": true])
      XCTAssertEqual(job["UserName"] as? String, "root")
      XCTAssertEqual(
        job["EnvironmentVariables"] as? [String: String],
        [InstallerProductIdentity.clientRequirementEnvironmentVariable: #"identifier "app""#])
      // Nothing that would start it at load or keep it running: launchd starts
      // it when the app connects, as it did the job SMJobBless wrote.
      XCTAssertNil(job["RunAtLoad"])
      XCTAssertNil(job["KeepAlive"])
    }

    func testAJobForAnotherServiceOrWithoutItsClientIsRefused() throws {
      let cases: [(String, (inout [String: Any]) -> Void)] = [
        ("another label", { $0["Label"] = "other.label" }),
        ("no service", { $0["MachServices"] = [:] as [String: Bool] }),
        ("no client", { $0["EnvironmentVariables"] = [:] as [String: String] }),
        ("its own program", { $0["Program"] = "/tmp/elsewhere" }),
        ("its own arguments", { $0["ProgramArguments"] = ["/tmp/elsewhere"] }),
      ]
      for (name, change) in cases {
        XCTAssertThrowsError(
          try SessionHelperLauncher.job(
            embedded: try embeddedJob(change), label: "helper.label", program: "/p"), name
        ) {
          XCTAssertEqual($0 as? SessionHelperLaunchError, .noJob, name)
        }
      }
      XCTAssertThrowsError(
        try SessionHelperLauncher.job(
          embedded: Data("junk".utf8), label: "helper.label", program: "/p"))
    }

    func testASectionIsReadFromTheArm64SliceOfASystemTool() throws {
      // A macOS tool with an Info.plist linked into __TEXT,__info_plist, as the
      // helper carries one and its launchd job.
      let donor = URL(fileURLWithPath: "/usr/bin/automator")
      guard
        let expected = CFBundleCopyInfoDictionaryForURL(donor as CFURL) as? [String: Any],
        let identifier = expected["CFBundleIdentifier"] as? String
      else {
        throw XCTSkip("no system tool with an embedded Info.plist")
      }
      let section = try XCTUnwrap(
        MachOSection.contents(
          segment: "__TEXT", section: "__info_plist", of: try Data(contentsOf: donor)))
      let read = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: section, format: nil) as? [String: Any])
      XCTAssertEqual(read["CFBundleIdentifier"] as? String, identifier)
      XCTAssertNil(
        MachOSection.contents(
          segment: "__TEXT", section: "__launchd_plist", of: try Data(contentsOf: donor)))
      XCTAssertNil(MachOSection.contents(segment: "__TEXT", section: "__info_plist", of: Data()))
      XCTAssertNil(
        MachOSection.contents(
          segment: "__TEXT", section: "__info_plist", of: Data(repeating: 0xff, count: 64)))
    }

    func testTheSessionHelperLeavesTheLaunchDaemonsFoldersAlone() {
      XCTAssertEqual(
        InstallerProductIdentity.installedHelperPath,
        "/Library/PrivilegedHelperTools/\(InstallerProductIdentity.helperIdentifier)")
      XCTAssertEqual(
        SessionHelperLauncher.setupLabel(InstallerProductIdentity.helperIdentifier),
        InstallerProductIdentity.helperIdentifier + ".setup")
    }

    // MARK: Root steps

    func testExitStatusWaitsUntilTheStepHasStopped() {
      let running =
        "system/x = {\n\tstate = running\n\tpid = 42\n\tlast exit code = (never exited)\n}"
      let notYet = "system/x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}"
      XCTAssertNil(SessionHelperLauncher.exitStatus(launchctlPrint: running))
      XCTAssertNil(SessionHelperLauncher.exitStatus(launchctlPrint: notYet))
    }

    func testExitStatusReadsTheCodeAndItsName() {
      let cases: [(String, Int32)] = [
        ("\tstate = not running\n\truns = 1\n\tlast exit code = 0\n", 0),
        ("\tstate = not running\n\tlast exit code = 1\n", 1),
        ("\tstate = not running\n\tlast exit code = 78: EX_CONFIG\n", 78),
        ("\tstate = not running\n\tlast terminating signal = Killed: 9\n", -1),
      ]
      for (output, expected) in cases {
        XCTAssertEqual(SessionHelperLauncher.exitStatus(launchctlPrint: output), expected, output)
      }
    }

    // MARK: The checked copy

    func testAnAppleSignedCopyMeetingTheRequirementIsAccepted() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let copy = try copyOfTrue(in: root)
      XCTAssertNoThrow(
        try SessionHelperLauncher.verifyInstalledCopy(
          copy.path, requirement: Self.trueRequirement, owner: geteuid()))
    }

    func testACopyOfAnotherProgramIsRejected() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let copy = try copyOfTrue(in: root)
      XCTAssertThrowsError(
        try SessionHelperLauncher.verifyInstalledCopy(
          copy.path, requirement: #"anchor apple and identifier "com.apple.false""#,
          owner: geteuid())
      ) { error in
        XCTAssertEqual(error as? SessionHelperLaunchError, .signatureRejected)
      }
    }

    func testACopyAnotherAccountCouldChangeIsRejected() throws {
      let fileManager = FileManager.default
      let cases: [(String, (URL, URL) throws -> Void)] = [
        (
          "group-writable copy",
          { copy, _ in
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: copy.path)
          }
        ),
        (
          "group-writable folder",
          { _, root in
            try fileManager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: root.path)
          }
        ),
        (
          "second link",
          { copy, root in
            try fileManager.linkItem(at: copy, to: root.appendingPathComponent("other"))
          }
        ),
        (
          "symbolic link",
          { copy, root in
            let target = root.appendingPathComponent("target")
            try fileManager.moveItem(at: copy, to: target)
            try fileManager.createSymbolicLink(at: copy, withDestinationURL: target)
          }
        ),
      ]
      for (name, damage) in cases {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let copy = try copyOfTrue(in: root)
        try damage(copy, root)
        XCTAssertThrowsError(
          try SessionHelperLauncher.verifyInstalledCopy(
            copy.path, requirement: Self.trueRequirement, owner: geteuid()), name
        ) { error in
          guard case .unsafeCopy? = error as? SessionHelperLaunchError else {
            return XCTFail("\(name): \(error)")
          }
        }
      }
    }

    func testACopyOwnedByAnotherAccountIsRejected() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let copy = try copyOfTrue(in: root)
      XCTAssertThrowsError(
        try SessionHelperLauncher.verifyInstalledCopy(
          copy.path, requirement: Self.trueRequirement, owner: geteuid() + 1))
    }

    // MARK: Replacement

    func testReplacementStopsTheOldJobRemovesTheStartupJobAndChecksTheCopy() throws {
      let fileManager = FileManager.default
      let root = try temporaryDirectory()
      defer { try? fileManager.removeItem(at: root) }
      let bundled = try copyOfTrue(in: root, named: "bundled")
      let tools = root.appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
      let installed = tools.appendingPathComponent("helper.label").path
      let startupJob = root.appendingPathComponent("helper.label.plist")
      try Data("<plist/>".utf8).write(to: startupJob)
      let launchd = FakeLaunchd(loaded: ["helper.label"])

      // The copy is checked and then refused: /usr/bin/true carries no
      // launchd job, so none is submitted.
      XCTAssertThrowsError(
        try SessionHelperLauncher.replace(
          label: "helper.label", bundledHelper: bundled,
          helperRequirement: Self.trueRequirement, launchd: launchd,
          installed: installed, persistentJob: startupJob.path, owner: geteuid())
      ) { error in
        XCTAssertEqual(error as? SessionHelperLaunchError, .noJob)
      }

      let steps = launchd.calls.map { $0.split(separator: " ").first.map(String.init) ?? "" }
      XCTAssertEqual(steps, ["remove", "root:/bin/rm", "root:/bin/mkdir", "root:/bin/cp"])
      XCTAssertFalse(fileManager.fileExists(atPath: startupJob.path))
      XCTAssertTrue(fileManager.contentsEqual(atPath: bundled.path, andPath: installed))
      XCTAssertEqual(launchd.submitted, [])
      // The staged copy in the app's temporary folder is gone.
      let staged = launchd.calls.last?.split(separator: " ").dropFirst(2).first.map(String.init)
      XCTAssertNotNil(staged)
      XCTAssertFalse(fileManager.fileExists(atPath: staged ?? "/"))
    }

    func testAJobThatWillNotUnloadStopsTheReplacement() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let bundled = try copyOfTrue(in: root, named: "bundled")
      let launchd = FakeLaunchd(loaded: ["helper.label"], unloads: false)

      XCTAssertThrowsError(
        try SessionHelperLauncher.replace(
          label: "helper.label", bundledHelper: bundled,
          helperRequirement: Self.trueRequirement, launchd: launchd,
          installed: root.appendingPathComponent("installed").path,
          persistentJob: root.appendingPathComponent("absent.plist").path, owner: geteuid())
      ) { error in
        XCTAssertEqual(error as? SessionHelperLaunchError, .stillLoaded)
      }
      XCTAssertEqual(
        launchd.calls, ["remove helper.label", "root:/bin/launchctl bootout system/helper.label"])
    }

    // MARK: Fixtures

    private static let trueRequirement = #"anchor apple and identifier "com.apple.true""#

    /// The job helper-plists links into a named-identity helper.
    private func embeddedJob(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
      var job: [String: Any] = [
        "Label": "helper.label",
        "MachServices": ["helper.label": true],
        "UserName": "root",
        "EnvironmentVariables": [
          InstallerProductIdentity.clientRequirementEnvironmentVariable: #"identifier "app""#
        ],
      ]
      change(&job)
      return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
      return root
    }

    private func copyOfTrue(in root: URL, named name: String = "helper") throws -> URL {
      let copy = root.appendingPathComponent(name, isDirectory: false)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
      return copy
    }
  }

  /// Records what the launcher asks of launchd and runs the root steps as
  /// the test's own account.
  private final class FakeLaunchd: SessionLaunchd, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private let unloads: Bool
    private var recorded: [String] = []
    private var jobs: [String] = []

    init(loaded: Set<String> = [], unloads: Bool = true) {
      self.loaded = loaded
      self.unloads = unloads
    }

    var calls: [String] { lock.withLock { recorded } }
    var submitted: [String] { lock.withLock { jobs } }

    func remove(_ label: String) {
      lock.withLock {
        recorded.append("remove \(label)")
        if unloads { loaded.remove(label) }
      }
    }

    func isLoaded(_ label: String) -> Bool {
      lock.withLock { loaded.contains(label) }
    }

    func submit(_ job: [String: Any]) throws {
      lock.withLock { jobs.append(job["Label"] as? String ?? "") }
    }

    func runAsRoot(_ arguments: [String], label: String) throws {
      lock.withLock { recorded.append("root:" + arguments.joined(separator: " ")) }
      guard arguments.first != "/bin/launchctl" else { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: arguments[0])
      process.arguments = Array(arguments.dropFirst())
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SessionHelperLaunchError.stepFailed(arguments[0], process.terminationStatus)
      }
    }
  }
#endif
