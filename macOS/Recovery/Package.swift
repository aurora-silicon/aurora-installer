// swift-tools-version: 5.9

import Foundation
import PackageDescription

let buildMode = ProcessInfo.processInfo.environment["AURORA_RECOVERY_BUILD"] ?? "preview"
precondition(["preview", "recovery"].contains(buildMode), "Unknown Recovery build mode")

// Recovery may run an older macOS than the main installer. Keep this target
// independent of the main application's macOS 15 requirement.
let package = Package(
  name: "AuroraRecovery",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "AuroraRecovery", targets: ["AuroraRecovery"])],
  targets: [
    .target(name: "RecoveryAuthorization", path: "Native", publicHeadersPath: "."),
    .executableTarget(
      name: "AuroraRecovery",
      dependencies: ["RecoveryAuthorization"],
      path: "Sources",
      swiftSettings: [
        .define(buildMode == "recovery" ? "AURORA_STEP2_RECOVERY" : "AURORA_STEP2_PREVIEW")
      ]
    ),
  ]
)
