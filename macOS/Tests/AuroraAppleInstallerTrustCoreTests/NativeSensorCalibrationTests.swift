#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeSensorCalibrationTests: XCTestCase, @unchecked Sendable {
    static func der(_ tag: UInt8, _ value: Data) -> Data {
      value.count < 0x80
        ? Data([tag, UInt8(value.count)]) + value
        : Data([tag, 0x81, UInt8(value.count)]) + value
    }

    static func text(_ value: String) -> Data { der(0x16, Data(value.utf8)) }

    static let calibrationPayload = der(
      0x30, text("IM4P") + text("FSC2") + text("synthetic") + der(4, Data("CALB".utf8)))
    static let rootPayload = der(
      0x30, text("IM4P") + text("MSRk") + text("1.0") + der(4, Data([1])))
    static let seal = der(0x30, text("IM4M") + der(2, Data([0])))
    static let trust = Data("synthetic trust bundle".utf8)
    static let trustName = "trustobject-" + SHA256Digest(hashing: trust).hexadecimal.uppercased()
    static let factoryNames = [
      "MSRk-synthetic", "seal-synthetic", "trustobject-current", trustName,
    ]

    /// The standalone FSC2 calibration, as the iBoot System Container stores it.
    static func calibration() -> Data {
      der(0x30, text("IMG4") + calibrationPayload + der(0xa0, der(0x30, text("IM4M"))))
    }

    /// The combined root-key record the enclave loads.
    static func rootKey() -> Data { sealed(rootPayload) }

    /// The bare MSRk record as the factory cache stores it, with its own manifest.
    static func factoryRoot() -> Data {
      let manifest = der(0x30, text("IM4M") + der(2, Data([1])))
      return der(0x30, text("IMG4") + rootPayload + der(0xa0, manifest))
    }

    /// An IM4P under the sealing manifest with the trust bundle as secb.
    static func sealed(_ payload: Data) -> Data {
      let image = der(0x30, text("IMG4") + payload + der(0xa0, seal))
      return der(
        0x30,
        text("comb") + der(0x30, text("fdrd") + der(4, image))
          + der(0x30, text("secb") + der(4, trust)))
    }

    static func snapshot(type: String = "Apple_APFS_ISC") -> RemovalSnapshot {
      let part = RemovalPartition(
        identifier: "disk0s1", uuid: "8C2F7AF7-3612-46E3-BEEF-E4B21DDB4954",
        type: type, offset: 20480, size: UInt64(calibration().count), name: "")
      return RemovalSnapshot(
        disk: "disk0", devicePath: "synthetic", diskSize: 1 << 30,
        macOSStoreUUID: UUID().uuidString, macOSContainerUUID: UUID().uuidString,
        partitions: [part], containers: [])
    }

    static func collector(
      _ snapshot: RemovalSnapshot, present: Bool = true,
      fault: String = "", factory: [String] = factoryNames
    ) -> NativeSensorInputCollector {
      let part = snapshot.partitions[0]
      return NativeSensorInputCollector(
        present: { present }, snapshot: { snapshot },
        disk: { name in
          if name == NativeSensorInputCollector.hardwareVolume.path {
            return [
              "Internal": true, "MountPoint": name,
              "APFSPhysicalStores": [
                ["APFSPhysicalStore": fault == "factory-store" ? "disk1s1" : part.identifier]
              ],
            ]
          }
          return [
            "DeviceIdentifier": part.identifier, "ParentWholeDisk": snapshot.disk,
            "Content": part.type, "DiskUUID": fault == "uuid" ? UUID().uuidString : part.uuid,
            "Size": NSNumber(value: part.size),
          ]
        },
        read: { _, _ in
          if fault == "forbid-read" { XCTFail("Read an unadmitted device") }
          return fault == "short" ? Data() : calibration()
        }, factoryNames: { factory },
        factoryRead: { name in
          if name.hasPrefix("MSRk-") { return fault == "bad-root" ? calibration() : factoryRoot() }
          if name.hasPrefix("seal-") { return seal }
          if name == "trustobject-current" { return fault == "stale-trust" ? Data([1]) : trust }
          if name.hasPrefix("trustobject-") { return trust }
          return calibration()
        })
    }

    func testPresentSensorResealsItsRecordsTheWayTheEnclaveLoadsThem() throws {
      let inputs = try XCTUnwrap(Self.collector(Self.snapshot()).collect(storeIdentifier: "disk0"))
      XCTAssertEqual(inputs.calibration, Self.sealed(Self.calibrationPayload))
      XCTAssertEqual(inputs.rootKey, Self.sealed(Self.rootPayload))
      XCTAssertEqual(try SignedSensorInputs.rootKey(inputs.rootKey), inputs.rootKey)
      let calibration = inputs.calibration
      XCTAssertEqual(try SignedSensorInputs.sealedCalibration(calibration), calibration)
    }

    func testTheTrustBundleFollowsTrustobjectCurrentAndSealingRecordsAreRequired() throws {
      let stale = "trustobject-" + String(repeating: "0", count: 64)
      XCTAssertNotNil(
        try Self.collector(Self.snapshot(), factory: Self.factoryNames + [stale]).collect(
          storeIdentifier: "disk0"))
      let current = Self.factoryNames.filter { $0 != "trustobject-current" }
      XCTAssertNotNil(
        try Self.collector(Self.snapshot(), factory: current).collect(storeIdentifier: "disk0"))
      for names in [
        Self.factoryNames.filter { !$0.hasPrefix("seal-") },
        Self.factoryNames + ["seal-other"],
        Self.factoryNames.filter { $0 != Self.trustName },
        current + [stale],
      ] {
        XCTAssertThrowsError(
          try Self.collector(Self.snapshot(), factory: names).collect(storeIdentifier: "disk0"))
      }
      XCTAssertThrowsError(
        try Self.collector(Self.snapshot(), fault: "stale-trust").collect(storeIdentifier: "disk0"))
    }

    func testAbsentSensorDoesNotReadAnyDevice() throws {
      let collector = NativeSensorInputCollector(
        present: { false },
        snapshot: {
          XCTFail("Read layout for absent sensor")
          throw NativePeripheralInputError.localInput
        },
        disk: { _ in
          XCTFail("Read disk")
          return [:]
        },
        read: { _, _ in
          XCTFail("Read device")
          return Data()
        },
        factoryNames: {
          XCTFail("Read factory records")
          return []
        }, factoryRead: { _ in Data() })
      XCTAssertNil(try collector.collect(storeIdentifier: "disk0"))
    }

    func testWrongStoreWrongPartitionChangedUUIDAndShortReadsAreRejected() throws {
      XCTAssertThrowsError(
        try Self.collector(Self.snapshot(), fault: "forbid-read").collect(storeIdentifier: "disk1"))
      XCTAssertThrowsError(
        try Self.collector(Self.snapshot(type: "Apple_APFS"), fault: "forbid-read").collect(
          storeIdentifier: "disk0"))
      for fault in ["uuid", "short", "factory-store", "bad-root"] {
        XCTAssertThrowsError(
          try Self.collector(Self.snapshot(), fault: fault).collect(storeIdentifier: "disk0"))
      }
    }

    func testFactoryPairIsCopiedWholeAndAmbiguousOrMismatchedRecordsFail() throws {
      let pair = try XCTUnwrap(
        Self.collector(
          Self.snapshot(), fault: "forbid-read",
          factory: Self.factoryNames + ["FSC2-synthetic"]
        ).collect(storeIdentifier: "disk0"))
      XCTAssertEqual(pair.calibration, Self.sealed(Self.calibrationPayload))
      XCTAssertEqual(pair.rootKey, Self.sealed(Self.rootPayload))
      for names in [[], ["MSRk-one", "MSRk-two"], ["FSC2-one", "MSRk-two"]] {
        XCTAssertThrowsError(
          try Self.collector(
            Self.snapshot(), fault: "forbid-read",
            factory: names
          ).collect(storeIdentifier: "disk0"))
      }
    }

    func testSensorDetectionFailureCannotBecomeAbsentHardware() throws {
      let collector = NativeSensorInputCollector(
        present: { throw NativePeripheralInputError.localInput },
        snapshot: { throw NativePeripheralInputError.localInput }, disk: { _ in [:] },
        read: { _, _ in Data() }, factoryNames: { [] }, factoryRead: { _ in Data() })
      XCTAssertThrowsError(try collector.collect(storeIdentifier: "disk0"))
    }
  }

  final class NativePeripheralCleanupTests: XCTestCase, @unchecked Sendable {
    private func make() throws -> PreparedNativePeripheralInputs {
      let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      return try PreparedNativePeripheralInputs(
        directory: path, recipeSHA256: String(repeating: "a", count: 64), owner: geteuid())
    }

    func testSuccessFailureAndCancellationRemovePrivateSnapshot() async throws {
      for fault in ["success", "failure", "cancel"] {
        let prepared = try make()
        defer { try? prepared.remove() }
        do {
          let result = try await PreparedNativePeripheralInputs.withCleanup(prepared) {
            if fault == "failure" { throw NativePeripheralInputError.invalidPolicy }
            if fault == "cancel" { throw CancellationError() }
            return 42
          }
          XCTAssertEqual(fault, "success")
          XCTAssertEqual(result, 42)
        } catch {
          if fault == "failure" {
            XCTAssertEqual(error as? NativePeripheralInputError, .invalidPolicy)
          } else {
            XCTAssertTrue(error is CancellationError)
          }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
        try prepared.remove()
      }
    }

    func testReplacedDirectoryIsPreservedAndCleanupErrorRetainsOriginalFailure() async throws {
      let prepared = try make()
      let moved = prepared.directory.appendingPathExtension("retained")
      try FileManager.default.moveItem(at: prepared.directory, to: moved)
      defer {
        try? FileManager.default.removeItem(at: moved)
        try? FileManager.default.removeItem(at: prepared.directory)
      }
      try FileManager.default.createDirectory(
        at: prepared.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      do {
        let _: Int = try await PreparedNativePeripheralInputs.withCleanup(prepared) {
          throw NativePeripheralInputError.invalidPolicy
        }
        XCTFail("Ignored failed cleanup")
      } catch let error as NativePeripheralCleanupError {
        XCTAssertEqual(error.operation as? NativePeripheralInputError, .invalidPolicy)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.directory.path))
    }
  }
#endif
