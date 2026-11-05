// Based on aurora-audio-dsp by saku (MIT): the collection of the machine's
// own AID<n> tuning folder through the device tree's `acoustic-id`, and of
// the per-unit `speaker-thiele-small` calibration, follows saku's
// tools/macos-collector/collect-audio-tuning.sh.
//
// Copyright (c) 2026 saku
// Copyright (c) 2026 The Aurora Silicon Contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#if os(macOS)
  import Darwin
  import Foundation
  import IOKit

  /// This Mac's own speaker tuning, read only from the running macOS.
  ///
  /// The device tree's audio node names the tuning folder (`acoustic-id`
  /// 35 selects `AID35`) and, on Macs with speaker calibration, carries the
  /// per-unit `speaker-thiele-small` record. Both are copied unchanged into
  /// the per-machine vendor firmware, beside Wi-Fi, Bluetooth and camera
  /// firmware, for the Linux speaker protection to read. Nothing here is
  /// shipped by the installer: the data comes from the user's own system
  /// volume and stays on the user's own ESP.
  enum NativeAudioTuningInputs {
    /// Where the tuning folders live on the sealed system volume.
    static let tuningsPrefix = "System/Library/Audio/Tunings"
    /// Names in the firmware package (`/lib/firmware/vendor/` on Linux).
    static let packagePrefix = "apple/audio-tuning/"
    /// Names in the raw fallback archive (`asahi/all_firmware.tar.gz`).
    static let fallbackPrefix = "audio-tuning/"
    static let manifestName = "manifest.json"
    static let thieleSmallName = "speaker-thiele-small.bin"
    /// AID35 is 34 files and 2.4 MB; these bounds leave ample room.
    static let maximumFiles = 1024
    static let maximumBytes = 64 << 20
    /// The manifest schema. 2 adds `source_file_count` and `complete`.
    static let schema = 2

    struct Snapshot: Sendable, Equatable {
      /// The `acoustic-id` value, e.g. 35.
      var acousticID: UInt32
      /// Raw `speaker-thiele-small`. Absent on Macs without speaker
      /// calibration (Mac mini, iMac, Mac Studio), which still get tuning.
      var thieleSmall: Data?
      /// Files of the `AID<n>` folder, by path relative to it.
      var files: [String: Data]
      /// The macOS build the files came from, e.g. 25G83.
      var build: String
      /// The machine's selection data from the Tunings root, by bundle path:
      /// `DeviceDSPDatabase.plist` holding only this Mac's `AID<n>` entry
      /// (the speaker configurations and the graph, strip and property
      /// strip each uses), and `Config/AID<n>.plist` unchanged (output
      /// volume ranges and scalars).
      var selection: [String: Data] = [:]
      /// Admitted entries of the source folder (regular files and links to
      /// them). Nil means `files.count`; anything else must equal it.
      var sourceFileCount: Int? = nil
      /// The HAL's `spid`: IORegistry `speakerID` of the built-in speaker
      /// device, which selects among speaker vendor variants. Nil when
      /// unknown; 65535 (an invalid strap) is kept as reported.
      var speakerID: UInt32? = nil
      /// Where the database entry was read, relative to the Tunings root:
      /// the shared `DeviceDSPDatabase.plist` (up to macOS 26) or
      /// `AID<n>/DSP/DSPDatabase.plist` (macOS 27).
      var databaseSource: String = NativeAudioTuningInputs.databaseName
      /// Files outside `AID<n>/` that the speaker modes reference
      /// (`Common/...`), by path relative to the Tunings root.
      var sharedFiles: [String: Data] = [:]
      /// `DRC/loudness-manager.plist`, only when it lists this AID.
      var loudnessManager: Data? = nil
      /// The lsm2 masker's bucket lattice from this Mac's AudioDSP
      /// component (`NativeLSM2Lattice`). Required: without it there is no
      /// bundle.
      var maskLattice: Data? = nil
      /// Canonical root target-type, e.g. j616s (Linux apple,j616s).
      var machineModel: String? = nil
      /// SHA-256 of root serial-number without trailing NUL bytes.
      var unitIDHash: String? = nil
    }

    /// The selection data read from the Tunings root for one Mac.
    struct Selection: Equatable {
      var selection: [String: Data] = [:]
      var databaseSource: String = NativeAudioTuningInputs.databaseName
      var sharedFiles: [String: Data] = [:]
      var loudnessManager: Data? = nil
    }

    struct Manifest: Codable, Equatable {
      struct File: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
      }
      /// The lsm2 masker lattice record: a file record plus its layout.
      struct Lattice: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
        let version: Int
        let format: String
        let entries: Int
      }
      let schema: Int
      let kind: String
      /// Entries of the source `AID<n>` folder; equals the `AID<n>/`
      /// records in `files`.
      let sourceFileCount: Int
      /// True only for a full set: every folder entry and both selection
      /// files. Readers refuse anything else.
      let complete: Bool
      let machineModel: String?
      let unitIDHash: String?
      let acousticID: UInt32
      let aid: String
      let macOSBuild: String
      let speakerThieleSmall: File?
      /// Bundle path of the filtered DSP database, when the Mac has an entry.
      let deviceDSPDatabase: String?
      /// Bundle path of `Config/AID<n>.plist`, when present.
      let config: String?
      /// The speaker ID (`spid`); omitted when unknown.
      let speakerID: UInt32?
      /// Where the entry was read (see `Snapshot.databaseSource`).
      /// Optional for readers; missing means the shared database.
      let deviceDSPDatabaseSource: String?
      /// Files outside `AID<n>/` the speaker modes reference. Kept apart
      /// from `files` so schema 2 readers still accept the bundle.
      let sharedFiles: [File]?
      /// The loudness manager, only when it lists this AID; omitted
      /// otherwise.
      let loudnessManager: File?
      /// The lsm2 masker's bucket lattice: 100 little-endian u64 exclusive
      /// bucket ends (version 1). Optional for readers: bundles collected
      /// before it have none.
      let lsm2MaskLattice: Lattice?
      let files: [File]
      let basedOn: String

      enum CodingKeys: String, CodingKey {
        case schema, kind, aid, files, config, complete
        case sourceFileCount = "source_file_count"
        case machineModel = "machine_model"
        case unitIDHash = "unit_id_sha256"
        case acousticID = "acoustic_id"
        case macOSBuild = "macos_build"
        case speakerThieleSmall = "speaker_thiele_small"
        case deviceDSPDatabase = "device_dsp_database"
        case speakerID = "speaker_id"
        case deviceDSPDatabaseSource = "device_dsp_database_source"
        case sharedFiles = "shared_files"
        case loudnessManager = "loudness_manager"
        case lsm2MaskLattice = "lsm2_mask_lattice"
        case basedOn = "based_on"
      }
    }

    static let databaseName = "DeviceDSPDatabase.plist"
    static func configName(_ acousticID: UInt32) -> String {
      "Config/" + folder(acousticID) + ".plist"
    }

    /// This Mac's entry of the DSP database, as a property list with that
    /// one key. Nil when the database has no entry for it.
    static func databaseEntry(_ database: Data, acousticID: UInt32) throws -> Data? {
      guard
        let root = try PropertyListSerialization.propertyList(from: database, format: nil)
          as? [String: Any]
      else { throw NativePeripheralInputError.localInput }
      let key = folder(acousticID)
      guard let entry = root[key] else { return nil }
      return try PropertyListSerialization.data(
        fromPropertyList: [key: entry], format: .xml, options: 0)
    }

    /// macOS 27 keeps each Mac's entry in its own folder, with the same
    /// shape as the shared database: one top-level key, `AID<n>`.
    static let folderDatabaseName = "DSP/DSPDatabase.plist"
    static func folderDatabase(_ acousticID: UInt32) -> String {
      folder(acousticID) + "/" + folderDatabaseName
    }
    /// Roots the speaker graph may reference outside `AID<n>/`.
    static let sharedRoots: Set<String> = ["Common"]
    static let speakerDevice = "Built-in Speaker"
    /// The loudness manager's DRC applies to the AIDs it lists.
    static let loudnessName = "DRC/loudness-manager.plist"
    static let maximumConfigBytes = 1 << 20

    /// Whether a database holds exactly one key, `AID<n>`, with a
    /// dictionary. Such a per-folder entry is kept byte for byte.
    static func onlyEntry(_ database: Data, acousticID: UInt32) throws -> Bool {
      guard
        let root = try PropertyListSerialization.propertyList(from: database, format: nil)
          as? [String: Any]
      else { throw NativePeripheralInputError.localInput }
      return root.count == 1 && root[folder(acousticID)] is [String: Any]
    }

    private static func paths(_ node: Any, into out: inout [String]) {
      if let dictionary = node as? [String: Any] {
        for (key, value) in dictionary {
          if key == "Path", let path = value as? String {
            out.append(path)
          } else {
            paths(value, into: &out)
          }
        }
      } else if let array = node as? [Any] {
        for value in array { paths(value, into: &out) }
      }
    }

    private static func isShared(_ path: String) -> Bool {
      guard let first = path.split(separator: "/", omittingEmptySubsequences: false).first,
        sharedRoots.contains(String(first))
      else { return false }
      return path.contains("/")
    }

    /// The paths below `AID<n>/` (relative to it) and the shared paths
    /// (relative to the Tunings root) that the entry's built-in speaker
    /// modes reference. Anything outside `AID<n>/` and `Common/` fails.
    static func speakerReferences(_ entry: Data, acousticID: UInt32) throws
      -> (own: Set<String>, shared: Set<String>)
    {
      let root = try PropertyListSerialization.propertyList(from: entry, format: nil)
      let aid = folder(acousticID)
      var found = [String]()
      if let entries = root as? [String: Any], let machine = entries[aid] as? [String: Any],
        let speaker = machine[speakerDevice]
      {
        paths(speaker, into: &found)
      }
      var own = Set<String>()
      var shared = Set<String>()
      for path in found {
        guard admitted(path) else { throw NativePeripheralInputError.localInput }
        if path.hasPrefix(aid + "/") {
          own.insert(String(path.dropFirst(aid.count + 1)))
        } else if isShared(path) {
          shared.insert(path)
        } else {
          throw NativePeripheralInputError.localInput
        }
      }
      return (own, shared)
    }

    /// Whether the loudness manager lists `AID<n>`.
    static func loudnessLists(_ data: Data, acousticID: UInt32) throws -> Bool {
      guard
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        let listed = root["Supported_Hardware"] as? [Any]
      else { throw NativePeripheralInputError.localInput }
      let names = listed.compactMap { $0 as? String }
      guard names.count == listed.count else { throw NativePeripheralInputError.localInput }
      return names.contains(folder(acousticID))
    }

    /// The selection data from the Tunings root, read through `tree` below
    /// `prefix` (`System/Library/Audio/Tunings` on the system volume), as
    /// the Python collector reads it: the folder's own
    /// `AID<n>/DSP/DSPDatabase.plist` when it exists (macOS 27), else the
    /// shared `DeviceDSPDatabase.plist`. A per-folder database that already
    /// holds only this Mac's entry is kept byte for byte; anything else is
    /// reduced to that entry. Every file the speaker modes reference must
    /// be in the folder or under `Common/`.
    static func selection(
      _ tree: NativeHandoffFileTree, prefix: String, acousticID: UInt32,
      files: [String: Data], owner: uid_t
    ) throws -> Selection {
      var result = Selection()
      var database = prefix + "/" + databaseName
      if try !tree.isAbsent(prefix + "/" + folderDatabase(acousticID)) {
        result.databaseSource = folderDatabase(acousticID)
        database = prefix + "/" + result.databaseSource
      }
      if try !tree.isAbsent(database) {
        let data = try NativeFirmwareInputFiles.read(
          tree, path: database, maximum: maximumBytes, owner: owner)
        if result.databaseSource != databaseName, try onlyEntry(data, acousticID: acousticID) {
          result.selection[databaseName] = data
        } else if let entry = try databaseEntry(data, acousticID: acousticID) {
          result.selection[databaseName] = entry
        }
      }
      let config = prefix + "/" + configName(acousticID)
      if try !tree.isAbsent(config) {
        result.selection[configName(acousticID)] = try NativeFirmwareInputFiles.read(
          tree, path: config, maximum: maximumConfigBytes, owner: owner)
      }
      if let entry = result.selection[databaseName] {
        let (own, shared) = try speakerReferences(entry, acousticID: acousticID)
        guard own.allSatisfy({ files[$0] != nil }) else {
          throw NativePeripheralInputError.localInput
        }
        for path in shared.sorted() {
          result.sharedFiles[path] = try NativeFirmwareInputFiles.read(
            tree, path: prefix + "/" + path, maximum: maximumBytes, owner: owner)
        }
      }
      let loudness = prefix + "/" + loudnessName
      if try !tree.isAbsent(loudness) {
        let data = try NativeFirmwareInputFiles.read(
          tree, path: loudness, maximum: maximumConfigBytes, owner: owner)
        if try loudnessLists(data, acousticID: acousticID) { result.loudnessManager = data }
      }
      return result
    }

    /// `AID<n>`, the folder name for an acoustic ID.
    static func folder(_ acousticID: UInt32) -> String { "AID\(acousticID)" }

    /// The device tree stores `acoustic-id` as one little-endian 32-bit word.
    static func acousticID(_ bytes: Data) -> UInt32? {
      guard bytes.count == 4 else { return nil }
      let value = bytes.enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << (8 * $1.offset)
      }
      guard value > 0, value < 100_000 else { return nil }
      return value
    }

    /// A tuning file name is a plain relative path; macOS AppleDouble and
    /// Finder sidecars are not tuning data.
    static func admitted(_ relative: String) -> Bool {
      guard NativeHandoffEvidence.safeRelative(relative), !relative.hasPrefix("/") else {
        return false
      }
      return !relative.split(separator: "/").contains {
        $0.hasPrefix("._") || $0 == ".DS_Store"
      }
    }

    /// The live snapshot, or nil on a Mac without an audio node or without a
    /// tuning folder for it.
    static func live(owner: uid_t) throws -> Snapshot? {
      guard let (acoustic, thieleSmall) = try properties(),
        let acousticID = acousticID(acoustic)
      else { return nil }
      let identity = try liveIdentity()
      let root = URL(fileURLWithPath: "/", isDirectory: true)
      let prefix = tuningsPrefix + "/" + folder(acousticID)
      var info = stat()
      guard lstat(root.appendingPathComponent(prefix).path, &info) == 0,
        info.st_mode & S_IFMT == S_IFDIR
      else { return nil }
      let tree = try NativeHandoffFileTree(
        root, protected: true, owner: owner, readOnlyVolume: true)
      let descriptor = try tree.fileDescriptor(prefix)
      defer { close(descriptor) }
      guard NativeHandoffFileTree.isReadOnly(descriptor) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let snapshot = try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: prefix, tree: tree, owner: owner)
      let (files, count) = try admittedFiles(snapshot)
      let selected = try selection(
        tree, prefix: tuningsPrefix, acousticID: acousticID, files: files, owner: owner)
      // Exactly one valid lattice, or no bundle: never a guessed table.
      let component: Data
      do {
        component = try NativeFirmwareInputFiles.read(
          tree, path: NativeLSM2Lattice.componentPath,
          maximum: NativeLSM2Lattice.maximumComponentBytes, owner: owner)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw NativeLSM2Lattice.Failure.malformed("cannot read it: \(error)")
      }
      let lattice = try NativeLSM2Lattice.extract(component)
      return Snapshot(
        acousticID: acousticID, thieleSmall: thieleSmall, files: files, build: build(),
        selection: selected.selection, sourceFileCount: count, speakerID: liveSpeakerID(),
        databaseSource: selected.databaseSource, sharedFiles: selected.sharedFiles,
        loudnessManager: selected.loudnessManager, maskLattice: lattice,
        machineModel: identity.model, unitIDHash: identity.unit)
    }

    static let speakerServiceClass = "AppleEmbeddedAudioDevice"

    /// The speaker ID from registry entries' `device UID` and `speakerID`:
    /// exactly one entry must be the `Speaker` device, and its value an
    /// integral CFNumber that fits a UInt32. Anything else is unknown.
    static func speakerID(_ services: [[String: Any]]) -> UInt32? {
      let speakers = services.filter { ($0["device UID"] as? String) == "Speaker" }
      guard speakers.count == 1, let value = speakers[0]["speakerID"] else { return nil }
      let object = value as AnyObject
      guard CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
      let number = unsafeBitCast(object, to: CFNumber.self)
      var wide: Int64 = 0
      guard !CFNumberIsFloatType(number), CFNumberGetValue(number, .sInt64Type, &wide),
        wide >= 0, wide <= Int64(UInt32.max)
      else { return nil }
      return UInt32(wide)
    }

    /// The live speaker ID. `read` returns the registry entries; it is a
    /// parameter so tests need no IOKit. Absence never fails collection.
    static func liveSpeakerID(_ read: () -> [[String: Any]] = speakerServices) -> UInt32? {
      speakerID(read())
    }

    /// `device UID` and `speakerID` of every `AppleEmbeddedAudioDevice` in
    /// the service plane. Read only: no user client is opened and nothing
    /// is written. Empty on any failure.
    static func speakerServices() -> [[String: Any]] {
      guard let matching = IOServiceMatching(speakerServiceClass) else { return [] }
      var iterator: io_iterator_t = 0
      guard
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
      else { return [] }
      defer { IOObjectRelease(iterator) }
      var services = [[String: Any]]()
      while true {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        guard services.count < 256 else { return [] }
        var properties = [String: Any]()
        for key in ["device UID", "speakerID"] {
          if let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          {
            properties[key] = value
          }
        }
        services.append(properties)
      }
      return services
    }

    /// The folder's admitted files, with each admitted link kept as a copy
    /// of its target, and the number of admitted entries. A link that does
    /// not end at a regular file of the folder fails the whole set, so a
    /// short read never becomes a bundle.
    static func admittedFiles(
      _ snapshot: NativeFirmwareInputFiles.Snapshot
    ) throws -> (files: [String: Data], count: Int) {
      var files = [String: Data]()
      var count = 0
      for (name, data) in snapshot.files where admitted(name) {
        files[name] = data
        count += 1
      }
      guard !snapshot.unresolved.contains(where: admitted) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      for (alias, target) in snapshot.links where admitted(alias) {
        guard let data = snapshot.files[target] else {
          throw NativeFirmwareInputFailure.invalidSource
        }
        files[alias] = data
        count += 1
      }
      return (files, count)
    }

    /// `acoustic-id` and `speaker-thiele-small` of the one device-tree audio
    /// node that carries an acoustic ID. Nil when there is none.
    static func properties() throws -> (Data, Data?)? {
      func read(_ entry: io_registry_entry_t) -> (Data, Data?)? {
        guard
          let acoustic = IORegistryEntryCreateCFProperty(
            entry, "acoustic-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? Data
        else { return nil }
        let spts =
          IORegistryEntryCreateCFProperty(
            entry, "speaker-thiele-small" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
        return (acoustic, spts)
      }
      var iterator: io_iterator_t = 0
      guard
        IORegistryCreateIterator(
          kIOMainPortDefault, kIODeviceTreePlane, IOOptionBits(kIORegistryIterateRecursively),
          &iterator) == KERN_SUCCESS
      else { return nil }
      defer { IOObjectRelease(iterator) }
      var matches: [(Data, Data?)] = []
      var count = 0
      while true {
        try Task.checkCancellation()
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        count += 1
        guard count <= 65_536 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(entry, kIODeviceTreePlane, &name) == KERN_SUCCESS,
          String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == "audio",
          let properties = read(entry)
        else { continue }
        matches.append(properties)
      }
      return try oneAudioNode(matches)
    }

    static func oneAudioNode(_ matches: [(Data, Data?)]) throws -> (Data, Data?)? {
      guard matches.count <= 1 else { throw NativePeripheralInputError.localInput }
      return matches.first
    }

    /// Hash exactly the bytes aura passes to Linux, excluding trailing NULs.
    static func unitHash(_ raw: Data) throws -> String {
      let serial = raw.reversed().drop(while: { $0 == 0 }).reversed()
      guard !serial.isEmpty, serial.count <= 128,
        serial.allSatisfy({ (0x21...0x7e).contains($0) })
      else { throw NativePeripheralInputError.localInput }
      return NativeStubFileStore.hash(Data(serial))
    }

    static func machineModel(_ raw: Any?) throws -> String {
      let value: String?
      if let data = raw as? Data {
        value = String(
          data: Data(data.reversed().drop(while: { $0 == 0 }).reversed()), encoding: .ascii)
      } else {
        value = raw as? String
      }
      guard let value else { throw NativePeripheralInputError.localInput }
      var model = value.lowercased()
      if model.hasSuffix("ap") { model.removeLast(2) }
      guard !model.isEmpty, model.utf8.count <= 8,
        model.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) })
      else { throw NativePeripheralInputError.localInput }
      return model
    }

    static func identity(_ root: [String: Any]) throws -> (model: String, unit: String?) {
      let model = try machineModel(root["target-type"])
      guard let serial = root["serial-number"] else { return (model, nil) }
      guard let serial = serial as? Data else { throw NativePeripheralInputError.localInput }
      return (model, try unitHash(serial))
    }

    static func liveIdentity() throws -> (model: String, unit: String?) {
      let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
      guard root != 0 else { throw NativePeripheralInputError.localInput }
      defer { IOObjectRelease(root) }
      var properties: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let properties = properties?.takeRetainedValue() as? [String: Any]
      else { throw NativePeripheralInputError.localInput }
      return try identity(properties)
    }

    static func build() -> String {
      var size = 0
      guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0, size < 64 else {
        return "unknown"
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
      let value = String(
        decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return value.range(of: #"\A[0-9A-Za-z]{1,16}\z"#, options: .regularExpression) == nil
        ? "unknown" : value
    }

    /// The package files for a snapshot, under `prefix`: the folder's files
    /// below `AID<n>/`, the calibration record and a manifest with every
    /// file's size and SHA-256. Empty for no snapshot.
    static func files(_ snapshot: Snapshot?, prefix: String) throws -> [String: Data] {
      guard let snapshot else { return [:] }
      guard !snapshot.files.isEmpty,
        snapshot.files.count + snapshot.sharedFiles.count <= maximumFiles,
        (snapshot.sourceFileCount ?? snapshot.files.count) == snapshot.files.count
      else {
        throw NativePeripheralInputError.localInput
      }
      // Only a complete set is a bundle: both selection files are required.
      guard snapshot.selection[databaseName] != nil,
        snapshot.selection[configName(snapshot.acousticID)] != nil
      else { throw NativePeripheralInputError.localInput }
      guard let model = snapshot.machineModel, try machineModel(model) == model else {
        throw NativePeripheralInputError.localInput
      }
      if let unit = snapshot.unitIDHash {
        guard unit.utf8.count == 64,
          unit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw NativePeripheralInputError.localInput }
      }
      let aid = folder(snapshot.acousticID)
      var result = [String: Data]()
      var records = [Manifest.File]()
      var total = 0
      for name in snapshot.files.keys.sorted() {
        let data = snapshot.files[name]!
        guard admitted(name), data.count <= maximumBytes - total else {
          throw NativePeripheralInputError.localInput
        }
        total += data.count
        result[prefix + aid + "/" + name] = data
        records.append(
          Manifest.File(
            path: aid + "/" + name, bytes: data.count, sha256: NativeStubFileStore.hash(data)))
      }
      for name in snapshot.selection.keys.sorted() {
        let data = snapshot.selection[name]!
        guard name == databaseName || name == configName(snapshot.acousticID),
          !data.isEmpty, data.count <= maximumBytes - total
        else { throw NativePeripheralInputError.localInput }
        total += data.count
        result[prefix + name] = data
        records.append(
          Manifest.File(path: name, bytes: data.count, sha256: NativeStubFileStore.hash(data)))
      }
      guard
        snapshot.databaseSource == databaseName
          || snapshot.databaseSource == folderDatabase(snapshot.acousticID)
      else { throw NativePeripheralInputError.localInput }
      var shared = [Manifest.File]()
      for name in snapshot.sharedFiles.keys.sorted() {
        let data = snapshot.sharedFiles[name]!
        guard admitted(name), isShared(name), data.count <= maximumBytes - total else {
          throw NativePeripheralInputError.localInput
        }
        total += data.count
        result[prefix + name] = data
        shared.append(
          Manifest.File(path: name, bytes: data.count, sha256: NativeStubFileStore.hash(data)))
      }
      var loudness: Manifest.File?
      if let data = snapshot.loudnessManager {
        guard !data.isEmpty, data.count <= maximumConfigBytes, data.count <= maximumBytes - total
        else { throw NativePeripheralInputError.localInput }
        total += data.count
        result[prefix + loudnessName] = data
        loudness = Manifest.File(
          path: loudnessName, bytes: data.count, sha256: NativeStubFileStore.hash(data))
      }
      guard let lattice = snapshot.maskLattice, NativeLSM2Lattice.valid(lattice) else {
        throw NativeLSM2Lattice.Failure.malformed("no valid lsm2 masker lattice")
      }
      result[prefix + NativeLSM2Lattice.bundleName] = lattice
      let latticeRecord = Manifest.Lattice(
        path: NativeLSM2Lattice.bundleName, bytes: lattice.count,
        sha256: NativeStubFileStore.hash(lattice), version: NativeLSM2Lattice.version,
        format: NativeLSM2Lattice.format, entries: NativeLSM2Lattice.entries)
      var thieleSmall: Manifest.File?
      if let spts = snapshot.thieleSmall {
        guard !spts.isEmpty, spts.count <= 4096 else {
          throw NativePeripheralInputError.localInput
        }
        result[prefix + thieleSmallName] = spts
        thieleSmall = Manifest.File(
          path: thieleSmallName, bytes: spts.count, sha256: NativeStubFileStore.hash(spts))
      }
      let manifest = Manifest(
        schema: schema, kind: "aurora-audio-tuning", sourceFileCount: snapshot.files.count,
        complete: true, machineModel: model, unitIDHash: snapshot.unitIDHash,
        acousticID: snapshot.acousticID, aid: aid,
        macOSBuild: snapshot.build, speakerThieleSmall: thieleSmall,
        deviceDSPDatabase: databaseName, config: configName(snapshot.acousticID),
        speakerID: snapshot.speakerID,
        deviceDSPDatabaseSource: snapshot.databaseSource, sharedFiles: shared,
        loudnessManager: loudness,
        lsm2MaskLattice: latticeRecord,
        files: records,
        basedOn: "aurora-audio-dsp by saku (MIT)")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      result[prefix + manifestName] = try encoder.encode(manifest)
      return result
    }

    /// Collection never stops an installation. Without a valid bundle Linux
    /// cannot compile this Mac's tuning. A cancellation still ends the step. A
    /// failure is recorded in the Installer Log, as an error when the lsm2
    /// masker lattice is what failed.
    static func collect(
      _ source: @Sendable (uid_t) throws -> Snapshot?, owner: uid_t
    ) throws -> (package: [String: Data], fallback: [String: Data]) {
      do {
        let snapshot = try source(owner)
        return (
          try files(snapshot, prefix: packagePrefix), try files(snapshot, prefix: fallbackPrefix)
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as NativeLSM2Lattice.Failure {
        InstallerLog.record(
          .error, "Speaker tuning not collected: the lsm2 masker lattice: \(failure)")
        return ([:], [:])
      } catch {
        InstallerLog.record(.progress, "Speaker tuning not collected: \(error)")
        return ([:], [:])
      }
    }
  }
#endif
