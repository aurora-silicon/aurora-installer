#if os(macOS)
  import AuroraFirmware
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// The N1 step runs after the stub is on disk: a missing, changed or
  /// malformed input installs without Wi-Fi and Bluetooth, with one log line.
  /// Synthetic bytes only, the vector of `CentauriFirmwareTests`.
  final class NativeCentauriFirmwareTests: XCTestCase {
    static let image =
      Data(count: 0x20) + Data("rkosftab".utf8) + Data([1, 0, 0, 0]) + Data(count: 4)
      + Data("synthetic N1 image".utf8)
    static let ticket =
      Data([0x30, 0x09, 0x16, 0x04]) + Data("IM4M".utf8) + Data([0x02, 0x01, 0x00])
    static let imagePath = "Firmware/synthetic/ftab.bin"
    static let ticketPath = "centauri/centauri.j714sap.im4m"

    static func source(_ deviceClass: String = "j714sap", images: [String] = [imagePath]) throws
      -> NativeFirmwareSourcePlan
    {
      var components: [String: Any] = [
        "KernelCache": ["Info": ["Path": "kernelcache.release.synthetic"]]
      ]
      for (index, path) in images.enumerated() {
        components["Wireless1,Synthetic\(index)"] = ["Info": ["Path": path]]
      }
      let identity: [String: Any] = [
        "ApChipID": "0x6050",
        "Info": [
          "DeviceClass": deviceClass, "RestoreBehavior": "Erase", "Variant": "macOS Customer",
        ],
        "Manifest": components,
      ]
      return try NativeFirmwareSourcePlan(
        manifest: PropertyListSerialization.data(
          fromPropertyList: ["BuildIdentities": [identity]], format: .xml, options: 0))
    }

    /// The result and the log's error lines for `files` as the stub's restore
    /// directory; a path whose value is nil makes `read` throw.
    func prepare(_ source: NativeFirmwareSourcePlan, _ files: [String: Data?]) async throws
      -> (NativeCentauriFirmware.Prepared?, [String])
    {
      let buffer = InstallerLogBuffer(capacity: 100)
      let prepared = try await InstallerLog.logging(into: buffer) {
        try NativeCentauriFirmware.prepare(source) { path, maximum in
          guard let entry = files[path] else { return nil }
          guard let data = entry, data.count <= maximum else {
            throw NativeFirmwareInputFailure.invalidSource
          }
          return data
        }
      }
      return (prepared, buffer.snapshot().filter { $0.level == .error }.map(\.message))
    }

    func testTheImageAndTicketBecomeTheDriverFileAndItsFallbackInputs() async throws {
      let (prepared, errors) = try await prepare(
        Self.source(), [Self.imagePath: Self.image, Self.ticketPath: Self.ticket])
      let n1 = try XCTUnwrap(prepared)
      let firmware = try XCTUnwrap(n1.package["apple/centauri/j714s-ftab.bin"])
      XCTAssertEqual(n1.package.count, 1)
      XCTAssertEqual(
        NativeStubFileStore.hash(firmware),
        "82f9fbcd0c2f700dde10f373f7b1d4aacae2bb0e20357dd2e78e1b8745f660af")
      XCTAssertEqual(n1.fallback["centauri/j714s/ftab.bin"], Self.image)
      XCTAssertEqual(n1.fallback["centauri/j714s/centauri.j714sap.im4m"], Self.ticket)
      XCTAssertEqual(n1.fallback.count, 2)
      XCTAssertEqual(errors, [])
    }

    /// The Mac installs without the file and the log has one line naming why.
    func expectWithoutFirmware(_ files: [String: Data?], _ reason: String) async throws {
      let (prepared, errors) = try await prepare(Self.source(), files)
      XCTAssertNil(prepared, reason)
      XCTAssertEqual(errors, [NativeCentauriFirmware.line(reason)])
    }

    func testABadInputInstallsWithoutWiFiAndSaysWhyOnce() async throws {
      XCTAssertEqual(
        NativeCentauriFirmware.line("why"),
        "N1 Wi-Fi/Bluetooth firmware could not be prepared: why; installing without Wi-Fi and "
          + "Bluetooth")
      try await expectWithoutFirmware(
        [Self.imagePath: Self.image], "the startup firmware has no centauri/centauri.j714sap.im4m")
      try await expectWithoutFirmware(
        [Self.imagePath: Self.image, Self.ticketPath: nil],
        "centauri/centauri.j714sap.im4m can't be read or isn't the file the installer copied")
      try await expectWithoutFirmware(
        [Self.imagePath: Self.image, Self.ticketPath: Data("damaged".utf8)],
        "the N1 ticket is not a manifest")
      try await expectWithoutFirmware(
        [Self.imagePath: Data(count: 0x40), Self.ticketPath: Self.ticket],
        "the N1 image is not an FTAB")
    }

    func testTwoImagesInstallWithoutWiFiAndAMacWithoutAnN1LogsNothing() async throws {
      let files: [String: Data?] = [Self.imagePath: Self.image, Self.ticketPath: Self.ticket]
      let (two, twoErrors) = try await prepare(
        Self.source(images: [Self.imagePath, "Firmware/other/ftab.bin"]), files)
      XCTAssertNil(two)
      XCTAssertEqual(
        twoErrors, [NativeCentauriFirmware.line("the build identity names 2 different N1 images")])
      let (none, noneErrors) = try await prepare(Self.source("j616sap", images: []), files)
      XCTAssertNil(none)
      XCTAssertEqual(noneErrors, [])
    }

    func testCancellationStillStopsTheStep() async throws {
      let source = try Self.source()
      XCTAssertThrowsError(
        try NativeCentauriFirmware.prepare(source) { _, _ in throw CancellationError() }
      ) { XCTAssertTrue($0 is CancellationError) }
    }
  }
#endif
