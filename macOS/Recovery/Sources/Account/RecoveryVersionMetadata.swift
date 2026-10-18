import Foundation

/// The stub needs its version visible during native Startup Disk authorization,
/// then hidden again for the initial Finish Installation Recovery handoff.
public enum RecoveryVersionMetadata {
  public static func validate(_ data: Data) throws {
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      value["ProductName"] as? String == "macOS",
      let version = value["ProductVersion"] as? String, !version.isEmpty,
      let build = value["ProductBuildVersion"] as? String, !build.isEmpty
    else { throw AccountSetupFailure("The stub is missing valid macOS version metadata.") }
  }

  public static func showForStartupDisk(system: URL) throws {
    try setVisible(true, system: system)
  }

  public static func hideForInitialRecovery(system: URL) throws {
    try hideForInitialRecovery(system: system, read: RecoveryAccountInstaller.protectedRead)
  }

  static func hideForInitialRecovery(
    system: URL, read: (URL, Int) throws -> Data
  ) throws {
    guard
      FileManager.default.fileExists(atPath: system.appendingPathComponent(".IAPhysicalMedia").path)
    else { return }
    try setVisible(false, system: system, read: read)
  }

  /// Finish the re-armed handoff only after native account ownership is verified.
  /// The caller snapshots every affected file, then passes the returned
  /// relocations to transaction.commit() to preserve moved metadata flags.
  @discardableResult
  public static func finishAccountSetup(
    system: URL, installationPending: Bool = false
  ) throws -> [String: URL] {
    try finishAccountSetup(
      system: system, installationPending: installationPending,
      read: RecoveryAccountInstaller.protectedRead)
  }

  @discardableResult
  static func finishAccountSetup(
    system: URL, installationPending: Bool = false, read: (URL, Int) throws -> Data
  ) throws -> [String: URL] {
    // Enrollment owns these files until its receipt is durable. Account ownership
    // can finish first without disarming the launcher needed to retry enrollment.
    guard !installationPending else { return [:] }
    var relocated = [String: URL]()
    let fm = FileManager.default
    let marker = system.appendingPathComponent(".IAPhysicalMedia")
    let disabled = system.appendingPathComponent("IAPhysicalMedia-disabled.plist")
    let receipt = system.appendingPathComponent("Aurora/Recovery/State/installation.json")
    var updated: Data?
    if fm.fileExists(atPath: receipt.path) {
      let bytes = try read(receipt, 65536)
      guard var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        value["status"] as? String == "installed"
      else { throw AccountSetupFailure("The completed installation receipt is invalid.") }
      if value["recoveryAccountDeferred"] as? Bool == true {
        value["recoveryAccountDeferred"] = false
        updated = try JSONSerialization.data(
          withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      }
    }
    if fm.fileExists(atPath: marker.path) {
      let bytes = try read(marker, 65536)
      guard
        let launch = try PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any], launch["AppName"] as? String == "Omarchy Installer.app"
      else { throw AccountSetupFailure("The Recovery launcher belongs to another application.") }
      if !fm.fileExists(atPath: disabled.path) {
        relocated[marker.standardizedFileURL.path] = disabled
      }
      try RecoveryFileTransaction.write(bytes, to: disabled)
      try fm.removeItem(at: marker)
      try RecoveryFileTransaction.flushDirectory(system)
    }
    let core = system.appendingPathComponent("System/Library/CoreServices")
    let hidden = core.appendingPathComponent("SystemVersion-disabled.plist")
    if fm.fileExists(atPath: hidden.path) {
      relocated[hidden.standardizedFileURL.path] = core.appendingPathComponent(
        "SystemVersion.plist")
    }
    try setVisible(true, system: system, read: read)
    if let updated { try RecoveryFileTransaction.write(updated, to: receipt) }
    return relocated
  }

  private static func setVisible(
    _ visible: Bool, system: URL,
    read: (URL, Int) throws -> Data = RecoveryAccountInstaller.protectedRead
  ) throws {
    let core = system.appendingPathComponent("System/Library/CoreServices", isDirectory: true)
    let enabled = core.appendingPathComponent("SystemVersion.plist")
    let disabled = core.appendingPathComponent("SystemVersion-disabled.plist")
    let target = visible ? enabled : disabled
    let source = visible ? disabled : enabled
    let fm = FileManager.default
    if fm.fileExists(atPath: target.path) {
      try validate(read(target, 65536))
      guard !fm.fileExists(atPath: source.path) else {
        throw AccountSetupFailure(
          "The stub has conflicting macOS version metadata. Both files were preserved.")
      }
      return
    }
    let bytes = try read(source, 65536)
    try validate(bytes)
    try fm.moveItem(at: source, to: target)
    guard try read(target, 65536) == bytes else {
      throw AccountSetupFailure("The stub version metadata did not verify.")
    }
  }
}
