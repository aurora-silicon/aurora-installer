#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerHelperProvisionerTests: XCTestCase {
    // MARK: Status

    func testRegistrationStatusFollowsTheJobFileAlone() {
      XCTAssertEqual(provisioner(FakeProbe(registered: false)).registrationStatus, .missing)
      // Registered counts as current without asking the helper.
      let unanswering = FakeProbe(registered: true, answering: false)
      XCTAssertEqual(provisioner(unanswering).registrationStatus, .current)
      XCTAssertEqual(unanswering.pings, 0)
    }

    func testProbeStatusClassifiesTheInstalledHelper() async {
      let cases: [(FakeProbe, String?, InstallerHelperStatus)] = [
        (FakeProbe(registered: false), "28", .missing),
        (FakeProbe(registered: true, answering: false), "28", .disabled),
        (FakeProbe(registered: true, answering: false, loaded: true), "28", .outdated),
        (FakeProbe(registered: true, answering: false, slow: true), "28", .busy),
        (FakeProbe(registered: true, version: "28"), "28", .current),
        (FakeProbe(registered: true, version: "27"), "28", .outdated),
        (FakeProbe(registered: true, version: nil), "28", .outdated),
        (FakeProbe(registered: true, version: nil), nil, .current),
      ]
      for (probe, bundled, expected) in cases {
        let status = await provisioner(probe, bundled: bundled).probeStatus()
        XCTAssertEqual(status, expected, "bundled \(bundled ?? "nil")")
      }
    }

    // MARK: ensureCurrent

    func testCurrentHelperNeedsNothing() async {
      let blesser = FakeBlesser()
      let outcome = await provisioner(
        FakeProbe(registered: true, version: "28"), blesser: blesser
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .alreadyCurrent)
      XCTAssertEqual(blesser.calls, [])
    }

    func testMissingHelperIsInstalledSilently() async {
      let probe = FakeProbe(registered: false, installsVersion: "28")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(blesser.calls, [.silent("owner")])
    }

    func testOutdatedHelperIsReplacedSilently() async {
      let probe = FakeProbe(registered: true, version: nil, installsVersion: "28")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(blesser.calls, [.silent("owner")])
    }

    func testRefusedSilentRouteFallsBackToTheDialog() async {
      let probe = FakeProbe(registered: false, installsVersion: "28")
      let blesser = FakeBlesser(silent: .refused, dialog: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedWithDialog)
      XCTAssertEqual(blesser.calls, [.silent("owner"), .dialog])
    }

    func testCancelledOrRefusedDialogIsReportedAsCancelled() async {
      for dialog in [InstallerHelperBlessResult.cancelled, .refused] {
        let blesser = FakeBlesser(silent: .refused, dialog: dialog)
        let outcome = await provisioner(FakeProbe(registered: false), blesser: blesser)
          .ensureCurrent(owner)
        XCTAssertEqual(outcome, .cancelled, "\(dialog)")
      }
    }

    func testWrongPasswordIsRejectedBeforeAnyInstallation() async {
      let probe = FakeProbe(registered: false)
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        probe, blesser: blesser, validator: FakeValidator(accepts: false)
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .credentialsRejected)
      XCTAssertEqual(blesser.calls, [])
      XCTAssertEqual(probe.pings, 0)
    }

    func testSwitchedOffHelperIsLeftAlone() async {
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: true, answering: false), blesser: blesser
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .disabled)
      XCTAssertEqual(blesser.calls, [])
    }

    func testALoadedHelperThatRefusesThisAppIsReplacedNotReportedAsSwitchedOff() async {
      // Seen on the M3 Air: an earlier installer's helper stays loaded but only
      // accepts its own app.
      let probe = FakeProbe(
        registered: true, answering: false, loaded: true, installsVersion: "28")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(blesser.calls, [.silent("owner")])
    }

    func testABusyHelperIsNeverReplacedMidJob() async {
      // Marcelo's review: a helper verifying a large payload answers late; a
      // re-bless would end its job.
      let blesser = FakeBlesser(silent: .blessed)
      for reenabling in [false, true] {
        let outcome = await provisioner(
          FakeProbe(registered: true, answering: false, slow: true), blesser: blesser
        ).ensureCurrent(owner, reenablingSwitchedOff: reenabling)
        XCTAssertEqual(outcome, .busy)
      }
      XCTAssertEqual(blesser.calls, [])
    }

    func testAStandardAccountCanUseAHelperThatIsAlreadyCurrent() async {
      let outcome = await provisioner(
        FakeProbe(registered: true, version: "28"), administrator: false
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .alreadyCurrent)
    }

    func testAStandardAccountIsToldAnAdministratorIsNeededToInstall() async {
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: false), blesser: blesser, administrator: false
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .notAdministrator)
      XCTAssertEqual(blesser.calls, [])
    }

    func testAWorkingHelperOfAnotherBuildIsNotReplaced() async {
      // Second review: it answers instantly while its engine works; replacing
      // it would end the engine mid-operation.
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: true, version: "27", replacement: false), blesser: blesser
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .busy)
      XCTAssertEqual(blesser.calls, [])
    }

    func testAHelperThatAgreedIsReplacedAndNotReleased() async {
      let probe = FakeProbe(
        registered: true, version: "27", installsVersion: "28", replacement: true)
      let outcome = await provisioner(
        probe, blesser: FakeBlesser(silent: .blessed, installing: probe)
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(probe.cancels, 0)
    }

    func testAHelperThatAgreedIsReleasedWhenTheReplacementDoesNotHappen() async {
      let probe = FakeProbe(registered: true, version: "27", replacement: true)
      let outcome = await provisioner(
        probe, blesser: FakeBlesser(silent: .refused, dialog: .cancelled)
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .cancelled)
      XCTAssertEqual(probe.cancels, 1, "it takes work again")
    }

    func testAHelperThatCannotBeAskedIsNotReplacedWhileItsEngineRuns() async {
      // Third review: no answer is not proof of idleness.
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: true, version: nil, replacement: nil, work: .working),
        blesser: blesser
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .busy)
      XCTAssertEqual(blesser.calls, [])
    }

    func testAnotherInstallerIsAnyOtherProcessOfTheAppEvenFromTheSameBundle() {
      typealias Process = PackageInstalledAppRetirement.RunningProcess
      let app =
        "/Applications/\(InstallerProductIdentity.appName).app/Contents/MacOS/OmarchyAppleInstallerApp"
      let us: pid_t = 100
      let ours = Process(pid: us, path: app, name: "")
      func open(_ others: [Process]?) -> Bool? {
        SystemInstallerHelperProbe.anotherInstallerIsOpen(
          processes: others.map { [ours] + $0 }, own: us)
      }
      // Another user's copy of the very same bundle is another installer.
      XCTAssertEqual(open([Process(pid: 200, path: app, name: "")]), true)
      XCTAssertEqual(open([Process(pid: 300, path: "/usr/bin/true", name: "")]), false)
      // A live installer whose bundle was deleted or updated in place has no
      // readable path; its kernel name (16 characters) still gives it away.
      XCTAssertEqual(open([Process(pid: 400, path: nil, name: "OmarchyAppleInst")]), true)
      XCTAssertEqual(open([Process(pid: 500, path: nil, name: "node")]), false)
      // An unverified process list proves nothing.
      XCTAssertNil(open(nil))
    }

    func testLiveProcessesWithoutPathsThatAreNotInstallersDoNotBlock() {
      // As measured on a typical Mac: live node and codex processes whose
      // executables were replaced on disk have no readable path. Injected, so
      // the result doesn't depend on what else is open while tests run.
      typealias Process = PackageInstalledAppRetirement.RunningProcess
      let processes = [
        Process(pid: 100, path: "/usr/bin/true", name: ""),
        Process(pid: 200, path: nil, name: "node"),
        Process(pid: 300, path: nil, name: "codex"),
      ]
      XCTAssertEqual(
        SystemInstallerHelperProbe.anotherInstallerIsOpen(processes: processes, own: 100), false)
    }

    func testTheProcessListReadsHereAndIncludesThisProcess() throws {
      let processes = try XCTUnwrap(PackageInstalledAppRetirement.runningProcesses())
      XCTAssertTrue(processes.contains { $0.pid == getpid() })
    }

    func testAHelperWhoseWorkCannotBeSeenIsNotReplaced() async {
      // Fourth review: a failed inspection is not proof of idleness.
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: true, version: nil, replacement: nil, work: .unknown),
        blesser: blesser
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .busy)
      XCTAssertEqual(blesser.calls, [])
    }

    func testNothingIsReplacedIfTheHelperIsNoLongerClearAtTheLastCheck() async {
      // Third review: a hold must still be valid when the bless happens, after
      // however long the authorization took.
      let probe = FakeProbe(
        registered: true, version: "27", installsVersion: "28", replacement: true,
        laterReplacement: false)
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser).ensureCurrent(owner)
      XCTAssertEqual(outcome, .busy)
      XCTAssertEqual(blesser.calls, [.silent("owner"), .declined])
      XCTAssertEqual(probe.cancels, 1)
    }

    func testAHoldWhoseReplyWasLostIsReleased() async {
      // Fourth review: the helper may have granted the hold before its reply
      // was lost; releasing by token keeps it from refusing work meanwhile.
      let probe = FakeProbe(registered: true, version: nil, replacement: nil, work: .working)
      let outcome = await provisioner(probe).ensureCurrent(owner)
      XCTAssertEqual(outcome, .busy)
      XCTAssertEqual(probe.cancels, 1)
    }

    func testAnOlderHelperThatCannotBeAskedIsStillReplaced() async {
      let probe = FakeProbe(registered: true, version: nil, installsVersion: "28", replacement: nil)
      let outcome = await provisioner(
        probe, blesser: FakeBlesser(silent: .blessed, installing: probe)
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
    }

    func testSwitchedOffHelperIsTurnedBackOnWhenThePersonChoseTo() async {
      let probe = FakeProbe(registered: true, answering: false, installsVersion: "28")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser)
        .ensureCurrent(owner, reenablingSwitchedOff: true)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(blesser.calls, [.silent("owner")])
    }

    func testChoosingToTurnItBackOnStillChecksThePasswordFirst() async {
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(
        FakeProbe(registered: true, answering: false), blesser: blesser,
        validator: FakeValidator(accepts: false)
      ).ensureCurrent(owner, reenablingSwitchedOff: true)
      XCTAssertEqual(outcome, .credentialsRejected)
      XCTAssertEqual(blesser.calls, [])
    }

    func testInstalledHelperThatDoesNotAnswerFails() async {
      let blesser = FakeBlesser(silent: .blessed)
      let outcome = await provisioner(FakeProbe(registered: false), blesser: blesser)
        .ensureCurrent(owner)
      guard case .failed = outcome else {
        return XCTFail("expected failure, got \(outcome)")
      }
    }

    func testBuildWithoutABlesserReportsUnavailable() async {
      let outcome = await provisioner(
        FakeProbe(registered: false), blesser: UnavailableInstallerHelperBlesser()
      ).ensureCurrent(owner)
      XCTAssertEqual(outcome, .unavailable)
    }

    func testFailedSilentInstallationIsNotRetriedWithTheDialog() async {
      let blesser = FakeBlesser(silent: .failed("launchd"))
      let outcome = await provisioner(FakeProbe(registered: false), blesser: blesser)
        .ensureCurrent(owner)
      XCTAssertEqual(outcome, .failed("launchd"))
      XCTAssertEqual(blesser.calls, [.silent("owner")])
    }

    func testHelperReportingAnotherBuildIsReplaced() async {
      let probe = FakeProbe(registered: true, version: "27", installsVersion: "28")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser, bundled: "28").ensureCurrent(owner)
      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertEqual(blesser.calls, [.silent("owner")])
      let status = await provisioner(probe, bundled: "28").probeStatus()
      XCTAssertEqual(status, .current)
    }

    func testReplacementThatLeavesTheOldBuildAnsweringFails() async {
      let probe = FakeProbe(registered: true, version: nil, installsVersion: "27")
      let blesser = FakeBlesser(silent: .blessed, installing: probe)
      let outcome = await provisioner(probe, blesser: blesser, bundled: "28").ensureCurrent(owner)
      XCTAssertEqual(outcome, .failed("The helper was installed but an older build still answers."))
    }

    // MARK: Housekeeping

    func testHousekeepingRunsOnceAfterAnInstall() async {
      let probe = FakeProbe(registered: true, version: nil, installsVersion: "28")
      let housekeeping = FakeHousekeeping()
      let outcome = await provisioner(
        probe, blesser: FakeBlesser(silent: .blessed, installing: probe), housekeeping: housekeeping
      ).ensureCurrent(owner)

      XCTAssertEqual(outcome, .installedSilently)
      await housekeeping.waitForCall()
      XCTAssertEqual(housekeeping.calls, 1)
    }

    func testHousekeepingDoesNotRunWhenNothingWasInstalled() async throws {
      let housekeeping = FakeHousekeeping()
      let current = await provisioner(
        FakeProbe(registered: true, version: "28"), housekeeping: housekeeping
      ).ensureCurrent(owner)
      let failed = await provisioner(
        FakeProbe(registered: false), blesser: FakeBlesser(silent: .failed("x")),
        housekeeping: housekeeping
      ).ensureCurrent(owner)

      XCTAssertEqual(current, .alreadyCurrent)
      XCTAssertEqual(failed, .failed("x"))
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(housekeeping.calls, 0)
    }

    func testSlowHousekeepingNeverHoldsUpSetup() async {
      let probe = FakeProbe(registered: false, installsVersion: "28")
      let housekeeping = FakeHousekeeping(hangs: true)
      let started = Date()
      let outcome = await provisioner(
        probe, blesser: FakeBlesser(silent: .blessed, installing: probe), housekeeping: housekeeping
      ).ensureCurrent(owner)

      XCTAssertEqual(outcome, .installedSilently)
      XCTAssertLessThan(Date().timeIntervalSince(started), 1)
      housekeeping.release()
    }

    // MARK: Bundled version

    func testBundledVersionComesFromTheHelpersEmbeddedInfoPlist() throws {
      // A macOS tool that carries a linked Info.plist stands in for the helper.
      let donor = URL(fileURLWithPath: "/usr/bin/automator")
      guard
        let expected = (CFBundleCopyInfoDictionaryForURL(donor as CFURL) as? [String: Any])?[
          "CFBundleVersion"] as? String
      else {
        throw XCTSkip("no system tool with an embedded Info.plist")
      }
      let app = try makeAppBundle()
      defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
      try FileManager.default.copyItem(at: donor, to: helperURL(in: app))

      XCTAssertEqual(
        InstallerHelperProvisioner.bundledHelperVersion(in: try XCTUnwrap(Bundle(url: app))),
        expected)
    }

    func testBundledVersionIsNilWithoutAHelperOrItsVersion() throws {
      let app = try makeAppBundle()
      defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
      let bundle = try XCTUnwrap(Bundle(url: app))
      XCTAssertNil(InstallerHelperProvisioner.bundledHelperVersion(in: bundle))

      let script = helperURL(in: app)
      try Data("#!/bin/sh\n".utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
      XCTAssertNil(InstallerHelperProvisioner.bundledHelperVersion(in: bundle))
    }

    private func makeAppBundle() throws -> URL {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let app = root.appendingPathComponent("Probe.app", isDirectory: true)
      let services = app.appendingPathComponent(
        "Contents/Library/LaunchServices", isDirectory: true)
      try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "probe.app", "CFBundlePackageType": "APPL"],
        format: .xml, options: 0)
      try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
      return app
    }

    private func helperURL(in app: URL) -> URL {
      app.appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        .appendingPathComponent(InstallerProductIdentity.helperIdentifier, isDirectory: false)
    }

    // MARK: Shipping pieces

    func testSystemProbeChecksTheCanonicalSystemLaunchDaemonPath() {
      XCTAssertEqual(
        InstallerProductIdentity.systemLaunchDaemonPath,
        "/Library/LaunchDaemons/\(InstallerProductIdentity.helperIdentifier).plist"
      )
    }

    func testSystemProbeTreatsAnUnreachableHelperAsNotAnswering() async {
      let probe = SystemInstallerHelperProbe {
        try AuthenticatedEngineXPCSubmitter(
          machServiceName: "com.omarchy.apple-installer.test.absent",
          helperCodeSigningRequirement: #"identifier "com.omarchy.apple-installer.helper""#
        )
      }
      // Refused, not timed out: nothing is listening, so it is not "busy".
      let pinged = await probe.ping()
      let version = await probe.reportedVersion()
      XCTAssertEqual(pinged, .refused)
      XCTAssertNil(version)
    }

    func testSystemProbeTreatsAMissingConfigurationAsNotAnswering() async {
      struct NoConfiguration: Error {}
      let probe = SystemInstallerHelperProbe { throw NoConfiguration() }
      // Refused, not timed out: nothing is listening, so it is not "busy".
      let pinged = await probe.ping()
      let version = await probe.reportedVersion()
      XCTAssertEqual(pinged, .refused)
      XCTAssertNil(version)
    }

    // MARK: Fixtures

    private let owner = try! MachineOwnerAuthorization(
      username: "owner", password: Data("secret".utf8))

    private func provisioner(
      _ probe: FakeProbe,
      blesser: any InstallerHelperBlessing = FakeBlesser(),
      validator: FakeValidator = FakeValidator(accepts: true),
      administrator: Bool = true,
      bundled: String? = "28",
      housekeeping: any InstallerHelperHousekeeping = NoInstallerHelperHousekeeping()
    ) -> InstallerHelperProvisioner {
      InstallerHelperProvisioner(
        probe: probe,
        blesser: blesser,
        credentialValidator: validator,
        administrators: FakeAdministrators(isAdministrator: administrator),
        bundledHelperVersion: bundled,
        housekeeping: housekeeping
      )
    }
  }

  private final class FakeProbe: InstallerHelperProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var registered: Bool
    private var answering: Bool
    private let loaded: Bool
    private let slow: Bool
    private var replacement: [Bool?]
    private let work: InstallerHelperWorkObservation
    private var cancelled = 0
    private var version: String?
    private let installsVersion: String?
    private var pingCount = 0

    /// - Parameter installsVersion: what a successful bless leaves running;
    ///   nil leaves a helper that never answers.
    /// - Parameter loaded: whether launchd has the job loaded while it does
    ///   not answer; false models a helper switched off in Login Items.
    /// - Parameter slow: a loaded helper that does not answer in time, as when
    ///   busy verifying a payload; otherwise a silent helper refuses at once.
    init(
      registered: Bool, answering: Bool = true, loaded: Bool = false, slow: Bool = false,
      version: String? = nil, installsVersion: String? = nil, replacement: Bool? = nil,
      laterReplacement: Bool?? = nil, work: InstallerHelperWorkObservation = .idle
    ) {
      // The first answer is for the request; the next, if given, for the
      // check immediately before installing.
      self.replacement = laterReplacement.map { [replacement, $0] } ?? [replacement]
      self.work = work
      self.registered = registered
      self.loaded = loaded || slow
      self.slow = slow
      self.answering = answering && registered
      self.version = version
      self.installsVersion = installsVersion
    }

    var pings: Int { lock.withLock { pingCount } }

    var isRegistered: Bool { lock.withLock { registered } }

    func ping() async -> AuthenticatedEngineXPCSubmitter.PingResult {
      lock.withLock {
        pingCount += 1
        if answering { return .answered }
        return slow ? .noAnswer : .refused
      }
    }

    var cancels: Int { lock.withLock { cancelled } }

    func prepareForReplacement(token: String) async -> Bool? {
      lock.withLock { replacement.count > 1 ? replacement.removeFirst() : replacement[0] }
    }

    func cancelReplacement(token: String) async {
      lock.withLock { cancelled += 1 }
    }

    func observeWork() async -> InstallerHelperWorkObservation { work }

    func isLoaded() async -> Bool {
      lock.withLock { answering || loaded }
    }

    func reportedVersion() async -> String? {
      lock.withLock { answering ? version : nil }
    }

    func installBundledHelper() {
      lock.withLock {
        registered = true
        answering = installsVersion != nil
        version = installsVersion
      }
    }
  }

  private final class FakeBlesser: InstallerHelperBlessing, @unchecked Sendable {
    enum Call: Equatable {
      case silent(String)
      case dialog
      case declined
    }

    private let lock = NSLock()
    private let silent: InstallerHelperBlessResult
    private let dialog: InstallerHelperBlessResult
    private weak var installing: FakeProbe?
    private var recorded: [Call] = []

    init(
      silent: InstallerHelperBlessResult = .failed("unexpected"),
      dialog: InstallerHelperBlessResult = .failed("unexpected"),
      installing: FakeProbe? = nil
    ) {
      self.silent = silent
      self.dialog = dialog
      self.installing = installing
    }

    var calls: [Call] { lock.withLock { recorded } }

    /// Like the real blesser: once authorized, the check runs immediately
    /// before installing, and a no installs nothing.
    func blessSilently(
      with authorization: MachineOwnerAuthorization,
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      lock.withLock { recorded.append(.silent(authorization.username)) }
      return await finish(silent, confirm)
    }

    func blessWithDialog(
      confirm: @escaping @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      lock.withLock { recorded.append(.dialog) }
      return await finish(dialog, confirm)
    }

    private func finish(
      _ result: InstallerHelperBlessResult, _ confirm: @Sendable () async -> Bool
    ) async -> InstallerHelperBlessResult {
      guard result == .blessed else { return result }
      guard await confirm() else {
        lock.withLock { recorded.append(.declined) }
        return .declined
      }
      installing?.installBundledHelper()
      return .blessed
    }
  }

  private final class FakeHousekeeping: InstallerHelperHousekeeping, @unchecked Sendable {
    private let lock = NSLock()
    private let hangs: Bool
    private var count = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(hangs: Bool = false) {
      self.hangs = hangs
    }

    var calls: Int { lock.withLock { count } }

    func afterInstall() async {
      let waiting = lock.withLock {
        count += 1
        let waiting = waiters
        waiters = []
        return waiting
      }
      for waiter in waiting {
        waiter.resume()
      }
      while hangs && !lock.withLock({ released }) {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }

    func release() {
      lock.withLock { released = true }
    }

    func waitForCall() async {
      await withCheckedContinuation { continuation in
        let done = lock.withLock {
          if count > 0 { return true }
          waiters.append(continuation)
          return false
        }
        if done { continuation.resume() }
      }
    }
  }

  private struct FakeAdministrators: HelperAdministratorChecking {
    let isAdministrator: Bool
    func isAdministrator(_ username: String) -> Bool { isAdministrator }
  }

  private struct FakeValidator: MachineOwnerCredentialValidating {
    let accepts: Bool

    func validate(_ authorization: MachineOwnerAuthorization) throws {
      guard accepts else { throw MachineOwnerCredentialValidationError.rejected }
    }
  }
#endif
