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

    static func live() throws -> Self {
      let directory = URL(
        fileURLWithPath:
          "/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata")
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
      return Self(factory: factory, lsci: records[0], address: address)
    }
  }

  enum NativePeripheralInputError: Error, Equatable {
    case localInput, invalidRecipe, identityChanged, invalidPolicy, unsafeSnapshot
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
    var environment: [String: String] {
      [
        "OMARCHY_NATIVE_PERIPHERALS": directory.path,
        "OMARCHY_NATIVE_FIRMWARE_RECIPE": recipeSHA256,
      ]
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
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
    private let localInputs: @Sendable () throws -> NativeNeoLocalInputs
    init() {
      owner = 0
      inventory = { try NativeNeoInputInventory.sealed() }
      localInputs = { try NativeNeoLocalInputs.live() }
    }
    init(
      owner: uid_t, inventory: @escaping @Sendable () throws -> NativeNeoInputInventory,
      localInputs: @escaping @Sendable () throws -> NativeNeoLocalInputs
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
      let local = try localInputs()
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
              ? "als" : name == "fallback/lsci.bin" ? "lsci" : "policy"
        records[name] = Record(role: role, bytes: data.count, sha256: Self.digest(data))
      }
      let manifest = Manifest(
        schema: 1, converter: "neo-v1", deviceIdentifier: package.deviceIdentifier,
        bindingDigest: package.bindingDigest, planDigest: package.planDigest,
        metadataDigest: SHA256Digest(hashing: metadata).rawValue, payloadDigest: payloadDigest,
        recipeSHA256: source.recipeSHA256,
        localInputs: [
          "factory": Self.digest(local.factory), "lsci": Self.digest(local.lsci),
          "address": Self.digest(local.address),
        ], files: records)
      let parent = package.packageURL.deletingLastPathComponent()
      _ = try NativeHandoffFileTree(parent, protected: true, owner: owner)
      let directory = parent.appendingPathComponent(
        "neo-peripherals-" + UUID().uuidString.lowercased())
      let temporary = URL(fileURLWithPath: directory.path + ".preparing", isDirectory: true)
      try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      var published = false
      defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
      for name in outputs.keys.sorted() {
        try Task.checkCancellation()
        guard NativeHandoffEvidence.safeRelative(name) else {
          throw NativePeripheralInputError.unsafeSnapshot
        }
        let path = temporary.appendingPathComponent("files/" + name)
        try FileManager.default.createDirectory(
          at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try Self.write(outputs[name]!, to: path)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try Self.write(
        encoder.encode(manifest), to: temporary.appendingPathComponent("manifest.json"))
      try RecoveryFileTransaction.flushTree(temporary)
      guard
        renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, directory.path, UInt32(RENAME_EXCL)) == 0
      else {
        throw NativePeripheralInputError.unsafeSnapshot
      }
      published = true
      do { try RecoveryFileTransaction.flushDirectory(parent) } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      return PreparedNativePeripheralInputs(directory: directory, recipeSHA256: source.recipeSHA256)
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
