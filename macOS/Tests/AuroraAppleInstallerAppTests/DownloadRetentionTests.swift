#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import XCTest
  @testable import AuroraAppleInstallerApp

  final class DownloadRetentionTests: XCTestCase {
    private func makeRelease(_ staging: URL, _ name: String) throws -> URL {
      let release = staging.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
      try Data(count: 64).write(to: release.appendingPathComponent("payload.zip"))
      return release
    }

    func testPreparingAReleaseKeepsOnlyThatReleasesDownload() throws {
      let fm = FileManager.default
      let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: staging) }
      let old = try makeRelease(staging, "image-build-1")
      let current = try makeRelease(staging, "image-build-2")

      LiveInstallerEnvironment.discardStaleDownloads(in: staging, keeping: current)

      XCTAssertFalse(fm.fileExists(atPath: old.path))
      XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("payload.zip").path))
    }

    func testAFinishedInstallationRemovesEverySystemsDownloads() throws {
      let fm = FileManager.default
      let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: base) }
      let fedora = base.appendingPathComponent("fedora-kde")
      let arch = base.appendingPathComponent("arch-gnome")
      let fedoraBuild = try makeRelease(
        fedora.appendingPathComponent("staging"), "image-build-1")
      let archBuild = try makeRelease(arch.appendingPathComponent("staging"), "image-build-2")
      let state = arch.appendingPathComponent("state")
      try fm.createDirectory(at: state, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: state.appendingPathComponent("accepted-catalog.json"))

      LiveInstallerEnvironment.discardDownloads(productBase: base)

      XCTAssertFalse(fm.fileExists(atPath: fedoraBuild.path))
      XCTAssertFalse(fm.fileExists(atPath: archBuild.path))
      XCTAssertTrue(fm.fileExists(atPath: arch.appendingPathComponent("staging").path))
      XCTAssertTrue(
        fm.fileExists(atPath: state.appendingPathComponent("accepted-catalog.json").path))
    }

    func testOnlyAnInstallationFinishedOnThisMacDiscardsDownloads() {
      XCTAssertTrue(LiveInstallerEnvironment.finishedOnMac(.enterRecovery))
      XCTAssertTrue(LiveInstallerEnvironment.finishedOnMac(.attachInstallationMedia))
      XCTAssertTrue(LiveInstallerEnvironment.finishedOnMac(.verifyInstalledSystem))
      XCTAssertFalse(LiveInstallerEnvironment.finishedOnMac(.continueInstallation))
      XCTAssertFalse(LiveInstallerEnvironment.finishedOnMac(.manualRecovery))
    }
  }
#endif
