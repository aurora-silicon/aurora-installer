#if os(macOS)
  import AudioToolbox
  import CryptoKit
  import Darwin
  import Foundation

  /// The lsm2 parameter fill for short presets, as the Python collector
  /// (`asahi_firmware/lsm2_fill.py`) collects it, byte for byte.
  ///
  /// An lsm2 preset is short when it lacks any of the compiler's 1,021 base
  /// parameter IDs. The missing values are read back from the running
  /// macOS's own lsm2 AudioUnit through the public AudioUnit v2 hosting
  /// interface: find (or register, in this process) the component,
  /// instantiate it, set the strip's ClassInfo and the matching propstrip
  /// properties, then read ParameterList, ParameterInfo and each parameter.
  /// Nothing is rendered, no audio device is opened and no system file is
  /// written. The readback runs in a separate process (the installer helper
  /// started again with `NativeLSM2FillWorker.argument`) with a 60-second
  /// limit, so a crash or hang in the unit never takes the installer down.
  ///
  /// The result is owner data like the rest of the tuning: no parameter
  /// value is logged, shipped or kept anywhere but the bundle. No ID set or
  /// value from the system component is in this source; the ID schema is
  /// the public compiler's (speakerguardd).
  enum NativeLSM2Fill {
    static let name = "lsm2-param-fill.bin"
    /// 2: captures name the component (unit_version may be 0) and short
    /// presets may carry unit-published append-map IDs.
    static let version = 2
    static let format = "json-id-name-f32bits-v1"
    static let maximumBytes = 4 << 20
    static let maximumParameters = 16384
    static let maximumCaptures = 64
    /// The four-character subtype `lsm2`.
    static let subtype: UInt32 = 0x6c73_6d32
    static let componentPath =
      "/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"
    static let factorySymbol = "AULoudspeakerManagerV2Factory"
    static let timeout: DispatchTimeInterval = .seconds(60)

    struct Failure: Error, Equatable, CustomStringConvertible {
      let description: String
      init(_ description: String) { self.description = description }
    }

    /// The helper executable that runs the readback, set by the helper at
    /// start. Without one (tests, development tools) a short preset is
    /// collected without its fill, as on a Mac whose readback fails.
    nonisolated(unsafe) static var workerExecutable: URL?

    // MARK: The compiler's ID schema

    private static func span(_ range: Range<UInt32>, into ids: inout Set<UInt32>) {
      ids.formUnion(range)
    }

    /// The public compiler's 1,021-ID schema, never parameter values.
    static let baseIDs: Set<UInt32> = {
      var ids = Set<UInt32>()
      span(0..<3, into: &ids)
      span(1024..<1033, into: &ids)
      span(2048..<2062, into: &ids)
      for b in UInt32(0)..<15 { span((3072 + 1024 * b)..<(3109 + 1024 * b), into: &ids) }
      for t in UInt32(0)..<3 { span((18432 + 1024 * t)..<(18448 + 1024 * t), into: &ids) }
      let ranges: [Range<UInt32>] = [
        21504..<21512, 22528..<22537, 23552..<23561, 1_048_576..<1_048_599,
        1_049_600..<1_049_637, 1_050_624..<1_050_645, 1_051_648..<1_051_669,
      ]
      for range in ranges { span(range, into: &ids) }
      for c in UInt32(0)..<8 { span((1_058_816 + 1024 * c)..<(1_058_849 + 1024 * c), into: &ids) }
      return ids
    }()

    /// The compiler's append map (IDs only). A saved ID outside `baseIDs`
    /// is accepted only when it is here and the running unit publishes it.
    static let extensionIDs: Set<UInt32> = {
      var ids: Set<UInt32> = [3, 21512]
      for b in UInt32(0)..<15 { span((3109 + 1024 * b)..<(3125 + 1024 * b), into: &ids) }
      for t in UInt32(0)..<3 { span((18448 + 1024 * t)..<(18450 + 1024 * t), into: &ids) }
      span(24576..<24584, into: &ids)
      let blocks: [UInt32] = [25600, 26624, 27648]
      for b in blocks { span(b..<(b + 4), into: &ids) }
      span(1_048_599..<1_048_604, into: &ids)
      for c in UInt32(0)..<8 { ids.insert(1_058_849 + 1024 * c) }
      span(1_067_008..<1_067_020, into: &ids)
      span(1_068_032..<1_068_044, into: &ids)
      return ids
    }()

    private static func listed(_ ids: Set<UInt32>, limit: Int = 8) -> String {
      let sorted = ids.sorted()
      return sorted.prefix(limit).map(String.init).joined(separator: ", ")
        + (sorted.count > limit ? ", ..." : "")
    }

    // MARK: Presets

    /// The IDs of an lsm2 preset's one global parameter section:
    /// big-endian scope, element and count, then (ID, value) pairs.
    static func presetIDs(_ data: Data) throws -> Set<UInt32> {
      let bytes = [UInt8](data)
      guard bytes.count >= 12 else { throw Failure("lsm2 preset has no global parameter state") }
      func word(_ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      }
      let count = Int(word(8))
      guard word(0) == 0, word(4) == 0, count <= maximumParameters, bytes.count == 12 + 8 * count
      else { throw Failure("lsm2 requires one global parameter section") }
      var ids = Set<UInt32>()
      for index in 0..<count { ids.insert(word(12 + 8 * index)) }
      guard ids.count == count else { throw Failure("duplicate lsm2 preset ID") }
      return ids
    }

    struct Preset {
      /// The strip, relative to the bundle (`AID<n>/DSP/Strips/x.austrip`).
      let path: String
      let effect: NSDictionary
      let data: Data
      let saved: Set<UInt32>
    }

    private static func list(_ value: Any?) throws -> NSArray {
      guard let value else { return [] }
      guard let array = value as? NSArray else { throw Failure("malformed lsm2 strip") }
      return array
    }

    private static func isSubtype(_ value: Any?) -> Bool {
      guard let value, CFGetTypeID(value as AnyObject) == CFNumberGetTypeID(),
        let number = value as? NSNumber
      else { return false }
      return number.doubleValue == Double(subtype)
    }

    /// Every lsm2 effect of every strip, in path order: unrelated or
    /// unreadable strips are skipped (the compiler diagnoses them).
    static func presets(_ files: [String: Data]) throws -> [Preset] {
      var found = [Preset]()
      for path in files.keys.sorted(by: NativePythonEncoding.precedes)
      where path.hasSuffix(".austrip") {
        guard
          let strip = try? PropertyListSerialization.propertyList(
            from: files[path] ?? Data(), format: nil)
        else { continue }
        guard let root = strip as? NSDictionary else { throw Failure("malformed lsm2 strip") }
        for section in try list(root["strips"]) {
          guard let section = section as? NSDictionary else {
            throw Failure("malformed lsm2 strip")
          }
          for effect in try list(section["effects"]) {
            guard let effect = effect as? NSDictionary else {
              throw Failure("malformed lsm2 strip")
            }
            guard let unit = (effect["unit"] ?? NSDictionary()) as? NSDictionary else {
              throw Failure("malformed lsm2 strip")
            }
            guard isSubtype(unit["subtype"]) else { continue }
            guard let preset = effect["aupreset"] as? NSDictionary,
              let data = preset["data"] as? Data
            else { throw Failure("lsm2 preset has no global parameter state") }
            found.append(
              Preset(path: path, effect: effect, data: data, saved: try presetIDs(data)))
          }
        }
      }
      return found
    }

    /// Whether any lsm2 preset lacks a base ID.
    static func needsFill(_ files: [String: Data]) -> Bool {
      ((try? presets(files)) ?? []).contains { !baseIDs.subtracting($0.saved).isEmpty }
    }

    /// Binds every AID/Common source file byte for byte, so a capture is
    /// never reused after a strip, propstrip or referenced plist changes.
    static func configurationDigest(_ files: [String: Data], aid: String) -> String {
      var hash = SHA256()
      hash.update(data: Data("aurora-lsm2-configuration-v1".utf8) + Data([0]))
      for path in files.keys.sorted(by: NativePythonEncoding.precedes)
      where path.hasPrefix(aid + "/") || path.hasPrefix("Common/") {
        let data = files[path] ?? Data()
        hash.update(data: Data(path.utf8) + Data([0]))
        var length = UInt64(data.count).littleEndian
        hash.update(data: Data(bytes: &length, count: 8))
        hash.update(data: data)
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ value: String) -> Bool {
      value.utf8.count == 64
        && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: Collection

    struct Parameter: Codable, Equatable, Sendable {
      let id: UInt32
      let name: String
      let bits: UInt32
    }

    struct Readback: Codable, Equatable, Sendable {
      let unitVersion: UInt32
      let componentSHA256: String
      let published: [Parameter]

      enum CodingKeys: String, CodingKey {
        case unitVersion = "unit_version"
        case componentSHA256 = "component_sha256"
        case published
      }
    }

    /// Reads one strip's published parameters: (bundle-relative strip, its
    /// lsm2 effect, the bundle's AID/Common files).
    typealias Reader = (String, NSDictionary, [String: Data]) throws -> Readback

    /// The fill for the short presets among `files` (the bundle's AID and
    /// Common files), or nil when no preset is short. Only missing IDs may
    /// supply the fill; a saved ID outside the base schema must be in the
    /// append map and published by the running unit.
    static func collect(
      _ files: [String: Data], aid: String, build: String, unit: String?, readback: Reader
    ) throws -> Data? {
      let candidates = try presets(files)
      guard candidates.contains(where: { !baseIDs.subtracting($0.saved).isEmpty }) else {
        return nil
      }
      guard let unit, !unit.isEmpty else {
        throw Failure("lsm2 fill requires the collecting Mac's unit identity")
      }
      typealias JSON = NativePythonEncoding.JSON
      var captures = [JSON]()
      var identities = Set<String>()
      for preset in candidates {
        let missing = baseIDs.subtracting(preset.saved)
        if missing.isEmpty { continue }
        let extra = preset.saved.subtracting(baseIDs)
        let unknown = extra.subtracting(extensionIDs)
        guard unknown.isEmpty else {
          throw Failure(
            "short lsm2 preset carries \(unknown.count) saved ID(s) outside the known lsm2 schema: "
              + listed(unknown))
        }
        let result = try readback(preset.path, preset.effect, files)
        var published = [UInt32: UInt32]()
        guard (1...maximumParameters).contains(result.published.count) else {
          throw Failure("invalid lsm2 published parameter list")
        }
        for parameter in result.published {
          guard published[parameter.id] == nil, parameter.name.utf8.count <= 1024 else {
            throw Failure("invalid lsm2 published parameter")
          }
          published[parameter.id] = parameter.bits
        }
        let ids = Set(published.keys)
        guard missing.isSubset(of: ids) else {
          throw Failure(
            "AudioUnit did not publish \(missing.subtracting(ids).count) missing lsm2 ID(s): "
              + listed(missing.subtracting(ids)))
        }
        guard extra.isSubset(of: ids) else {
          throw Failure(
            "AudioUnit does not publish \(extra.subtracting(ids).count) saved lsm2 ID(s): "
              + listed(extra.subtracting(ids)))
        }
        guard missing.allSatisfy({ Float(bitPattern: published[$0] ?? 0).isFinite }) else {
          throw Failure("lsm2 fill value is not finite")
        }
        guard validDigest(result.componentSHA256) else {
          throw Failure("invalid lsm2 fill capture")
        }
        identities.insert("\(result.unitVersion) \(result.componentSHA256)")
        let records: [JSON] = result.published.map { parameter -> JSON in
          let record: [String: JSON] = [
            "id": .int(parameter.id), "name": .string(parameter.name), "bits": .int(parameter.bits),
          ]
          return .object(record)
        }
        let fillIDs: [JSON] = missing.sorted().map { JSON.int($0) }
        let capture: [String: JSON] = [
          "strip": .string(preset.path),
          "preset_sha256": .string(NativeStubFileStore.hash(preset.data)),
          "unit_version": .int(result.unitVersion),
          "component_sha256": .string(result.componentSHA256),
          "published": .array(records),
          "fill_ids": .array(fillIDs),
        ]
        captures.append(.object(capture))
      }
      guard captures.count <= maximumCaptures else {
        throw Failure("invalid lsm2 fill capture list")
      }
      guard identities.count == 1 else { throw Failure("lsm2 fill captures name different units") }
      let document: [String: JSON] = [
        "version": .int(version), "format": .string(format), "aid": .string(aid),
        "macos_build": .string(build), "unit_id": .string(unit),
        "configuration_sha256": .string(configurationDigest(files, aid: aid)),
        "presets": .array(captures),
      ]
      let data = NativePythonEncoding.json(.object(document), pretty: false)
      guard data.count <= maximumBytes else { throw Failure("invalid lsm2 fill size") }
      return data
    }

    private static func integer(_ value: Any?) -> Int64? {
      guard let value, CFGetTypeID(value as AnyObject) == CFNumberGetTypeID(),
        let number = value as? NSNumber, !CFNumberIsFloatType(number as CFNumber)
      else { return nil }
      return number.int64Value
    }

    /// The manifest record of a fill (path, size, SHA-256, layout, identity
    /// and the sorted unit versions), after checking it names this bundle:
    /// its AID, build and unit, and the configuration of `files`.
    static func record(
      _ data: Data, aid: String, build: String, unit: String?, files: [String: Data]
    ) throws -> NativePythonEncoding.JSON {
      guard (1...maximumBytes).contains(data.count),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw Failure("invalid lsm2 fill size") }
      guard let unit, !unit.isEmpty, integer(object["version"]) == Int64(version),
        object["format"] as? String == format, object["aid"] as? String == aid,
        object["macos_build"] as? String == build, object["unit_id"] as? String == unit
      else { throw Failure("lsm2 fill identity differs from its bundle") }
      guard object["configuration_sha256"] as? String == configurationDigest(files, aid: aid) else {
        throw Failure("lsm2 fill source configuration changed")
      }
      guard let captures = object["presets"] as? [[String: Any]],
        (1...maximumCaptures).contains(captures.count)
      else { throw Failure("invalid lsm2 fill capture list") }
      var versions = Set<Int64>()
      for capture in captures {
        guard let reported = integer(capture["unit_version"]),
          (0...Int64(UInt32.max)).contains(reported)
        else { throw Failure("invalid lsm2 fill capture") }
        versions.insert(reported)
      }
      typealias JSON = NativePythonEncoding.JSON
      let unitVersions: [JSON] = versions.sorted().map { JSON.integer($0) }
      let record: [String: JSON] = [
        "path": .string(name), "bytes": .int(data.count),
        "sha256": .string(NativeStubFileStore.hash(data)), "version": .int(version),
        "format": .string(format), "aid": .string(aid), "macos_build": .string(build),
        "unit_id": .string(unit), "unit_versions": .array(unitVersions),
      ]
      return .object(record)
    }

    // MARK: The isolated readback

    /// A reader that runs each readback in `executable` (the helper, which
    /// answers `NativeLSM2FillWorker.argument`), over pipes, within
    /// `timeout`. Its standard error is never read: a system component may
    /// print parameter values.
    static func isolated(_ executable: URL) -> Reader {
      { path, effect, files in
        let request = try PropertyListSerialization.data(
          fromPropertyList: ["path": path, "effect": effect, "files": files] as NSDictionary,
          format: .binary, options: 0)
        let output = try run(executable, input: request)
        do {
          return try JSONDecoder().decode(Readback.self, from: output)
        } catch {
          throw Failure("lsm2 parameter readback answered malformed data")
        }
      }
    }

    private final class Output: @unchecked Sendable {
      private let lock = NSLock()
      private var data = Data()
      private var over = false
      let done = DispatchSemaphore(value: 0)

      func read(_ descriptor: Int32, limit: Int) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
          let count = Darwin.read(descriptor, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          lock.lock()
          data.append(contentsOf: buffer[0..<count])
          if data.count > limit { over = true }
          let stop = over
          lock.unlock()
          if stop { break }
        }
        done.signal()
      }

      var result: (data: Data, over: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, over)
      }
    }

    private static func run(_ executable: URL, input: Data) throws -> Data {
      try Task.checkCancellation()
      let process = Process()
      process.executableURL = executable
      process.arguments = [NativeLSM2FillWorker.argument]
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
      let standardInput = Pipe()
      let standardOutput = Pipe()
      process.standardInput = standardInput
      process.standardOutput = standardOutput
      process.standardError = FileHandle.nullDevice
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      // A worker that dies early must not end the helper with SIGPIPE.
      let writer = standardInput.fileHandleForWriting
      _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
      try process.run()
      let output = Output()
      let reader = standardOutput.fileHandleForReading
      DispatchQueue.global().async { output.read(reader.fileDescriptor, limit: maximumBytes) }
      DispatchQueue.global().async {
        try? writer.write(contentsOf: input)
        try? writer.close()
      }
      let deadline = DispatchTime.now() + timeout
      var stopped: String?
      while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
        if Task.isCancelled || DispatchTime.now() >= deadline || output.result.over {
          stopped = Task.isCancelled ? "cancelled" : output.result.over ? "over" : "timeout"
          process.terminate()
          if exited.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .seconds(2))
          }
          break
        }
      }
      _ = output.done.wait(timeout: .now() + .seconds(5))
      switch stopped {
      case "cancelled": throw CancellationError()
      case "timeout": throw Failure("lsm2 parameter readback timed out")
      case "over": throw Failure("lsm2 parameter readback over budget")
      default: break
      }
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw Failure("lsm2 parameter readback failed (exit \(process.terminationStatus))")
      }
      let result = output.result
      guard !result.over else { throw Failure("lsm2 parameter readback over budget") }
      return result.data
    }

    // MARK: Hosting the unit (worker process only)

    /// SHA-256 of the component executable that provides the unit; with the
    /// macOS build it names the exact unit code that was read.
    static func componentDigest(_ path: String = componentPath) throws -> String {
      guard let handle = FileHandle(forReadingAtPath: path) else {
        throw Failure("lsm2 component unreadable")
      }
      defer { try? handle.close() }
      var hash = SHA256()
      while true {
        guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
        hash.update(data: chunk)
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The version the running unit reports: ClassInfo `auversion` when the
    /// unit writes it, or the registry version of a found component. When
    /// both exist they must agree; 0 when neither does. ClassInfo
    /// `version` is the preset format version and identifies nothing.
    static func unitVersion(_ classInfo: NSDictionary, registry: UInt32) throws -> UInt32 {
      var reported: UInt32 = 0
      if let value = classInfo["auversion"] {
        guard let number = integer(value), (0...Int64(UInt32.max)).contains(number) else {
          throw Failure("lsm2 reported a malformed unit version")
        }
        reported = UInt32(number)
      }
      let versions = Set([reported, registry].filter { $0 != 0 })
      guard versions.count <= 1 else {
        throw Failure("lsm2 ClassInfo and registry versions disagree")
      }
      return versions.first ?? 0
    }

    private static func check(_ status: OSStatus) throws {
      guard status == noErr else {
        throw Failure("lsm2 public AudioUnit API failed (OSStatus \(status))")
      }
    }

    private static func fourCC(_ value: Any?) throws -> UInt32 {
      guard let number = integer(value), (0...Int64(UInt32.max)).contains(number) else {
        throw Failure("malformed lsm2 unit description")
      }
      return UInt32(number)
    }

    /// Hosts the installed unit and reads every published parameter. Only
    /// the worker process calls this.
    static func readParameters(path: String, effect: NSDictionary, files: [String: Data]) throws
      -> Readback
    {
      let componentSHA256 = try componentDigest()
      guard let unit = effect["unit"] as? NSDictionary,
        let preset = effect["aupreset"] as? NSDictionary
      else { throw Failure("malformed lsm2 effect") }
      var description = AudioComponentDescription(
        componentType: try fourCC(unit["type"]), componentSubType: try fourCC(unit["subtype"]),
        componentManufacturer: try fourCC(unit["manufacturer"]), componentFlags: 0,
        componentFlagsMask: 0)
      var found = AudioComponentFindNext(nil, &description)
      var registry: UInt32 = 0
      if let found {
        try check(AudioComponentGetVersion(found, &registry))
      } else {
        // This system effect may not be in the discoverable registry: its
        // standard exported AUv2 factory is registered in this process
        // only, never patched. Register's version (0) is a placeholder.
        guard let library = dlopen(componentPath, RTLD_NOW | RTLD_LOCAL),
          let symbol = dlsym(library, factorySymbol)
        else { throw Failure("could not load the system lsm2 AudioUnit") }
        let factory = unsafeBitCast(symbol, to: AudioComponentFactoryFunction.self)
        found = AudioComponentRegister(
          &description, "Owner-local lsm2 collector" as CFString, 0, factory)
      }
      guard let component = found else {
        throw Failure("could not register the system lsm2 AudioUnit")
      }
      var created: AudioComponentInstance?
      try check(AudioComponentInstanceNew(component, &created))
      guard let instance = created else { throw Failure("could not instantiate lsm2") }
      defer { _ = AudioComponentInstanceDispose(instance) }

      var classInfo: CFPropertyList = preset
      try check(
        AudioUnitSetProperty(
          instance, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo,
          UInt32(MemoryLayout<CFPropertyList>.size)))
      try applyProperties(instance, path: path, effect: effect, files: files)

      var returned: UnsafeMutableRawPointer?
      var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
      try check(
        AudioUnitGetProperty(
          instance, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &returned, &size))
      guard let pointer = returned else { throw Failure("lsm2 did not return ClassInfo") }
      let reported = Unmanaged<CFPropertyList>.fromOpaque(pointer).takeRetainedValue()
      guard let reportedInfo = reported as? NSDictionary else {
        throw Failure("lsm2 ClassInfo cannot be serialized")
      }
      let version = try unitVersion(reportedInfo, registry: registry)

      var listSize: UInt32 = 0
      try check(
        AudioUnitGetPropertyInfo(
          instance, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &listSize, nil))
      guard listSize > 0, listSize % 4 == 0, listSize <= UInt32(maximumParameters * 4) else {
        throw Failure("invalid lsm2 published parameter count")
      }
      var ids = [AudioUnitParameterID](repeating: 0, count: Int(listSize / 4))
      try check(
        AudioUnitGetProperty(
          instance, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &listSize))
      ids = Array(ids.prefix(Int(listSize / 4)))

      var published = [Parameter]()
      for id in ids {
        var info = AudioUnitParameterInfo()
        var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
        try check(
          AudioUnitGetProperty(
            instance, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info,
            &infoSize))
        let flags = unsafeBitCast(info.flags, to: UInt32.self)
        let hasName = flags & (1 << 27) != 0  // kAudioUnitParameterFlag_HasCFNameString
        defer {
          // The SDK says to release these only with kAudioUnitParameterFlag_CFNameRelease.
          if flags & (1 << 4) != 0 {
            if hasName { info.cfNameString?.release() }
            // kAudioUnitParameterUnit_CustomUnit
            if unsafeBitCast(info.unit, to: UInt32.self) == 26 { info.unitName?.release() }
          }
        }
        var nameBytes = withUnsafeBytes(of: info.name) { Array($0.prefix { $0 != 0 }) }
        if hasName, let text = info.cfNameString?.takeUnretainedValue() {
          var buffer = [CChar](repeating: 0, count: 1025)
          guard
            CFStringGetCString(text, &buffer, buffer.count, CFStringBuiltInEncodings.UTF8.rawValue)
          else { throw Failure("lsm2 parameter name is too long") }
          nameBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        }
        var value: AudioUnitParameterValue = 0
        try check(AudioUnitGetParameter(instance, id, kAudioUnitScope_Global, 0, &value))
        published.append(
          Parameter(
            id: id, name: String(decoding: nameBytes, as: UTF8.self), bits: value.bitPattern))
      }
      return Readback(unitVersion: version, componentSHA256: componentSHA256, published: published)
    }

    /// The propstrip's properties for this effect's box, applied after the
    /// ClassInfo: UInt32 values, and property lists named by `Path`
    /// (relative to the AID, or to the Tunings root for `AID…`/`Common/`).
    private static func applyProperties(
      _ instance: AudioUnit, path: String, effect: NSDictionary, files: [String: Data]
    ) throws {
      let propertiesPath = String(path.dropLast(".austrip".count)) + ".propstrip"
      guard let source = files[propertiesPath] else { return }
      guard
        let root = try PropertyListSerialization.propertyList(from: source, format: nil)
          as? NSDictionary
      else { throw Failure("malformed lsm2 propstrip") }
      let display = effect["displayname"] as? String
      for box in try list(root["Boxes"]) {
        guard let box = box as? NSDictionary else { throw Failure("malformed lsm2 propstrip") }
        guard let name = box["Name"] as? String, name == display else { continue }
        for property in try list(box["Properties"]) {
          guard let property = property as? NSDictionary else {
            throw Failure("malformed lsm2 propstrip")
          }
          let number = property["Number"] ?? property["PropertyID"]
          guard let id = number as? NSNumber, CFGetTypeID(id) == CFNumberGetTypeID(),
            id.doubleValue == id.doubleValue.rounded(), id.doubleValue >= 0,
            id.doubleValue <= Double(UInt32.max)
          else { throw Failure("invalid lsm2 property ID") }
          let scope = UInt32(truncatingIfNeeded: integer(property["Scope"] ?? 0) ?? 0)
          let element = UInt32(truncatingIfNeeded: integer(property["Element"] ?? 0) ?? 0)
          let identifier = AudioUnitPropertyID(id.doubleValue)
          if let raw = property["UInt32"] {
            guard let wide = integer(raw) else { throw Failure("invalid lsm2 property value") }
            var value = UInt32(truncatingIfNeeded: wide)
            try check(AudioUnitSetProperty(instance, identifier, scope, element, &value, 4))
          } else if let reference = property["Path"] as? String {
            var target = reference
            let prefix = "/System/Library/Audio/Tunings/"
            if target.hasPrefix(prefix) { target = String(target.dropFirst(prefix.count)) }
            if !(target.hasPrefix("AID") || target.hasPrefix("Common/")) {
              target =
                String(path.split(separator: "/", omittingEmptySubsequences: false)[0]) + "/"
                + target
            }
            guard let data = files[target] else {
              throw Failure("lsm2 property path is outside the private bundle")
            }
            var value: CFPropertyList =
              try PropertyListSerialization.propertyList(from: data, format: nil) as CFPropertyList
            try check(
              AudioUnitSetProperty(
                instance, identifier, scope, element, &value,
                UInt32(MemoryLayout<CFPropertyList>.size)))
          } else {
            throw Failure("unsupported lsm2 propstrip property type")
          }
        }
      }
    }
  }

  /// The readback worker: the installer helper started again with
  /// `argument` reads one request (a binary property list with the strip
  /// path, its effect and the bundle files) from standard input, hosts the
  /// unit, and writes the published parameters as JSON to standard output.
  /// It accepts no paths or options and writes no files.
  public enum NativeLSM2FillWorker {
    public static let argument = "--lsm2-readback"

    /// Makes this executable the readback worker for its own collections.
    public static func useCurrentExecutable() {
      NativeLSM2Fill.workerExecutable =
        Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    /// Runs the worker when `arguments` ask for it; returns its exit
    /// status, or nil when this is not a worker start.
    public static func run(_ arguments: [String] = CommandLine.arguments) -> Int32? {
      guard arguments.count == 2, arguments[1] == argument else { return nil }
      do {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
          let count = read(STDIN_FILENO, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          request.append(contentsOf: buffer[0..<count])
          guard request.count <= 68 << 20 else { return 1 }
        }
        guard
          let object = try PropertyListSerialization.propertyList(from: request, format: nil)
            as? NSDictionary,
          let path = object["path"] as? String, let effect = object["effect"] as? NSDictionary,
          let files = object["files"] as? [String: Data]
        else { return 1 }
        let response = try NativeLSM2Fill.readParameters(path: path, effect: effect, files: files)
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
        return 0
      } catch {
        return 1
      }
    }
  }
#endif
