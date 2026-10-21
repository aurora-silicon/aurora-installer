// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
import PackageDescription

// Focused native firmware qualification on Command Line Tools hosts, where
// Swift Testing is available but the Xcode-only XCTest framework may be absent.
// Both manifests compile the same production sources and the same policy tests.
let package = Package(
  name: "AuroraPolicyQualification", platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "AuroraFirmwareRecipeGenerator"),
    .plugin(
      name: "AuroraFirmwareRecipePlugin", capability: .buildTool(),
      dependencies: ["AuroraFirmwareRecipeGenerator"]),
    .target(
      name: "AuroraFirmware", exclude: ["PROVENANCE.md", "Resources"],
      plugins: ["AuroraFirmwareRecipePlugin"]),
    .testTarget(
      name: "AuroraFirmwareTests", dependencies: ["AuroraFirmware"],
      exclude: [
        "FirmwareExtractorTests.swift", "FirmwarePackageTests.swift",
        "GenericFirmwareConversionTests.swift", "IPSWArchiveTests.swift",
        "NeoFirmwareConversionTests.swift", "NeoRegulatoryPolicyTests.swift",
        "RangeCacheTests.swift", "RestoreImageTests.swift", "SignedSensorInputsTests.swift",
        "TransportTests.swift",
      ],
      sources: ["NeoRegulatoryPolicyV2Tests.swift"], resources: [.copy("Fixtures")]),
  ])
