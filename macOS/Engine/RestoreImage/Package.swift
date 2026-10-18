// swift-tools-version: 6.2
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
  name: "RestoreImage",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "omarchy-restore-image", targets: ["RestoreImageCLI"])],
  targets: [
    .target(name: "RestoreImageCore"),
    .executableTarget(name: "RestoreImageCLI", dependencies: ["RestoreImageCore"]),
    .testTarget(
      name: "RestoreImageCoreTests", dependencies: ["RestoreImageCore"],
      resources: [.copy("Fixtures")]),
  ]
)
