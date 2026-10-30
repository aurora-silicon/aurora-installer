// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AuroraAppleInstallerTrustCore",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "AuroraFirmware", targets: ["AuroraFirmware"]),
    .executable(name: "AuroraFirmwareCheck", targets: ["AuroraFirmwareCheck"]),
    .library(
      name: "AuroraAppleInstallerTrustCore",
      targets: ["AuroraAppleInstallerTrustCore"]
    ),
    .library(
      name: "AuroraInstallerUXCore",
      targets: ["AuroraInstallerUXCore"]
    ),
    .executable(
      name: "AuroraAppleInstallerApp",
      targets: ["AuroraAppleInstallerApp"]
    ),
    .executable(
      name: "AuroraAppleInstallerHelper",
      targets: ["AuroraAppleInstallerHelper"]
    ),
  ],
  targets: [
    .executableTarget(name: "AuroraFirmwareRecipeGenerator"),
    .plugin(
      name: "AuroraFirmwareRecipePlugin", capability: .buildTool(),
      dependencies: ["AuroraFirmwareRecipeGenerator"]),
    .target(
      name: "AuroraFirmware", exclude: ["PROVENANCE.md", "Resources"],
      plugins: ["AuroraFirmwareRecipePlugin"]),
    .executableTarget(
      name: "AuroraFirmwareCheck", dependencies: ["AuroraFirmware"],
      path: "Development/NativeFirmwareCheck"),
    .testTarget(
      name: "AuroraFirmwareTests",
      dependencies: ["AuroraFirmware", "NativeFirmwareFixtureSupport"],
      resources: [.copy("Fixtures")]),
    .target(
      name: "NativeFirmwareFixtureSupport", path: "Tests/NativeFirmwareFixtureSupport",
      resources: [.copy("Fixtures")]),
    .target(name: "RecoveryAuthorization", path: "Recovery/Native", publicHeadersPath: "."),
    .target(
      name: "RecoveryAccountCore", dependencies: ["RecoveryAuthorization"],
      path: "Recovery/Sources/Account"),
    .target(
      name: "AuroraInstallerSystem",
      path: "Sources/AuroraInstallerSystem",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "RecoveryAccountQualification",
      dependencies: ["RecoveryAccountCore"],
      path: "Development/RecoveryAccountQualification"
    ),
    .executableTarget(
      name: "InstallerReadinessCheck",
      dependencies: ["AuroraAppleInstallerTrustCore"],
      path: "Development/ReadinessCheck"
    ),
    .executableTarget(
      name: "InstallerDryRun",
      dependencies: ["AuroraAppleInstallerTrustCore", "AuroraFirmware", "AuroraInstallerUXCore"],
      path: "Development/InstallerDryRun"
    ),
    .executableTarget(
      name: "AuroraInstallerIdentityGenerator",
      path: "Sources/AuroraInstallerIdentityGenerator"
    ),
    .plugin(
      name: "AuroraInstallerIdentityPlugin",
      capability: .buildTool(),
      dependencies: ["AuroraInstallerIdentityGenerator"]
    ),
    .target(
      name: "AuroraAppleInstallerTrustCore",
      dependencies: ["AuroraInstallerSystem", "RecoveryAccountCore", "AuroraFirmware"],
      path: "Sources/AuroraAppleInstaller",
      plugins: ["AuroraInstallerIdentityPlugin"]
    ),
    .target(
      name: "AuroraInstallerUXCore",
      dependencies: ["AuroraAppleInstallerTrustCore", "RecoveryAccountCore"],
      path: "Sources/AuroraInstallerUXCore"
    ),
    .executableTarget(
      name: "AuroraAppleInstallerApp",
      dependencies: [
        "AuroraAppleInstallerTrustCore",
        "AuroraInstallerUXCore",
        "RecoveryAccountCore",
      ],
      path: "Sources/AuroraAppleInstallerApp"
    ),
    .executableTarget(
      name: "AuroraAppleInstallerHelper",
      dependencies: ["AuroraAppleInstallerTrustCore"],
      path: "Sources/AuroraAppleInstallerHelper"
    ),
    .testTarget(
      name: "AuroraAppleInstallerTrustCoreTests",
      dependencies: [
        "AuroraAppleInstallerTrustCore", "RecoveryAccountCore", "NativeFirmwareFixtureSupport",
      ],
      path: "Tests/AuroraAppleInstallerTrustCoreTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "AuroraInstallerLifecycleTests",
      dependencies: ["AuroraAppleInstallerTrustCore"],
      path: "Tests/AuroraInstallerLifecycleTests"
    ),
    .testTarget(
      name: "AuroraAppleInstallerAppTests",
      dependencies: ["AuroraAppleInstallerApp"],
      path: "Tests/AuroraAppleInstallerAppTests"
    ),
    .testTarget(
      name: "AuroraInstallerUXCoreTests",
      dependencies: ["AuroraInstallerUXCore"],
      path: "Tests/AuroraInstallerUXCoreTests"
    ),
  ]
)
