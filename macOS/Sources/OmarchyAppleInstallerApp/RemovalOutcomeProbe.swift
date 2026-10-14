import Foundation
import OmarchyAppleInstallerTrustCore

/// Reads, without privileges, what a removal leaves behind, for when its
/// reply is lost.
enum RemovalOutcomeProbe {
  /// The helper's job file, binary and state directory are all gone, in two
  /// looks a second apart, so a helper another build is reinstalling at that
  /// moment is not mistaken for one that retired.
  static func helperRetired() async -> Bool {
    let paths = [
      InstallerProductIdentity.systemLaunchDaemonPath,
      "/Library/PrivilegedHelperTools/" + InstallerProductIdentity.helperIdentifier,
      InstallerProductIdentity.helperWorkingDirectory,
    ]
    func absent() -> Bool {
      paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
    }
    guard absent() else { return false }
    try? await Task.sleep(for: .seconds(1))
    return absent()
  }

  /// The size of the APFS container macOS runs from.
  static func macOSContainerBytes() -> UInt64? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", "/"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return (info["APFSContainerSize"] as? NSNumber)?.uint64Value
  }
}
