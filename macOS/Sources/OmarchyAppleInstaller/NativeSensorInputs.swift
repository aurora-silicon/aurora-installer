#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import IOKit

  /// Device-local inputs stay in memory until the private per-install snapshot
  /// is written. Never use the model-wide IPSW cache for factory calibration.
  struct NativeSensorInputs: Sendable {
    let calibration: Data
    let rootKey: Data
  }

  struct NativeSensorInputCollector: Sendable {
    let present: @Sendable () throws -> Bool
    let snapshot: @Sendable () throws -> RemovalSnapshot
    let disk: @Sendable (String) throws -> [String: Any]
    let read: @Sendable (String, UInt64) throws -> Data
    let factoryNames: @Sendable () throws -> [String]
    let factoryRead: @Sendable (String) throws -> Data

    static var live: Self {
      Self(
        present: builtInSensor,
        snapshot: { try MacRemovalDiskOperator().snapshot(maximumPartitions: 4096) },
        disk: { try NativeHandoffEnvironment.live.disk($0) }, read: readContainer,
        factoryNames: {
          try FileManager.default.contentsOfDirectory(atPath: factoryDirectory.path)
        },
        factoryRead: {
          try NativeHandoffFileTree(factoryDirectory, protected: true).read($0, maximum: 16 << 20)
        })
    }

    static let hardwareVolume = URL(fileURLWithPath: "/System/Volumes/Hardware")
    static let factoryDirectory = hardwareVolume.appendingPathComponent(
      "FactoryData/System/Library/Caches/com.apple.factorydata")

    func collect(storeIdentifier: String) throws -> NativeSensorInputs? {
      try Task.checkCancellation()
      guard try present() else { return nil }
      let before = try snapshot()
      guard before.disk == storeIdentifier,
        let source = before.partitions.min(by: { $0.offset < $1.offset }),
        source.type == "Apple_APFS_ISC", source.identifier == before.disk + "s1",
        source.size > 0, source.size <= 1 << 30
      else { throw NativePeripheralInputError.localInput }
      func verify() throws {
        let info = try disk(source.identifier)
        guard info["DeviceIdentifier"] as? String == source.identifier,
          info["ParentWholeDisk"] as? String == before.disk,
          info["Content"] as? String == source.type,
          (info["DiskUUID"] as? String)?.uppercased() == source.uuid.uppercased(),
          (info["Size"] as? NSNumber)?.uint64Value == source.size
        else { throw NativePeripheralInputError.identityChanged }
      }
      func verifyFactory() throws {
        try Self.requireFactoryStore(
          try disk(Self.hardwareVolume.path), partition: source.identifier)
      }
      try verify()
      try verifyFactory()
      let names = try factoryNames()
      guard names.count <= 4096, Set(names).count == names.count else {
        throw NativePeripheralInputError.unsafeSnapshot
      }
      let roots = names.filter { $0.hasPrefix("MSRk-") }
      guard roots.count == 1, let root = roots.first,
        NativeHandoffEvidence.safeRelative(root), !root.contains("/"), root.utf8.count <= 255,
        root.count > 5
      else { throw NativePeripheralInputError.sensorRootKeyMissing }
      let rootKey = try SignedSensorInputs.rootKey(factoryRead(root))
      let calibrations = names.filter { $0.hasPrefix("FSC2-") || $0.hasPrefix("FSCl-") }
      let calibration: Data
      if calibrations.isEmpty {
        let bytes = try read(source.identifier, source.size)
        guard bytes.count == source.size else { throw NativePeripheralInputError.localInput }
        calibration = try SignedSensorInputs.calibration(in: bytes)
      } else {
        guard calibrations.count == 1, let name = calibrations.first,
          String(name.dropFirst(5)) == String(root.dropFirst(5)),
          NativeHandoffEvidence.safeRelative(name), !name.contains("/"), name.utf8.count <= 255
        else { throw NativePeripheralInputError.sensorCalibrationMissing }
        let bytes = try factoryRead(name)
        calibration = try SignedSensorInputs.calibration(in: bytes)
        guard calibration == bytes else {
          throw NativePeripheralInputError.sensorCalibrationMissing
        }
      }
      try Task.checkCancellation()
      try verify()
      try verifyFactory()
      guard try snapshot() == before else { throw NativePeripheralInputError.identityChanged }
      return NativeSensorInputs(calibration: calibration, rootKey: rootKey)
    }

    static func requireFactoryStore(_ info: [String: Any], partition: String) throws {
      guard info["Internal"] as? Bool == true,
        info["MountPoint"] as? String == hardwareVolume.path,
        let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        stores[0]["APFSPhysicalStore"] as? String == partition
      else { throw NativePeripheralInputError.identityChanged }
    }

    static func builtInSensor() throws -> Bool {
      let node = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io")
      guard node != 0 else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(node) }
      var iterator: io_iterator_t = 0
      guard IORegistryEntryGetChildIterator(node, kIODeviceTreePlane, &iterator) == KERN_SUCCESS
      else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(iterator) }
      var count = 0
      var found = false
      while true {
        try Task.checkCancellation()
        let child = IOIteratorNext(iterator)
        if child == 0 { break }
        defer { IOObjectRelease(child) }
        count += 1
        guard count <= 4096 else { throw NativePeripheralInputError.localInput }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(child, kIODeviceTreePlane, &name) == KERN_SUCCESS
        else { throw NativePeripheralInputError.localInput }
        let value = String(
          decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !value.isEmpty else { throw NativePeripheralInputError.localInput }
        if value.split(separator: "@").first == "spi2" { found = true }
      }
      guard count > 0 else { throw NativePeripheralInputError.localInput }
      return found
    }

    static func readContainer(_ identifier: String, _ expected: UInt64) throws -> Data {
      guard identifier.range(of: #"\Adisk[0-9]+s1\z"#, options: .regularExpression) != nil,
        expected > 0, expected <= 1 << 30
      else { throw NativePeripheralInputError.localInput }
      let fd = open("/dev/r" + identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw NativePeripheralInputError.localInput }
      defer { close(fd) }
      var info = stat()
      var blockSize: UInt32 = 0
      var blocks: UInt64 = 0
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
        ioctl(fd, UInt(0x4004_6418), &blockSize) == 0,
        ioctl(fd, UInt(0x4008_6419), &blocks) == 0, blockSize > 0,
        !blocks.multipliedReportingOverflow(by: UInt64(blockSize)).overflow,
        blocks * UInt64(blockSize) == expected
      else { throw NativePeripheralInputError.localInput }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var result = Data()
      result.reserveCapacity(Int(expected))
      while result.count < expected {
        try Task.checkCancellation()
        let chunk = try file.read(upToCount: min(4 << 20, Int(expected) - result.count)) ?? Data()
        guard !chunk.isEmpty else { throw NativePeripheralInputError.localInput }
        result.append(chunk)
      }
      return result
    }
  }
#endif
