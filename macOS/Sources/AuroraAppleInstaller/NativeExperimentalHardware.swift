#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// How far an experimental installation goes on a Mac this release does not
  /// support. The owner picks it; it is never inferred.
  public enum ExperimentalHardwareLevel: String, Codable, CaseIterable, Sendable {
    /// aura Stage 1 and Stage 2 with the USB proxy window on every boot, for
    /// bring-up from a host. The distribution is not booted.
    case bootloaderOnly = "bootloader-only"
    /// The bootloader plus the chosen distribution, with this board's device
    /// tree or the closest one on the same chip.
    case fullSend = "full-send"
  }

  public enum NativeExperimentalHardwareError: Error, Equatable, Sendable {
    /// The Mac is supported, so the experimental path is never offered.
    case supported
    /// No stub firmware this Mac's boot firmware, macOS and recovery accept.
    case noFirmware
    case invalidDeviceTree
  }

  /// Where an experimental installation's Stage 2 comes from.
  public enum ExperimentalStage2Source: Equatable, Sendable {
    /// The payload carries a board file whose device tree names this board.
    case own(member: String)
    /// No tree for this board; the closest board on the same chip, with its
    /// root compatible extended so aura matches this board's ADT.
    case sibling(board: String, member: String)
    /// No tree on this chip at all: the combined Stage 2, which still brings
    /// up the proxy window but finds no device tree to boot Linux with.
    case none
  }

  /// The decision an experimental installation runs on. Nothing here touches a
  /// disk: the planner, the space refusals and the 1TR step are the same ones a
  /// supported Mac gets, run against `policy`.
  public struct NativeExperimentalAssessment: Sendable {
    public let deviceIdentifier: String
    public let chipID: UInt64
    public let requestedLevel: ExperimentalHardwareLevel
    /// Equal to `requestedLevel`, except that Full send with no device tree on
    /// this chip falls back to Bootloader only.
    public let level: ExperimentalHardwareLevel
    public let firmwareVersion: String
    /// What would block a supported Mac but is only a warning here.
    public let warnings: [String]
    let policy: NativeInspectionPolicy
  }

  enum NativeExperimentalHardware {
    /// The ESP root file aura 1.0.0b1 Stage 1 reads to hold a 15 s proxy
    /// window on every boot (aura docs/boot-options.md). Deleting it turns the
    /// window off without enrolling Stage 1 again.
    static let proxyMarker = "aura-proxy"
    /// The installation's own record of what was installed and why.
    static let recordPath = "aurora/experimental.json"

    static func isSupported(
      _ deviceIdentifier: String, hardware: NativeInspectionHardware,
      policy: NativeInspectionPolicy
    ) -> Bool {
      !AppleSiliconHostInspector.isExplicitlyUnsupported(deviceIdentifier)
        && policy.supports(deviceIdentifier, hardware: hardware)
    }

    /// Why the experimental path is not offered, or nil when it is.
    static func refusal(
      _ deviceIdentifier: String, hardware: NativeInspectionHardware,
      policy: NativeInspectionPolicy
    ) -> NativeExperimentalHardwareError? {
      // Ryan, 2026-10-30: M1 to M3 and the A18 Pro are supported, newer Macs
      // are not. A supported Mac whose iBoot may refuse the Stage 1 (the M1
      // Pro, Max and Ultra) is warned in the normal path, never sent here, so
      // the only refusal is a supported Mac.
      isSupported(deviceIdentifier, hardware: hardware, policy: policy) ? .supported : nil
    }

    static func assess(
      _ deviceIdentifier: String, hardware: NativeInspectionHardware,
      policy: NativeInspectionPolicy, metadata: NativeInstallationMetadata,
      level: ExperimentalHardwareLevel
    ) throws -> NativeExperimentalAssessment {
      if let refusal = refusal(deviceIdentifier, hardware: hardware, policy: policy) {
        throw refusal
      }
      guard deviceIdentifier.hasPrefix("apple,"),
        deviceIdentifier.range(of: #"\Aapple,j[0-9]+[a-z]*\z"#, options: .regularExpression)
          != nil
      else { throw NativeExperimentalHardwareError.noFirmware }
      let board = String(deviceIdentifier.dropFirst(6))
      var warnings = [String]()
      let chipKey = String(hardware.chipID)
      let chipMinimum = policy.chipMinimum[chipKey]
      if chipMinimum == nil {
        warnings.append(
          "The chip (0x\(String(hardware.chipID, radix: 16))) is not in this release's inspection policy."
        )
      } else if policy.devices[board] == nil
        || AppleSiliconHostInspector.isExplicitlyUnsupported(deviceIdentifier)
      {
        warnings.append(
          "This board is not in this release's inspection policy; its chip is.")
      }
      let firmware = try firmware(
        hardware: hardware, policy: policy, metadata: metadata, chipMinimum: chipMinimum)
      if let models = firmware.models, !models.contains(board) {
        warnings.append("The macOS \(firmware.version) stub is not listed for this board.")
      }
      warnings.append("aura Stage 1 has not been booted on this board.")
      var chips = policy.chipMinimum
      chips[chipKey] = chipMinimum ?? firmware.version
      var devices = policy.devices
      devices[board] = .init(minimum: firmware.version, expert: false)
      let entries = policy.firmware.map { entry -> NativeInspectionPolicy.Firmware in
        guard entry.version == firmware.version, let models = entry.models else { return entry }
        return .init(
          version: entry.version, minimumMacOS: entry.minimumMacOS,
          minimumBoot: entry.minimumBoot, minimumRecovery: entry.minimumRecovery,
          expert: entry.expert, models: models.contains(board) ? models : models + [board],
          sourceURL: entry.sourceURL)
      }
      let widened = NativeInspectionPolicy(
        runtimeVersion: policy.runtimeVersion, sourceSHA256: policy.sourceSHA256,
        chipMinimum: chips, devices: devices, firmware: entries,
        baselineMetadata: policy.baselineMetadata)
      return NativeExperimentalAssessment(
        deviceIdentifier: deviceIdentifier, chipID: hardware.chipID, requestedLevel: level,
        level: level, firmwareVersion: firmware.version, warnings: warnings, policy: widened)
    }

    /// The newest non-expert stub firmware this Mac's boot firmware, macOS and
    /// recovery accept, whatever models it lists. The restore manifest's own
    /// DeviceClass check still has to find this board before any disk change.
    static func firmware(
      hardware: NativeInspectionHardware, policy: NativeInspectionPolicy,
      metadata: NativeInstallationMetadata, chipMinimum: String?
    ) throws -> NativeInspectionPolicy.Firmware {
      guard let boot = hardware.bootVersion, let macOS = hardware.macOSVersion,
        let recovery = hardware.recoveryVersion
      else { throw NativeExperimentalHardwareError.noFirmware }
      let target = try metadata.target()
      var selected: NativeInspectionPolicy.Firmware?
      for entry in policy.firmware where !entry.expert {
        guard target.supportedFirmware?.contains(entry.version) ?? true,
          try chipMinimum.map({ try NativeInspectionPolicy.Version.atLeast(entry.version, $0) })
            ?? true,
          try NativeInspectionPolicy.Version.atLeast(boot, entry.minimumBoot),
          try NativeInspectionPolicy.Version.atLeast(macOS, entry.minimumMacOS),
          try NativeInspectionPolicy.Version.atLeast(recovery, entry.minimumRecovery)
        else { continue }
        if try selected.map({
          try !NativeInspectionPolicy.Version.atLeast($0.version, entry.version)
        })
          ?? true
        {
          selected = entry
        }
      }
      guard let selected else { throw NativeExperimentalHardwareError.noFirmware }
      return selected
    }

    // MARK: Stage 2

    /// Chooses this board's own Stage 2 file, else the closest board file on
    /// the same chip. `boardFiles` maps each `esp/m1n1/boot-*.bin` member to the
    /// root compatible lists of the device trees it carries.
    static func stage2Source(
      deviceIdentifier: String, chipID: UInt64, boardFiles: [String: [[String]]]
    ) -> ExperimentalStage2Source {
      let board = String(deviceIdentifier.dropFirst(6))
      let own = "esp/m1n1/boot-\(board).bin"
      if let trees = boardFiles[own], trees.contains(where: { $0.first == deviceIdentifier }) {
        return .own(member: own)
      }
      let chip = "apple," + chipName(chipID)
      let siblings = boardFiles.compactMap { member, trees -> (String, String)? in
        guard let tree = trees.first(where: { $0.contains(chip) }), let first = tree.first,
          first.hasPrefix("apple,j"), first != deviceIdentifier
        else { return nil }
        return (String(first.dropFirst(6)), member)
      }
      // Prefer the board with the same family suffix (j614s -> j616s), then
      // the nearest board number, then name order, so the choice is stable.
      let suffix = board.drop(while: { $0 == "j" || $0.isNumber })
      let number = Int(board.dropFirst().prefix(while: \.isNumber)) ?? 0
      let best = siblings.min { a, b in
        func key(_ s: String) -> (Int, Int, String) {
          let n = Int(s.dropFirst().prefix(while: \.isNumber)) ?? 0
          return (s.drop(while: { $0 == "j" || $0.isNumber }) == suffix ? 0 : 1, abs(n - number), s)
        }
        return key(a.0) < key(b.0)
      }
      if let best { return .sibling(board: best.0, member: best.1) }
      return .none
    }

    static func chipName(_ chipID: UInt64) -> String {
      "t" + String(format: "%04x", chipID)
    }

    /// The device trees a Stage 2 board file carries, as root compatible lists.
    static func deviceTrees(inStage2 data: Data) -> [[String]] {
      let bytes = [UInt8](data)
      guard let marker = data.range(of: Data("STACKBOT".utf8), options: .backwards) else {
        return []
      }
      var position = marker.upperBound
      var trees = [[String]]()
      while position + 8 <= bytes.count {
        if bytes[position] == 0 {
          position += 1
          continue
        }
        guard bytes[position..<(position + 4)].elementsEqual([0xd0, 0x0d, 0xfe, 0xed]) else {
          break
        }
        let size = Int(be32(bytes, position + 4))
        guard size >= 40, position + size <= bytes.count,
          let tree = try? NativeFDT(Array(bytes[position..<(position + size)]))
        else { break }
        trees.append(tree.rootCompatible)
        position += size
      }
      return trees
    }

    /// The sibling board file with each matching tree's root compatible
    /// extended to name this board first, so aura's ADT match finds it.
    static func retarget(stage2 data: Data, sibling: String, deviceIdentifier: String) throws
      -> Data
    {
      let bytes = [UInt8](data)
      guard let marker = data.range(of: Data("STACKBOT".utf8), options: .backwards) else {
        throw NativeExperimentalHardwareError.invalidDeviceTree
      }
      var output = Array(bytes[..<marker.upperBound])
      var position = marker.upperBound
      var changed = 0
      while position + 8 <= bytes.count {
        if bytes[position] == 0 {
          output.append(0)
          position += 1
          continue
        }
        guard bytes[position..<(position + 4)].elementsEqual([0xd0, 0x0d, 0xfe, 0xed]) else {
          break
        }
        let size = Int(be32(bytes, position + 4))
        guard size >= 40, position + size <= bytes.count else {
          throw NativeExperimentalHardwareError.invalidDeviceTree
        }
        var tree = try NativeFDT(Array(bytes[position..<(position + size)]))
        if tree.rootCompatible.first == "apple," + sibling {
          tree.rootCompatible = [deviceIdentifier] + tree.rootCompatible
          changed += 1
        }
        output += tree.encoded()
        position += size
      }
      guard changed > 0 else { throw NativeExperimentalHardwareError.invalidDeviceTree }
      output += bytes[position...]
      return Data(output)
    }

    // MARK: Record and report

    static func record(
      _ assessment: NativeExperimentalAssessment, stage2: ExperimentalStage2Source,
      stage1Bytes: Int?, stage1SHA256: String?
    ) throws -> Data {
      var source: [String: Any] = ["kind": "none"]
      switch stage2 {
      case .own(let member): source = ["kind": "own", "member": member]
      case .sibling(let board, let member):
        source = ["kind": "sibling", "board": "apple," + board, "member": member]
      case .none: break
      }
      var value: [String: Any] = [
        "schema": 1, "experimental": true, "device_identifier": assessment.deviceIdentifier,
        "chip_id": "0x" + String(assessment.chipID, radix: 16),
        "requested_level": assessment.requestedLevel.rawValue, "level": assessment.level.rawValue,
        "stub_firmware": assessment.firmwareVersion, "stage2_source": source,
        "proxy_marker": assessment.level == .bootloaderOnly, "warnings": assessment.warnings,
      ]
      if let stage1Bytes { value["stage1_bytes"] = stage1Bytes }
      if let stage1SHA256 { value["stage1_sha256"] = stage1SHA256 }
      return try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
      bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
  }

  /// The facts a bring-up report records. Everything is read locally and
  /// nothing is sent anywhere.
  public struct ExperimentalBringUpFacts: Sendable {
    public var model: String
    public var deviceIdentifier: String
    public var chipID: UInt64
    public var systemBoot: String?
    public var systemMacOS: String?
    public var stubBoot: String?
    public var stubMacOS: String?
    public var level: ExperimentalHardwareLevel
    public var stage2: String
    public var stage1: String?
    public var warnings: [String]

    public init(
      model: String, deviceIdentifier: String, chipID: UInt64, systemBoot: String?,
      systemMacOS: String?, stubBoot: String?, stubMacOS: String?,
      level: ExperimentalHardwareLevel, stage2: String, stage1: String?, warnings: [String]
    ) {
      self.model = model
      self.deviceIdentifier = deviceIdentifier
      self.chipID = chipID
      self.systemBoot = systemBoot
      self.systemMacOS = systemMacOS
      self.stubBoot = stubBoot
      self.stubMacOS = stubMacOS
      self.level = level
      self.stage2 = stage2
      self.stage1 = stage1
      self.warnings = warnings
    }

    /// Plain text the owner can paste into a bug report.
    public var report: String {
      var lines = [
        "Aurora experimental hardware bring-up report",
        "",
        "Model: \(model)",
        "Board: \(deviceIdentifier)",
        "Chip ID: 0x\(String(chipID, radix: 16))",
        "System iBoot: \(systemBoot ?? "unknown")",
        "System macOS: \(systemMacOS ?? "unknown")",
        "Stub iBoot: \(stubBoot ?? "not installed yet")",
        "Stub macOS: \(stubMacOS ?? "not installed yet")",
        "Level: \(level.rawValue)",
        "Stage 1: \(stage1 ?? "not chosen yet")",
        "Stage 2: \(stage2)",
        "ESP files: aura Stage 2 at m1n1/boot.bin, this record at \(NativeExperimentalHardware.recordPath)",
      ]
      if level == .bootloaderOnly {
        lines.append(
          "Proxy window: \(NativeExperimentalHardware.proxyMarker) at the ESP root holds Stage 1 for 15 s on every boot. Delete it to boot straight through."
        )
      }
      lines += [
        "",
        "Logs: aura Stage 1 and Stage 2 print to the screen. A host connected over USB-C during the proxy window gets the aura proxy and its console.",
        "Host: connect a USB-C cable to another computer, start the Mac, then within the window run",
        "  python3 proxyclient/tools/shell.py",
        "from an aura checkout (M1N1DEVICE=/dev/cu.usbmodem<…> on macOS, /dev/ttyACM0 on Linux).",
        "Nothing in this report was sent anywhere.",
      ]
      if !warnings.isEmpty {
        lines += ["", "Untested on this Mac:"] + warnings.map { "- " + $0 }
      }
      return lines.joined(separator: "\n") + "\n"
    }
  }

  /// A minimal flattened device tree reader and writer: enough to read and
  /// replace the root node's compatible list, keeping everything else.
  struct NativeFDT {
    private var reservations: [UInt8]
    private var structure: [UInt8]
    private var strings: [UInt8]
    private let version: UInt32
    private let lastCompatible: UInt32
    private let bootCPU: UInt32
    private var compatibleRange: Range<Int>?

    init(_ blob: [UInt8]) throws {
      func word(_ offset: Int) throws -> Int {
        guard offset + 4 <= blob.count else {
          throw NativeExperimentalHardwareError.invalidDeviceTree
        }
        return Int(blob[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
      }
      guard try word(0) == 0xd00d_feed, try word(4) == blob.count else {
        throw NativeExperimentalHardwareError.invalidDeviceTree
      }
      let structOffset = try word(8)
      let stringsOffset = try word(12)
      let reserveOffset = try word(16)
      version = UInt32(try word(20))
      lastCompatible = UInt32(try word(24))
      bootCPU = UInt32(try word(28))
      let stringsSize = try word(32)
      let structSize = try word(36)
      guard reserveOffset >= 40, reserveOffset <= structOffset,
        structOffset + structSize <= blob.count, stringsOffset + stringsSize <= blob.count
      else { throw NativeExperimentalHardwareError.invalidDeviceTree }
      reservations = Array(blob[reserveOffset..<structOffset])
      structure = Array(blob[structOffset..<(structOffset + structSize)])
      strings = Array(blob[stringsOffset..<(stringsOffset + stringsSize)])
      // Find the root node's compatible property.
      var cursor = 0
      func token() throws -> Int {
        let value = try Self.read(structure, cursor)
        cursor += 4
        return value
      }
      while try Self.read(structure, cursor) == 4 { cursor += 4 }
      guard try token() == 1 else { throw NativeExperimentalHardwareError.invalidDeviceTree }
      guard let end = structure[cursor...].firstIndex(of: 0) else {
        throw NativeExperimentalHardwareError.invalidDeviceTree
      }
      cursor = (end + 4) & ~3
      while cursor + 4 <= structure.count {
        let kind = try Self.read(structure, cursor)
        if kind == 4 {
          cursor += 4
          continue
        }
        guard kind == 3 else { break }
        let length = try Self.read(structure, cursor + 4)
        let name = try Self.read(structure, cursor + 8)
        let value = cursor + 12
        guard value + length <= structure.count, name < strings.count,
          let nameEnd = strings[name...].firstIndex(of: 0)
        else { throw NativeExperimentalHardwareError.invalidDeviceTree }
        if strings[name..<nameEnd].elementsEqual(Array("compatible".utf8)) {
          compatibleRange = value..<(value + length)
          break
        }
        cursor = (value + length + 3) & ~3
      }
      guard compatibleRange != nil else { throw NativeExperimentalHardwareError.invalidDeviceTree }
    }

    var rootCompatible: [String] {
      get {
        guard let range = compatibleRange else { return [] }
        return structure[range].split(separator: 0).compactMap {
          String(bytes: $0, encoding: .utf8)
        }
      }
      set {
        guard let range = compatibleRange else { return }
        let value: [UInt8] = newValue.flatMap { Array($0.utf8) + [UInt8(0)] }
        let oldPadded = (range.count + 3) & ~3
        let newPadded = (value.count + 3) & ~3
        let replacement = value + [UInt8](repeating: 0, count: newPadded - value.count)
        let lengthOffset = range.lowerBound - 8
        structure.replaceSubrange(
          range.lowerBound..<(range.lowerBound + oldPadded), with: replacement)
        let length = UInt32(value.count)
        for index in 0..<4 {
          structure[lengthOffset + index] = UInt8(truncatingIfNeeded: length >> (24 - 8 * index))
        }
        compatibleRange = range.lowerBound..<(range.lowerBound + value.count)
      }
    }

    func encoded() -> [UInt8] {
      let reserveOffset = 40
      let structOffset = reserveOffset + reservations.count
      let stringsOffset = structOffset + structure.count
      let total = stringsOffset + strings.count
      var header = [UInt8]()
      for value in [
        0xd00d_feed, UInt32(total), UInt32(structOffset), UInt32(stringsOffset),
        UInt32(reserveOffset), version, lastCompatible, bootCPU, UInt32(strings.count),
        UInt32(structure.count),
      ] as [UInt32] {
        header += (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
      }
      return header + reservations + structure + strings
    }

    private static func read(_ bytes: [UInt8], _ offset: Int) throws -> Int {
      guard offset >= 0, offset + 4 <= bytes.count else {
        throw NativeExperimentalHardwareError.invalidDeviceTree
      }
      return Int(bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
  }
#endif

#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// The boot chain an experimental installation would write. Like
  /// `NativeBootChainAdmission`, it is computed from the payload alone.
  struct NativeExperimentalBootChain: Sendable {
    let assessment: NativeExperimentalAssessment
    let stage1Member: String
    let stage1Bytes: Int
    let stage1SHA256: String
    let stage2: ExperimentalStage2Source
    /// The Stage 2 bytes to publish at m1n1/boot.bin: the board file as is,
    /// or the sibling's with its root compatible naming this board.
    let stage2Bytes: Int
    let stage2SHA256: String
    /// The rebuilt Stage 2 bytes when they come from a same-chip sibling;
    /// nil when the payload's own member is copied as it is.
    let stage2Override: Data?
    /// Root compatible lists of the trees in the Stage 2 that is published.
    let stage2Trees: [[String]]
    let espLayout: [String: String]
    /// Files written to the ESP besides the payload's: the proxy marker
    /// (Bootloader only) and the experimental record.
    let extraFiles: [String: Data]
    let notes: [String]

    static func admit(
      metadata: Data, archive: IPSWArchive, assessment: NativeExperimentalAssessment
    ) async throws -> Self {
      let template = try NativePayloadPreflight.target(metadata)
      let members = Dictionary(
        uniqueKeysWithValues: archive.members.filter { !$0.isDirectory }.map { ($0.name, $0) })
      // Stage 1 qualification is a warning here; the common Stage 1 is the only
      // one that is not built for a single board.
      let stage1Member = "esp/aurora/stage1.bin"
      guard let stage1 = members[stage1Member] else { throw NativeBootChainError.missingStage1 }
      let stage1Data = try await archive.read(stage1, maximumBytes: 64 << 20)
      let path = template["next_object"] as? String ?? "m1n1/boot.bin"
      // The config window stays 0: the ESP marker holds the window, so it can
      // be removed later without enrolling Stage 1 again.
      let filled = try NativeBootChain.fillStage1(
        stage1Data, uuid: "00000000-0000-0000-0000-000000000000", path: path,
        windowMilliseconds: 0)
      var boardFiles = [String: [[String]]]()
      for member in members.keys
      where member.hasPrefix("esp/m1n1/boot-") && member.hasSuffix(".bin") {
        guard let entry = members[member], entry.sizeBytes > 64 else { continue }
        let data = try await archive.read(entry, maximumBytes: 64 << 20)
        let trees = NativeExperimentalHardware.deviceTrees(inStage2: data)
        if !trees.isEmpty { boardFiles[member] = trees }
      }
      let source = NativeExperimentalHardware.stage2Source(
        deviceIdentifier: assessment.deviceIdentifier, chipID: assessment.chipID,
        boardFiles: boardFiles)
      var level = assessment.level
      var notes = [String]()
      let selected: String
      let stage2Data: Data
      switch source {
      case .own(let member):
        selected = member
        stage2Data = try await archive.read(members[member]!, maximumBytes: 64 << 20)
        notes.append("Stage 2 is this board's own file, \(member).")
      case .sibling(let board, let member):
        selected = member
        let original = try await archive.read(members[member]!, maximumBytes: 64 << 20)
        stage2Data = try NativeExperimentalHardware.retarget(
          stage2: original, sibling: board, deviceIdentifier: assessment.deviceIdentifier)
        notes.append(
          "No device tree names this board; Stage 2 uses apple,\(board)'s on the same chip, with this board added to its compatible list."
        )
      case .none:
        selected = "esp/m1n1/boot.bin"
        guard let combined = members[selected] else { throw NativeBootChainError.missingStage2 }
        stage2Data = try await archive.read(combined, maximumBytes: 64 << 20)
        if level == .fullSend {
          level = .bootloaderOnly
          notes.append(
            "No device tree exists for this chip, so Full send falls back to Bootloader only.")
        }
        notes.append("Stage 2 is the combined file; it has no device tree for this board.")
      }
      let effective = NativeExperimentalAssessment(
        deviceIdentifier: assessment.deviceIdentifier, chipID: assessment.chipID,
        requestedLevel: assessment.requestedLevel, level: level,
        firmwareVersion: assessment.firmwareVersion, warnings: assessment.warnings,
        policy: assessment.policy)
      let esp = Set(members.keys.filter { $0.hasPrefix("esp/") })
      let layout = try NativeESPLayout.map(
        deviceIdentifier: assessment.deviceIdentifier, members: esp, commonAllowed: true,
        stage2: selected, stage2Variants: [])
      var extra = [String: Data]()
      if level == .bootloaderOnly {
        extra[NativeExperimentalHardware.proxyMarker] = Data()
      }
      extra[NativeExperimentalHardware.recordPath] = try NativeExperimentalHardware.record(
        effective, stage2: source, stage1Bytes: filled.count,
        stage1SHA256: SHA256Digest(hashing: stage1Data).rawValue)
      guard Set(layout.values).isDisjoint(with: extra.keys) else {
        throw NativeHandoffValidationError.changedContent
      }
      return Self(
        assessment: effective, stage1Member: stage1Member, stage1Bytes: filled.count,
        stage1SHA256: SHA256Digest(hashing: stage1Data).rawValue, stage2: source,
        stage2Bytes: stage2Data.count, stage2SHA256: SHA256Digest(hashing: stage2Data).rawValue,
        stage2Override: { if case .sibling = source { return stage2Data } else { return nil } }(),
        stage2Trees: NativeExperimentalHardware.deviceTrees(inStage2: stage2Data),
        espLayout: layout, extraFiles: extra, notes: notes)
    }
  }
#endif

#if os(macOS)
  import Foundation

  /// The app's read-only view of the experimental hardware decision on the
  /// running Mac, so the UI can offer the choice and save a bring-up report.
  public enum ExperimentalHardwareInspection {
    public enum Availability: Equatable, Sendable {
      case supported
      case refused(String)
      case offered(warnings: [String])
    }

    public static func availability(deviceIdentifier: String) throws -> Availability {
      let policy = try NativeInspectionPolicy.sealed()
      let hardware = try NativeInspectionHardware.live()
      switch NativeExperimentalHardware.refusal(
        deviceIdentifier, hardware: hardware, policy: policy)
      {
      case .supported?: return .supported
      case .some(let other): return .refused(String(describing: other))
      case nil:
        let assessment = try NativeExperimentalHardware.assess(
          deviceIdentifier, hardware: hardware, policy: policy,
          metadata: anyPayload(), level: .bootloaderOnly)
        return .offered(warnings: assessment.warnings)
      }
    }

    /// Before a payload is chosen, check against one that limits no stub
    /// firmware, as current payload metadata does.
    static func anyPayload() throws -> NativeInstallationMetadata {
      try NativeInstallationMetadata(
        data: Data(
          #"{"os_list":[{"omarchy_target":"apple-silicon-full-os","default_os_name":"Aurora","partitions":[{"size":"1GiB"}]}]}"#
            .utf8))
    }

    /// The record the plan will bind, from the decision on the running Mac.
    public static func admission(
      deviceIdentifier: String, level: ExperimentalHardwareLevel
    ) throws -> ExperimentalAdmissionRecord {
      NativeDeviceAdmission.record(
        try NativeExperimentalHardware.assess(
          deviceIdentifier, hardware: NativeInspectionHardware.live(),
          policy: NativeInspectionPolicy.sealed(), metadata: anyPayload(), level: level))
    }

    /// The report for the running Mac, before any payload is chosen: Stage 1
    /// and Stage 2 are named once the payload is prepared.
    public static func report(
      model: String, deviceIdentifier: String, level: ExperimentalHardwareLevel
    ) throws -> ExperimentalBringUpFacts {
      let policy = try NativeInspectionPolicy.sealed()
      let hardware = try NativeInspectionHardware.live()
      let assessment = try NativeExperimentalHardware.assess(
        deviceIdentifier, hardware: hardware, policy: policy,
        metadata: anyPayload(), level: level)
      return ExperimentalBringUpFacts(
        model: model, deviceIdentifier: deviceIdentifier, chipID: hardware.chipID,
        systemBoot: hardware.bootVersion, systemMacOS: hardware.macOSVersion, stubBoot: nil,
        stubMacOS: assessment.firmwareVersion + " (to be installed)", level: level,
        stage2: "chosen when the payload is prepared", stage1: "aura common raw Stage 1",
        warnings: assessment.warnings)
    }
  }
#endif

#if os(macOS)
  import Foundation

  /// Which Macs a plan may run on, and under which policy. A plan without an
  /// experimental record gets exactly the old answer: the sealed policy, and
  /// the explicit refusal list. A plan with one is never taken at its word:
  /// the decision is run again on this Mac and must give the same answer.
  enum NativeDeviceAdmission {
    static func record(_ assessment: NativeExperimentalAssessment)
      -> ExperimentalAdmissionRecord
    {
      ExperimentalAdmissionRecord(
        deviceIdentifier: assessment.deviceIdentifier, chipID: assessment.chipID,
        level: assessment.requestedLevel.rawValue, stubFirmware: assessment.firmwareVersion)
    }

    /// Re-runs the experimental decision on `hardware` and refuses unless it
    /// gives the record's Mac, chip, level and stub.
    static func verify(
      _ record: ExperimentalAdmissionRecord, deviceIdentifier: String,
      hardware: NativeInspectionHardware, policy: NativeInspectionPolicy,
      metadata: NativeInstallationMetadata
    ) throws -> NativeExperimentalAssessment {
      guard record.deviceIdentifier == deviceIdentifier,
        let level = ExperimentalHardwareLevel(rawValue: record.level)
      else { throw ExperimentalAdmissionError.decisionChanged }
      guard
        NativeExperimentalHardware.refusal(
          deviceIdentifier, hardware: hardware, policy: policy) == nil
      else { throw ExperimentalAdmissionError.notOffered }
      guard record.chipID == String(hardware.chipID, radix: 16) else {
        throw ExperimentalAdmissionError.decisionChanged
      }
      let assessment = try NativeExperimentalHardware.assess(
        deviceIdentifier, hardware: hardware, policy: policy, metadata: metadata, level: level)
      guard Self.record(assessment) == record else {
        throw ExperimentalAdmissionError.decisionChanged
      }
      return assessment
    }

    /// The policy a plan runs under on this Mac: the sealed one, unchanged,
    /// without a record; the verified assessment's widened one with it.
    static func policy(
      deviceIdentifier: String, admission: ExperimentalAdmissionRecord?,
      hardware: NativeInspectionHardware, metadata: NativeInstallationMetadata
    ) throws -> NativeInspectionPolicy {
      let sealed = try NativeInspectionPolicy.sealed()
      guard let admission else { return sealed }
      return try verify(
        admission, deviceIdentifier: deviceIdentifier, hardware: hardware, policy: sealed,
        metadata: metadata
      ).policy
    }

    /// Replaces the explicit refusal check. Without a record it is that check.
    /// With one, the decision is re-run on this Mac (stub choice against a
    /// payload that limits no firmware, as current payloads do; the steps that
    /// hold the real metadata check it again).
    static func admits(
      deviceIdentifier: String, admission: ExperimentalAdmissionRecord?,
      hardware: () throws -> NativeInspectionHardware
    ) -> Bool {
      guard let admission else {
        return !AppleSiliconHostInspector.isExplicitlyUnsupported(deviceIdentifier)
      }
      guard let live = try? hardware(), let policy = try? NativeInspectionPolicy.sealed(),
        let any = try? ExperimentalHardwareInspection.anyPayload()
      else { return false }
      return
        (try? verify(
          admission, deviceIdentifier: deviceIdentifier, hardware: live, policy: policy,
          metadata: any)) != nil
    }
  }
#endif
