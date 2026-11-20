#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class InstallationChannelRecordStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aurora-channel-records-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: directory)
    }

    func testAnInstallationIsFoundByTheSpaceItWasInstalledInto() throws {
      let store = InstallationChannelRecordStore(directory: directory)
      try store.record(.testing, storeIdentifier: "disk0", offsetBytes: 100_000, lengthBytes: 50_000)

      // Recognized later from the disk: its startup container onwards.
      let installed = NativeKnownInstallation(
        sourceIdentifier: "disk0s5", offsetBytes: 100_000, lengthBytes: 50_000)
      let inside = NativeKnownInstallation(
        sourceIdentifier: "disk0s5", offsetBytes: 120_000, lengthBytes: 10_000)

      XCTAssertEqual(try store.channel(for: installed, storeIdentifier: "disk0"), .testing)
      XCTAssertEqual(try store.channel(for: inside, storeIdentifier: "disk0"), .testing)
    }

    func testNothingIsRecordedForOtherSpacesOrDisks() throws {
      let store = InstallationChannelRecordStore(directory: directory)
      let installation = NativeKnownInstallation(
        sourceIdentifier: "disk0s5", offsetBytes: 100_000, lengthBytes: 50_000)
      XCTAssertNil(try store.channel(for: installation, storeIdentifier: "disk0"))

      try store.record(.edge, storeIdentifier: "disk0", offsetBytes: 200_000, lengthBytes: 50_000)

      XCTAssertNil(try store.channel(for: installation, storeIdentifier: "disk0"))
      let elsewhere = NativeKnownInstallation(
        sourceIdentifier: "disk1s5", offsetBytes: 200_000, lengthBytes: 50_000)
      XCTAssertNil(try store.channel(for: elsewhere, storeIdentifier: "disk1"))
    }

    func testInstallingIntoTheSameSpaceAgainReplacesItsChannel() throws {
      let store = InstallationChannelRecordStore(directory: directory)
      try store.record(.edge, storeIdentifier: "disk0", offsetBytes: 100_000, lengthBytes: 50_000)
      try store.record(.rc, storeIdentifier: "disk0", offsetBytes: 300_000, lengthBytes: 50_000)
      // A Reset of the first installation, from Nightly.
      try store.record(.testing, storeIdentifier: "disk0", offsetBytes: 110_000, lengthBytes: 40_000)

      let first = NativeKnownInstallation(
        sourceIdentifier: "disk0s5", offsetBytes: 100_000, lengthBytes: 50_000)
      let second = NativeKnownInstallation(
        sourceIdentifier: "disk0s9", offsetBytes: 300_000, lengthBytes: 50_000)
      XCTAssertEqual(try store.channel(for: first, storeIdentifier: "disk0"), .testing)
      XCTAssertEqual(try store.channel(for: second, storeIdentifier: "disk0"), .rc)
    }

    func testAnUnreadableRecordIsNotTrusted() throws {
      let file = directory.appendingPathComponent(InstallationChannelRecordStore.fileName)
      try Data("not json".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      let store = InstallationChannelRecordStore(directory: directory)
      let installation = NativeKnownInstallation(
        sourceIdentifier: "disk0s5", offsetBytes: 100_000, lengthBytes: 50_000)

      XCTAssertThrowsError(try store.channel(for: installation, storeIdentifier: "disk0"))
    }
  }
#endif
