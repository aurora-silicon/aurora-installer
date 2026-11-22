// SPDX-License-Identifier: MIT
// The helper's Recovery template archive: the flat JSON container the GUI
// hands over, reconstructed into a private app directory and inventoried.
// The code-signature check is the caller's and is not part of this reader.
import Foundation

@testable import AuroraFirmware

/// What the template source names from the rest of the installer target.
struct ImportedEngineHandoffPackage {
  let packageURL: URL
  let recoveryTemplateURL: URL?
}
enum InstallerLoggedCommand {
  @discardableResult
  static func checked(_ executable: String, _ arguments: [String]) throws -> Data { Data() }
}

let fuzzTemplateParent: URL = {
  let parent = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("recovery-template-fuzz-\(getpid())")
  try? FileManager.default.removeItem(at: parent)
  try! FileManager.default.createDirectory(
    at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return parent
}()

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzRecoveryTemplate(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  let data = fuzzData(bytes, count)
  do {
    let prepared = try NativeRecoveryTemplate.prepare(
      data: data, in: fuzzTemplateParent, owner: getuid(), requirement: "cdhash H\"00\"",
      verify: { _ in })
    _ = try? NativeRecoveryTemplate.templateIdentity(prepared, owner: getuid())
    prepared.remove()
  } catch {
    fuzzNote("template", error)
  }
  // A refused archive must leave nothing behind.
  if let left = try? FileManager.default.contentsOfDirectory(atPath: fuzzTemplateParent.path),
    !left.isEmpty
  {
    fatalError("Recovery template left \(left) behind")
  }
  return 0
}
