// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "OmarchyAppleInstallerTrustCore",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "AuroraFirmware", targets: ["AuroraFirmware"]),
    .executable(name: "AuroraFirmwareCheck", targets: ["AuroraFirmwareCheck"]),
    .library(
      name: "OmarchyAppleInstallerTrustCore",
      targets: ["OmarchyAppleInstallerTrustCore"]
    ),
    .library(
      name: "OmarchyInstallerUXCore",
      targets: ["OmarchyInstallerUXCore"]
    ),
    .executable(
      name: "OmarchyAppleInstallerApp",
      targets: ["OmarchyAppleInstallerApp"]
    ),
    .executable(
      name: "OmarchyAppleInstallerHelper",
      targets: ["OmarchyAppleInstallerHelper"]
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
      name: "OmarchyInstallerSystem",
      path: "Sources/OmarchyInstallerSystem",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "RecoveryAccountQualification",
      dependencies: ["RecoveryAccountCore"],
      path: "Development/RecoveryAccountQualification"
    ),
    .executableTarget(
      name: "InstallerReadinessCheck",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Development/ReadinessCheck"
    ),
    .executableTarget(
      name: "OmarchyInstallerIdentityGenerator",
      path: "Sources/OmarchyInstallerIdentityGenerator"
    ),
    .plugin(
      name: "OmarchyInstallerIdentityPlugin",
      capability: .buildTool(),
      dependencies: ["OmarchyInstallerIdentityGenerator"]
    ),
    .target(
      name: "OmarchyAppleInstallerTrustCore",
      dependencies: ["OmarchyInstallerSystem", "RecoveryAccountCore", "AuroraFirmware"],
      path: "Sources/OmarchyAppleInstaller",
      plugins: ["OmarchyInstallerIdentityPlugin"]
    ),
    .target(
      name: "OmarchyInstallerUXCore",
      dependencies: ["OmarchyAppleInstallerTrustCore", "RecoveryAccountCore"],
      path: "Sources/OmarchyInstallerUXCore"
    ),
    .executableTarget(
      name: "OmarchyAppleInstallerApp",
      dependencies: [
        "OmarchyAppleInstallerTrustCore",
        "OmarchyInstallerUXCore",
        "RecoveryAccountCore",
      ],
      path: "Sources/OmarchyAppleInstallerApp"
    ),
    .executableTarget(
      name: "OmarchyAppleInstallerHelper",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Sources/OmarchyAppleInstallerHelper"
    ),
    .testTarget(
      name: "OmarchyAppleInstallerTrustCoreTests",
      dependencies: [
        "OmarchyAppleInstallerTrustCore", "RecoveryAccountCore", "NativeFirmwareFixtureSupport",
      ],
      path: "Tests/OmarchyAppleInstallerTrustCoreTests",
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "OmarchyInstallerLifecycleTests",
      dependencies: ["OmarchyAppleInstallerTrustCore"],
      path: "Tests/OmarchyInstallerLifecycleTests"
    ),
    .testTarget(
      name: "OmarchyAppleInstallerAppTests",
      dependencies: ["OmarchyAppleInstallerApp"],
      path: "Tests/OmarchyAppleInstallerAppTests"
    ),
    .testTarget(
      name: "OmarchyInstallerUXCoreTests",
      dependencies: ["OmarchyInstallerUXCore"],
      path: "Tests/OmarchyInstallerUXCoreTests"
    ),
  ]
)
