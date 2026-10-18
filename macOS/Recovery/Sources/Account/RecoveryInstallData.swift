import CryptoKit
import Darwin
import Foundation

/// Installation-specific inputs live beside the immutable signed Recovery app.
public enum RecoveryInstallData {
  public static let relativePath = "Aurora/Recovery/InstallData"

  public static func directory(system: URL) throws -> URL {
    var path = system
    for name in relativePath.split(separator: "/") {
      path.appendPathComponent(String(name), isDirectory: true)
      var info = stat()
      if lstat(path.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw AccountSetupFailure("The Recovery installation data path is unsuitable.")
        }
      } else if errno != ENOENT {
        throw AccountSetupFailure("The Recovery installation data path could not be read.")
      }
    }
    return path
  }

  public static func configuration(system: URL, appName: String) throws -> URL {
    let external = try directory(system: system)
    if FileManager.default.fileExists(atPath: external.path) {
      return external.appendingPathComponent("install-config.json")
    }
    // Read old embedded data only to discover/migrate a prior installation.
    return system.appendingPathComponent(appName + "/Contents/Resources/install-config.json")
  }

  @discardableResult public static func migrateLegacy(
    system: URL, appName: String, target: RecoveryAccountTarget,
    read: (URL, Int) throws -> Data = RecoveryAccountInstaller.protectedRead
  ) throws -> URL {
    let fm = FileManager.default
    let destination = try directory(system: system)
    if fm.fileExists(atPath: destination.path) {
      _ = try verifiedBaseline(resources: destination, target: target, read: read)
      return destination
    }
    let resources = system.appendingPathComponent(appName + "/Contents/Resources")
    var legacy = system
    for name in [appName, "Contents", "Resources"] {
      legacy.appendPathComponent(name)
      try requireDirectory(legacy)
    }
    let (config, manifest, verified) = try verifiedBaseline(
      resources: resources, target: target, read: read)
    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = try directory(system: system)
    let temporary = parent.appendingPathComponent(".install-data-" + UUID().uuidString)
    try fm.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    try RecoveryFileTransaction.write(
      config, to: temporary.appendingPathComponent("install-config.json"))
    for (name, bytes) in verified {
      let output = temporary.appendingPathComponent("AuraPayloads/" + name)
      try fm.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try RecoveryFileTransaction.write(bytes, to: output)
    }
    try RecoveryFileTransaction.write(
      manifest, to: temporary.appendingPathComponent("AuraPayloads/manifest.json"))
    try RecoveryFileTransaction.flushTree(temporary)
    try fm.moveItem(at: temporary, to: destination)
    try RecoveryFileTransaction.flushDirectory(parent)
    return destination
  }

  public static func payloadDirectory(system: URL) throws -> URL {
    let path = try directory(system: system).appendingPathComponent("AuraPayloads")
    try requireDirectory(path)
    return path
  }

  private static func requireDirectory(_ path: URL) throws {
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw AccountSetupFailure("The Recovery payload directory is unsuitable.")
    }
  }

  private static func verifiedBaseline(
    resources: URL, target: RecoveryAccountTarget, read: (URL, Int) throws -> Data
  ) throws -> (Data, Data, [String: Data]) {
    let config = try read(resources.appendingPathComponent("install-config.json"), 65536)
    try validateTarget(config, target)
    let payloads = resources.appendingPathComponent("AuraPayloads")
    try requireDirectory(payloads)
    let manifest = try read(payloads.appendingPathComponent("manifest.json"), 1 << 20)
    guard let value = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      value["schema"] as? Int == 2,
      let files = value["files"] as? [String: [String: Any]]
    else { throw AccountSetupFailure("The old Recovery payload manifest is invalid.") }
    let required: Set<String> = [
      "raw/aura-raw.bin", "raw/boot.bin", "vendorfw/firmware.tar",
      "vendorfw/firmware.cpio", "vendorfw/manifest.txt",
    ]
    let allowed = required.union(["vendorfw/u-boot/asmedia/asm2214a-apple.bin"])
    guard required.isSubset(of: files.keys), Set(files.keys).isSubset(of: allowed) else {
      throw AccountSetupFailure("The old Recovery payload inventory is invalid.")
    }
    var verified: [String: Data] = [:]
    for (name, entry) in files {
      var path = payloads
      for component in name.split(separator: "/") {
        path.appendPathComponent(String(component))
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
          throw AccountSetupFailure("The old Recovery payload path is unsuitable.")
        }
      }
      let bytes = try read(path, name.hasSuffix(".txt") ? 1 << 20 : 256 << 20)
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      guard entry["bytes"] as? Int == bytes.count, entry["sha256"] as? String == hash else {
        throw AccountSetupFailure("The old Recovery payload changed before migration.")
      }
      verified[name] = bytes
    }
    return (config, manifest, verified)
  }

  private static func validateTarget(_ config: Data, _ target: RecoveryAccountTarget) throws {
    guard let object = try JSONSerialization.jsonObject(with: config) as? [String: Any],
      object["schema"] as? Int == 2,
      object["systemUUID"] as? String == target.systemUUID,
      object["groupUUID"] as? String == target.groupUUID,
      object["prebootUUID"] as? String == target.prebootUUID
    else { throw AccountSetupFailure("The Recovery data belongs to another installation.") }
  }
}
