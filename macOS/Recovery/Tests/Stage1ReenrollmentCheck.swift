import Foundation

/// A staged Stage 1 re-enrolls only after the same checks as setup; nothing
/// here runs bputil or kmutil.
@main struct Stage1ReenrollmentCheck {
  static let base: UInt64 = 0xFFFF_FE00_0700_4000
  static let esp = "3ce364b1-1de6-4418-a00d-5b2d95884ad7"
  static let t8140: UInt64 = 0x8140
  static let t8103: UInt64 = 0x8103

  static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
  }

  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
    }
    return ~crc
  }

  /// aura's Stage 1 configuration block, filled for `uuid` and `path`.
  static func block(uuid: String, path: String) -> [UInt8] {
    let encoded = Array((";" + path).utf8)
    var body = le(UInt32(1)) + le(UInt32(0)) + Array(uuid.utf8)
    body += [UInt8](repeating: 0, count: 4) + encoded
    body += [UInt8](repeating: 0, count: 192 - encoded.count)
    return Array("AURORA-S1-CFG01\0".utf8) + body + le(crc32(body))
  }

  static func raw(uuid: String = esp, path: String) -> Data {
    let code = [UInt8](repeating: 0x5A, count: 0x40)
    return Data(code + block(uuid: uuid, path: path) + code)
  }

  /// A fileset boot object without __TEXT_BOOT_EXEC carrying `raw`.
  static func object(carrying raw: Data) -> Data {
    let segments: [(String, UInt64, UInt64)] = [
      ("__TEXT", 0, 0x8000), ("__TEXT_EXEC", 0x8000, 0x8000), ("__PRELINK_INFO", 0x10000, 0x4000),
      ("__LINKEDIT", 0x14000, 0x4000),
    ]
    var commands: [UInt8] = []
    for (name, offset, size) in segments {
      commands += le(UInt32(0x19)) + le(UInt32(72))
      commands += Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
      commands += le(base + offset) + le(size) + le(offset) + le(size)
      commands += le(UInt32(1)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(0))
    }
    var registers = [UInt64](repeating: 0, count: 34)
    registers[32] = base + 0x8800
    commands += le(UInt32(5)) + le(UInt32(16 + 34 * 8)) + le(UInt32(6)) + le(UInt32(0x44))
    for register in registers { commands += le(register) }
    var bytes = le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0xC000_0002))
    bytes += le(UInt32(12)) + le(UInt32(segments.count + 1)) + le(UInt32(commands.count))
    bytes += le(UInt32(0)) + le(UInt32(0)) + commands
    var data = Data(bytes + [UInt8](repeating: 0, count: 0x18000 - bytes.count))
    data.replaceSubrange(0x8000..<(0x8000 + raw.count), with: raw)
    return data
  }

  static func receipt(stage1: Data, stage2Path: String = "m1n1/boot.bin", mode: String = "macho")
    -> [String: Any]
  {
    [
      "schema": 1, "status": "installed", "mode": mode, "stage2Path": stage2Path,
      "stage1SHA256": RecoveryDigest.sha256(stage1), "recoveryAccountRequired": true,
      "operation": "/kept",
    ]
  }

  static func manifest(staged: Data, mode: AuraBootMode = .macho, espPath: String)
    -> [String: Any]
  {
    [
      "schema": 2, "defaultMode": mode.rawValue, "modes": [mode.rawValue: ["espPath": espPath]],
      "files": [mode.stage1Path: ["sha256": RecoveryDigest.sha256(staged), "bytes": staged.count]],
    ]
  }

  static func refuses(_ expected: Stage1ReenrollmentError, _ why: String, _ body: () throws -> Void)
  {
    do {
      try body()
      preconditionFailure("accepted: \(why)")
    } catch let error as Stage1ReenrollmentError {
      precondition(error == expected, "\(why): \(error)")
      precondition(error.errorDescription?.contains("Nothing was changed") == true, why)
    } catch {
      preconditionFailure("\(why): \(error)")
    }
  }

  static func main() throws {
    // An Alpha 17 installation: an unpadded object that loads m1n1/boot.bin.
    let earlier = object(carrying: raw(path: "m1n1/boot.bin"))
    let staged = object(carrying: raw(path: "m1n1/boot-ctxr.bin"))
    try MachOBootObject.check(staged)
    let confined = AuraStage1Format.confinedStage2Path

    // A recognized installation with a staged update is offered it.
    let enrolled = receipt(stage1: earlier)
    let pending = Stage1Reenrollment.pending(
      receipt: enrolled, hasPendingInstallation: false, bootMode: "macho", stage2Path: confined,
      manifest: manifest(staged: staged, espPath: confined))
    precondition(
      pending
        == Stage1Reenrollment(
          mode: .macho, stage1SHA256: RecoveryDigest.sha256(staged), stage2Path: confined))
    let update = try Stage1Reenrollment.verify(
      stage1: staged, mode: .macho, chipID: t8140, espUUID: esp.uppercased(),
      stage2Path: confined, receipt: enrolled, stage2Bytes: 1 << 20)
    precondition(update == pending)
    // A raw Mac re-enrolls its raw image the same way.
    let rawStaged = raw(path: "m1n1/boot.bin")
    let rawUpdate = try Stage1Reenrollment.verify(
      stage1: rawStaged, mode: .raw, chipID: t8103, espUUID: esp, stage2Path: "m1n1/boot.bin",
      receipt: receipt(stage1: raw(uuid: esp, path: "m1n1/other.bin"), mode: "raw"),
      stage2Bytes: 20 << 20)
    precondition(rawUpdate?.mode == .raw)

    // The receipt changes only in what the new Stage 1 decides.
    let after = update!.receipt(after: enrolled, stage2SHA256: "stage2")
    precondition(after["stage1SHA256"] as? String == RecoveryDigest.sha256(staged))
    precondition(after["stage2Path"] as? String == confined)
    precondition(after["executeWindowSize"] as? UInt64 == ExecuteWindow.size)
    precondition(after["operation"] as? String == "/kept")
    precondition(after["recoveryAccountRequired"] as? Bool == true)
    var rawReceipt = receipt(stage1: rawStaged, mode: "raw")
    rawReceipt["executeWindowSize"] = 1
    precondition(
      rawUpdate!.receipt(after: rawReceipt, stage2SHA256: "")["executeWindowSize"] == nil)

    // An unchanged Stage 1 is a no-op: nothing is offered and nothing runs.
    let current = receipt(stage1: staged, stage2Path: confined)
    precondition(
      Stage1Reenrollment.pending(
        receipt: current, hasPendingInstallation: false, bootMode: "macho", stage2Path: confined,
        manifest: manifest(staged: staged, espPath: confined)) == nil)
    let unchanged = try Stage1Reenrollment.verify(
      stage1: staged, mode: .macho, chipID: t8140, espUUID: esp, stage2Path: confined,
      receipt: current, stage2Bytes: nil)
    precondition(unchanged == nil)

    // A mismatched or changed installation is refused before anything runs.
    for (receipt, interrupted, mode, manifest, why) in [
      (enrolled, true, "macho", manifest(staged: staged, espPath: confined), "setup unfinished"),
      (
        ["status": "pending"], false, "macho", manifest(staged: staged, espPath: confined),
        "no completed receipt"
      ),
      (enrolled, false, "raw", manifest(staged: staged, espPath: confined), "another mode"),
      (
        enrolled, false, "macho", manifest(staged: staged, espPath: "m1n1/boot.bin"),
        "a payload for another Stage 2"
      ),
    ] as [([String: Any], Bool, String, [String: Any], String)] {
      precondition(
        Stage1Reenrollment.pending(
          receipt: receipt, hasPendingInstallation: interrupted, bootMode: mode,
          stage2Path: confined, manifest: manifest) == nil, why)
    }
    refuses(.wrongMode, "a Mach-O Stage 1 on a raw chip") {
      _ = try Stage1Reenrollment.verify(
        stage1: staged, mode: .macho, chipID: t8103, espUUID: esp, stage2Path: confined,
        receipt: enrolled, stage2Bytes: 1 << 20)
    }
    refuses(.wrongTarget, "another installation's startup partition") {
      _ = try Stage1Reenrollment.verify(
        stage1: object(carrying: raw(uuid: "aaaaaaaa-1de6-4418-a00d-5b2d95884ad7", path: confined)),
        mode: .macho, chipID: t8140, espUUID: esp, stage2Path: confined, receipt: enrolled,
        stage2Bytes: 1 << 20)
    }
    refuses(.wrongTarget, "an unpadded object loading m1n1/boot.bin") {
      _ = try Stage1Reenrollment.verify(
        stage1: earlier, mode: .macho, chipID: t8140, espUUID: esp, stage2Path: "m1n1/boot.bin",
        receipt: receipt(stage1: staged), stage2Bytes: 1 << 20)
    }
    refuses(.missingStage2(path: confined), "an ESP without the confined Stage 2") {
      _ = try Stage1Reenrollment.verify(
        stage1: staged, mode: .macho, chipID: t8140, espUUID: esp, stage2Path: confined,
        receipt: enrolled, stage2Bytes: nil)
    }
    refuses(.missingStage2(path: confined), "a confined Stage 2 larger than aura's slot") {
      _ = try Stage1Reenrollment.verify(
        stage1: staged, mode: .macho, chipID: t8140, espUUID: esp, stage2Path: confined,
        receipt: enrolled, stage2Bytes: Int(ExecuteWindow.auraSlot) + 1)
    }
    do {
      _ = try Stage1Reenrollment.verify(
        stage1: object(carrying: Data(repeating: 1, count: 0x40)), mode: .macho, chipID: t8140,
        espUUID: esp, stage2Path: confined, receipt: enrolled, stage2Bytes: 1 << 20)
      preconditionFailure("accepted an object with no configuration")
    } catch is Stage1ReenrollmentError {}

    // An object that's too large is refused before it's read further.
    let huge = Data(count: Stage1Reenrollment.maximumBytes + 1)
    refuses(.tooLarge(bytes: huge.count), "an oversized object") {
      _ = try Stage1Reenrollment.verify(
        stage1: huge, mode: .macho, chipID: t8140, espUUID: esp, stage2Path: confined,
        receipt: enrolled, stage2Bytes: 1 << 20)
    }

    // Order, and an authorization failure: nothing is recorded or disarmed.
    struct Refused: Error {}
    for failing in ["stage", "authorizePolicy", "enroll", "record", ""] {
      var ran: [String] = []
      func step(_ name: String) throws {
        ran.append(name)
        if name == failing { throw Refused() }
      }
      do {
        try Stage1ReenrollmentRunner.run(
          stage: { try step("stage") }, authorizePolicy: { try step("authorizePolicy") },
          enroll: { try step("enroll") }, record: { try step("record") },
          finish: { try step("finish") })
        precondition(failing.isEmpty)
      } catch is Refused {}
      let order = ["stage", "authorizePolicy", "enroll", "record", "finish"]
      let expected =
        failing.isEmpty ? order : Array(order.prefix(order.firstIndex(of: failing)! + 1))
      precondition(ran == expected, "\(failing): \(ran)")
    }
    print("Stage 1 re-enrollment checks passed")
  }
}
