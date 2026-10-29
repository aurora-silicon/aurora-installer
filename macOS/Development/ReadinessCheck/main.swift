import Darwin
import Foundation
import AuroraAppleInstallerTrustCore

@main struct InstallerReadinessCheck {
  static func main() async {
    do { try await check() } catch {
      FileHandle.standardError.write(Data("NOT READY: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func check() async throws {
    guard CommandLine.arguments.count == 1 else { throw NSError(domain: "readiness", code: 64) }
    let host = try AppleSiliconHostInspector().inspect()
    let inspection = try await NativeInstallerInspector().inspect(host: host)
    let engine = inspection.validated
    guard engine.deviceIdentifier == host.identity.deviceIdentifier, engine.support == .supported,
      host.eligibility == .requiresSignedCatalog
    else { throw NSError(domain: "readiness", code: 1) }
    print("READY: \(host.identity.deviceIdentifier), native inspection")
  }
}
