#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import NativeFirmwareFixtureSupport
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeFactoryCalibrationInputTests: XCTestCase {
    private let calibrationName = "BWC2-fixture"

    private func fixture() throws -> (URL, URL, Data) {
      struct Local: Decodable { let local: [String: Data] }
      let data = try XCTUnwrap(
        JSONDecoder().decode(Local.self, from: NeoFirmwareFixture.data()).local["factory"])
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let directory = root.appendingPathComponent(NativeSensorInputCollector.factoryRelativePath)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let file = directory.appendingPathComponent(calibrationName)
      try data.write(to: file)
      XCTAssertEqual(chmod(file.path, 0o666), 0)
      return (root, file, data)
    }

    func testWritableFactoryCalibrationIsTypedDataAndGenericReadsStayStrict() throws {
      let (root, file, expected) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let tree = try NativeHandoffFileTree(root, protected: true, owner: getuid())
      let bytes = try NativeFactoryCalibrationInput.read(
        tree, name: calibrationName, owner: getuid())
      XCTAssertEqual(bytes, expected)
      XCTAssertFalse(try NeoFirmwareConversions.factoryFields(bytes).isEmpty)
      XCTAssertThrowsError(
        try tree.read(
          NativeSensorInputCollector.factoryRelativePath + "/" + calibrationName, maximum: 32 << 20)
      )
      try Data("invalid calibration".utf8).write(to: file)
      XCTAssertEqual(chmod(file.path, 0o666), 0)
      let invalid = try NativeFactoryCalibrationInput.read(
        tree, name: calibrationName, owner: getuid())
      XCTAssertThrowsError(try NeoFirmwareConversions.factoryFields(invalid))
    }

    func testFactoryReaderRejectsUnsafeSourcesAndConcurrentChanges() throws {
      for fault in ["owner", "link", "symlink", "parent", "size", "mode", "changed"] {
        let (root, file, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try NativeHandoffFileTree(root, protected: true, owner: getuid())
        let other = file.appendingPathExtension("other")
        switch fault {
        case "link": XCTAssertEqual(link(file.path, other.path), 0)
        case "symlink":
          try FileManager.default.moveItem(at: file, to: other)
          try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        case "parent": XCTAssertEqual(chmod(file.deletingLastPathComponent().path, 0o777), 0)
        case "size":
          let fd = open(file.path, O_WRONLY)
          XCTAssertGreaterThanOrEqual(fd, 0)
          XCTAssertEqual(ftruncate(fd, (32 << 20) + 1), 0)
          close(fd)
        case "mode": XCTAssertEqual(chmod(file.path, 0o676), 0)
        default: break
        }
        XCTAssertThrowsError(
          try NativeFactoryCalibrationInput.read(
            tree, name: calibrationName, owner: fault == "owner" ? getuid() + 1 : getuid(),
            afterRead: {
              if fault == "changed" { XCTAssertEqual(chmod(file.path, 0o600), 0) }
            }), fault)
      }
    }

    func testOptInLiveNeoCalibrationInputs() throws {
      guard ProcessInfo.processInfo.environment["AURORA_LIVE_FIRMWARE_PROBE"] == "1" else {
        throw XCTSkip("Opt-in live Neo calibration inspection")
      }
      let store = try MacRemovalDiskOperator().snapshot(maximumPartitions: 4096).disk
      let inputs = try NativeNeoLocalInputs.live(storeIdentifier: store)
      XCTAssertFalse(try NeoFirmwareConversions.factoryFields(inputs.factory).isEmpty)
      XCTAssertFalse(try NeoFirmwareConversions.alsCalibration(inputs.lsci).isEmpty)
      XCTAssertEqual(inputs.address.count, 6)
      print("Live Neo calibration inputs passed")
    }
  }
#endif
