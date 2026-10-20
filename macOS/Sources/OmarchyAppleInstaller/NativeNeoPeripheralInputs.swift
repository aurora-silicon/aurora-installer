#if os(macOS)
  import AuroraFirmware
  import CryptoKit
  import Darwin
  import Foundation
  import IOKit
  import RecoveryAccountCore

  struct NativeNeoLocalInputs: Sendable {
    let factory: Data
    let lsci: Data
    let address: Data
    let sensor: NativeSensorInputs?

    init(factory: Data, lsci: Data, address: Data, sensor: NativeSensorInputs? = nil) {
      self.factory = factory
      self.lsci = lsci
      self.address = address
      self.sensor = sensor
    }

    static func live(storeIdentifier: String) throws -> Self {
      func verifyFactoryStore() throws {
        try NativeSensorInputCollector.requireFactoryStore(
          NativeHandoffEnvironment.live.disk(NativeSensorInputCollector.hardwareVolume.path),
          partition: storeIdentifier + "s1")
      }
      try verifyFactoryStore()
      let directory = NativeSensorInputCollector.factoryDirectory
      let tree = try NativeHandoffFileTree(directory, protected: true)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0.hasPrefix("BWC2-")
      }
      guard names.count == 1 else { throw NativePeripheralInputError.localInput }
      let factory = try tree.read(names[0], maximum: 32 << 20)
      try Task.checkCancellation()
      let chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
      guard chosen != 0 else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(chosen) }
      guard
        let address = IORegistryEntryCreateCFProperty(
          chosen, "mac-address-bluetooth0" as CFString,
          kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
      else { throw NativePeripheralInputError.localInput }
      var iterator: io_iterator_t = 0
      guard
        IOServiceGetMatchingServices(
          kIOMainPortDefault, IOServiceNameMatching("exbright"), &iterator) == KERN_SUCCESS
      else {
        throw NativePeripheralInputError.localInput
      }
      defer { IOObjectRelease(iterator) }
      var records = [Data]()
      var count = 0
      while true {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        count += 1
        guard count <= 64 else { throw NativePeripheralInputError.localInput }
        if let value = IORegistryEntryCreateCFProperty(
          entry, "LSCI" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        {
          guard let bytes = value as? Data else { throw NativePeripheralInputError.localInput }
          records.append(bytes)
        }
      }
      guard records.count == 1 else { throw NativePeripheralInputError.localInput }
      let sensor = try NativeSensorInputCollector.live.collect(storeIdentifier: storeIdentifier)
      try verifyFactoryStore()
      return Self(factory: factory, lsci: records[0], address: address, sensor: sensor)
    }
  }

  enum NativePeripheralInputError: Error, Equatable, LocalizedError {
    case localInput, invalidRecipe, identityChanged, invalidPolicy, unsafeSnapshot
    case sensorCalibrationMissing, sensorRootKeyMissing
    var errorDescription: String? {
      switch self {
      case .sensorRootKeyMissing:
        "Touch ID is present, but this Mac’s signed sensor root-key record is missing or ambiguous."
      case .sensorCalibrationMissing:
        "Touch ID is present, but its factory calibration cannot be paired with its root-key record."
      default: "Required device firmware inputs could not be verified."
      }
    }
  }

  struct NativeNeoInputInventory: Sendable {
    struct File: Sendable {
      let name: String
      let bytes: Int
      let sha256: String
    }
    let recipeSHA256: String
    let files: [File]
    static func sealed() throws -> Self {
      let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
      return Self(
        recipeSHA256: plan.recipeSHA256,
        files: plan.outputs.map {
          File(name: $0.name, bytes: $0.sizeBytes, sha256: $0.sha256)
        })
    }
  }

  struct PreparedNativePeripheralInputs: Sendable {
    let directory: URL
    let recipeSHA256: String
    private let owner: uid_t
    private let device: dev_t
    private let inode: ino_t

    init(directory: URL, recipeSHA256: String, owner: uid_t = 0) throws {
      var info = stat()
      guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner, info.st_mode & 0o077 == 0
      else { throw NativePeripheralInputError.unsafeSnapshot }
      self.directory = directory
      self.recipeSHA256 = recipeSHA256
      self.owner = owner
      device = info.st_dev
      inode = info.st_ino
    }
    var environment: [String: String] {
      [
        "OMARCHY_NATIVE_PERIPHERALS": directory.path,
        "OMARCHY_NATIVE_FIRMWARE_RECIPE": recipeSHA256,
      ]
    }
    /// Cleanup ignores task cancellation, but never ignores an I/O failure or
    /// deletes a different directory that has replaced this attempt's snapshot.
    func remove() throws {
      var info = stat()
      if lstat(directory.path, &info) != 0 {
        guard errno == ENOENT else { throw NativePeripheralInputError.unsafeSnapshot }
        return
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner,
        info.st_mode & 0o077 == 0, info.st_dev == device, info.st_ino == inode
      else { throw NativePeripheralInputError.unsafeSnapshot }
      try FileManager.default.removeItem(at: directory)
      try RecoveryFileTransaction.flushDirectory(directory.deletingLastPathComponent())
    }

    static func withCleanup<T>(
      _ prepared: Self?, operation: () async throws -> T
    ) async throws -> T {
      let outcome: Result<T, any Error>
      do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
      do { try prepared?.remove() } catch {
        throw NativePeripheralCleanupError(operation: outcome.failure, cleanup: error)
      }
      return try outcome.get()
    }
  }

  extension Result {
    fileprivate var failure: Failure? {
      if case .failure(let error) = self { return error }
      return nil
    }
  }

  struct NativePeripheralCleanupError: Error {
    let operation: (any Error)?
    let cleanup: any Error
  }

  protocol NativePeripheralPreparing: Sendable {
    func prepare(package: ImportedEngineHandoffPackage, rawDirectory: URL) async throws
      -> PreparedNativePeripheralInputs
  }

  /// Converted snapshots are fresh per attempt and never placed in the imported
  /// package or the model-wide raw cache. Private local inputs are never published.
  struct NativeNeoPeripheralPreparer: NativePeripheralPreparing {
    private let owner: uid_t
    private let inventory: @Sendable () throws -> NativeNeoInputInventory
    private let localInputs: @Sendable (String) throws -> NativeNeoLocalInputs
    init() {
      owner = 0
      inventory = { try NativeNeoInputInventory.sealed() }
      localInputs = { try NativeNeoLocalInputs.live(storeIdentifier: $0) }
    }
    init(
      owner: uid_t, inventory: @escaping @Sendable () throws -> NativeNeoInputInventory,
      localInputs: @escaping @Sendable (String) throws -> NativeNeoLocalInputs
    ) {
      self.owner = owner
      self.inventory = inventory
      self.localInputs = localInputs
    }

    struct Record: Codable, Equatable, Sendable {
      let role: String
      let bytes: Int
      let sha256: String
    }
    struct Manifest: Codable, Sendable {
      enum CodingKeys: String, CodingKey {
        case schema, converter, files
        case deviceIdentifier = "device_identifier"
        case bindingDigest = "binding_digest"
        case planDigest = "plan_digest"
        case metadataDigest = "metadata_digest"
        case payloadDigest = "payload_digest"
        case recipeSHA256 = "recipe_sha256"
        case localInputs = "local_inputs"
      }
      let schema: Int
      let converter: String
      let deviceIdentifier: String
      let bindingDigest: String
      let planDigest: String
      let metadataDigest: String
      let payloadDigest: String
      let recipeSHA256: String
      let localInputs: [String: String]
      let files: [String: Record]
    }

    func prepare(package: ImportedEngineHandoffPackage, rawDirectory: URL) async throws
      -> PreparedNativePeripheralInputs
    {
      try Task.checkCancellation()
      guard package.deviceIdentifier == "apple,j700",
        package.metadataURL.deletingLastPathComponent().path == package.packageURL.path,
        package.identityURL.deletingLastPathComponent().path == package.packageURL.path
      else { throw NativePeripheralInputError.identityChanged }
      let controls = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let metadata = try controls.read(package.metadataURL.lastPathComponent, maximum: 65536)
      let identityData = try controls.read(package.identityURL.lastPathComponent, maximum: 65536)
      guard let identity = try JSONSerialization.jsonObject(with: identityData) as? [String: Any],
        identity["metadata_digest"] as? String == SHA256Digest(hashing: metadata).rawValue,
        let payloadDigest = identity["payload_digest"] as? String,
        SHA256Digest(rawValue: payloadDigest) != nil
      else { throw NativePeripheralInputError.identityChanged }
      let source = try inventory()
      guard SHA256Digest(hexadecimal: source.recipeSHA256) != nil, source.files.count <= 128,
        Set(source.files.map(\.name)).count == source.files.count
      else { throw NativePeripheralInputError.invalidRecipe }
      let raw = try NativeHandoffFileTree(rawDirectory, protected: true, owner: owner)
      func read(_ name: String) throws -> Data {
        guard let record = source.files.first(where: { $0.name == name }), record.bytes > 0,
          record.bytes <= 64 << 20
        else { throw NativePeripheralInputError.invalidRecipe }
        let bytes = try raw.read(name, maximum: record.bytes)
        guard bytes.count == record.bytes, Self.digest(bytes) == record.sha256 else {
          throw NativePeripheralInputError.invalidRecipe
        }
        return bytes
      }
      let camera = source.files.filter { $0.name.hasPrefix("camera/") }
      guard camera.count == 1 else { throw NativePeripheralInputError.invalidRecipe }
      var outputs = try NeoFirmwareConversions.camera(read(camera[0].name))
      let cameraNames = Set(outputs.keys)
      let local = try localInputs(package.storeIdentifier)
      try Task.checkCancellation()
      let radio = try NeoFirmwareConversions.radio(
        .init(
          patch: read("sunrise/" + NeoFirmwareConversions.wifiPatch),
          ram: read("sunrise/" + NeoFirmwareConversions.wifiRAM),
          ppr: read("sunrise/IZUBA_PPR_MT7932.bin"), config: read("sunrise/IZUBA_wifi.cfg"),
          bluetooth: NeoFirmwareConversions.bluetoothNames.map { try read("bluetooth/" + $0) },
          ptx: read("bluetooth/" + NeoFirmwareConversions.ptxName), factory: local.factory,
          address: local.address))
      outputs.merge(radio) { _, new in new }
      outputs[NeoFirmwareConversions.alsName] = try NeoFirmwareConversions.alsCalibration(
        local.lsci)
      outputs["fallback/lsci.bin"] = local.lsci
      if let sensor = local.sensor {
        let calibration = sensor.calibration
        guard try SignedSensorInputs.calibration(in: calibration) == calibration else {
          throw NativePeripheralInputError.localInput
        }
        outputs["apple/mesacal-j700.bin"] = calibration
        outputs["apple/msrk-j700.bin"] = try SignedSensorInputs.rootKey(sensor.rootKey)
      }
      let policies = try await suppliedPolicies(metadata: metadata, payload: package.payloadURL)
      outputs.merge(policies) { _, new in new }
      var records = [String: Record]()
      for (name, data) in outputs {
        let role =
          cameraNames.contains(name)
          ? "camera"
          : radio[name] != nil
            ? "radio"
            : name == NeoFirmwareConversions.alsName
              ? "als"
              : name == "fallback/lsci.bin"
                ? "lsci"
                : ["apple/mesacal-j700.bin", "apple/msrk-j700.bin"].contains(name)
                  ? "sensor" : "policy"
        records[name] = Record(role: role, bytes: data.count, sha256: Self.digest(data))
      }
      var localDigests = [
        "factory": Self.digest(local.factory), "lsci": Self.digest(local.lsci),
        "address": Self.digest(local.address),
      ]
      if let sensor = local.sensor {
        localDigests["sensorCalibration"] = Self.digest(sensor.calibration)
        localDigests["sensorRootKey"] = Self.digest(sensor.rootKey)
      }
      let manifest = Manifest(
        schema: 1, converter: "neo-v1", deviceIdentifier: package.deviceIdentifier,
        bindingDigest: package.bindingDigest, planDigest: package.planDigest,
        metadataDigest: SHA256Digest(hashing: metadata).rawValue, payloadDigest: payloadDigest,
        recipeSHA256: source.recipeSHA256,
        localInputs: localDigests, files: records)
      let parent = package.packageURL.deletingLastPathComponent()
      _ = try NativeHandoffFileTree(parent, protected: true, owner: owner)
      let directory = parent.appendingPathComponent(
        "neo-peripherals-" + UUID().uuidString.lowercased())
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let prepared = try PreparedNativePeripheralInputs(
        directory: directory, recipeSHA256: source.recipeSHA256, owner: owner)
      do {
        for name in outputs.keys.sorted() {
          try Task.checkCancellation()
          guard NativeHandoffEvidence.safeRelative(name) else {
            throw NativePeripheralInputError.unsafeSnapshot
          }
          let path = directory.appendingPathComponent("files/" + name)
          try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          try Self.write(outputs[name]!, to: path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.write(
          encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"))
        try RecoveryFileTransaction.flushTree(directory)
        try RecoveryFileTransaction.flushDirectory(parent)
        return prepared
      } catch {
        let operationError = error
        do { try prepared.remove() } catch {
          throw NativePeripheralCleanupError(operation: operationError, cleanup: error)
        }
        throw operationError
      }
    }

    private func suppliedPolicies(metadata: Data, payload: URL) async throws -> [String: Data] {
      let target = try NativePayloadPreflight.target(metadata)
      guard let contract = target["neo_regulatory_policy"] as? [String: Any],
        Set(contract.keys) == ["kind", "files"],
        contract["kind"] as? String == "original-j7rp-v1",
        let files = contract["files"] as? [String: String],
        files["world-XZ.bin"] != nil, (1...251).contains(files.count)
      else { throw NativePeripheralInputError.invalidPolicy }
      let archive = try await IPSWArchive.open(NativePayloadRangeReader(payload, owner: owner))
      var result = [String: Data]()
      for (name, memberName) in files {
        let country = name == "world-XZ.bin" ? "XZ" : String(name.dropLast(4))
        guard
          name == "world-XZ.bin"
            || (name == country + ".bin" && country.utf8.count == 2
              && country.utf8.allSatisfy({ (65...90).contains($0) })),
          memberName == "installer-inputs/mt7932-policy/" + name,
          let member = archive.members.first(where: { $0.name == memberName }),
          (16...16384).contains(member.sizeBytes)
        else { throw NativePeripheralInputError.invalidPolicy }
        let data = try await archive.read(member, maximumBytes: 16384)
        result["mediatek/mt7932/policy/" + name] = try NeoFirmwareConversions.policy(
          data, country: country)
      }
      return result
    }

    private static func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ data: Data, to url: URL) throws {
      let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw NativePeripheralInputError.unsafeSnapshot }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      defer { try? file.close() }
      try file.write(contentsOf: data)
      try file.synchronize()
    }
  }
#endif
