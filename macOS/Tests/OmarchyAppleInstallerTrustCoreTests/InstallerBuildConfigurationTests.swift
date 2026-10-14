#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerBuildConfigurationTests: XCTestCase {
    func testCompiledIdentityMatchesTheBuildConfiguration() throws {
      let configuration = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Packaging/identity.conf")
      let source = try String(contentsOf: configuration, encoding: .utf8)
      var expected: [String: String] = [:]
      for line in source.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1)
        XCTAssertEqual(parts.count, 2, "unexpected line: \(line)")
        expected[String(parts[0])] = String(parts[1].dropFirst().dropLast())
      }

      XCTAssertEqual(InstallerBuildConfiguration.entries, expected)
    }

    func testProductIdentityDerivesFromTheBuildConfiguration() {
      let entries = InstallerBuildConfiguration.entries
      let app = entries["INSTALLER_APP_IDENTIFIER"]
      let helper = entries["INSTALLER_HELPER_IDENTIFIER"]

      XCTAssertEqual(InstallerProductIdentity.appName, entries["INSTALLER_APP_NAME"])
      XCTAssertEqual(InstallerProductIdentity.appIdentifier, app)
      XCTAssertEqual(InstallerProductIdentity.helperMachServiceName, helper)
      XCTAssertEqual(
        InstallerProductIdentity.systemLaunchDaemonPath,
        "/Library/LaunchDaemons/" + (helper ?? "") + ".plist"
      )
      XCTAssertEqual(
        InstallerProductIdentity.helperWorkingDirectory,
        "/var/db/" + (app ?? "")
      )
    }
  }
#endif
