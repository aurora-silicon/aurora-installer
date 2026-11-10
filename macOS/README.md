# Aurora Installer development

The SwiftUI app, privileged helper and Recovery app for [Aurora Installer](../README.md). Inspection, planning, disk preparation, image writing, firmware extraction, Recovery handoff, retries and preserved reinstall run natively in Swift.

## Build a preview

Requires macOS 15+, Swift 6.2+ and XcodeBuildMCP. Run from this directory:

```sh
XCODEBUILDMCP=/path/to/xcodebuildmcp bash Packaging/build-aurora-preview.sh /absolute/output
open "/absolute/output/Aurora Installer.app" --args --simulate
```

The preview uses the in-memory simulator. It does not register a helper, change disks or reboot. See [simulation scenarios](Development/Simulation.md).

## Tests

Portable checks run on Linux or macOS with Bash 5+, Python 3.12+, Git and standard Unix tools:

```sh
bash test/all
```

On a Mac, also run:

```sh
xcrun swift-format lint --strict --recursive Package.swift Sources Plugins Tests
xcodebuildmcp swift-package test --package-path "$PWD" --configuration debug
xcodebuildmcp swift-package test --package-path "$PWD" --configuration release
```

These checks are unprivileged. Build and simulation results do not establish physical installation or Recovery qualification. See [validation](docs/validation.md) and [CI](../.github/workflows/native-checks.yml).

## Source layout

- `Sources/`, `Tests/`, `Package.swift`: app, native engine, helper, firmware library and tests.
- `Recovery/`: [Recovery app and account setup](Recovery/README.md).
- `RestoreImage/`: native restore-image decoder.
- `Packaging/`: [app and package assembly](Packaging/README.md).
- `Release/`, `scripts/`: signed catalogs, delivery and release tooling.

The native executor is `NativeInstallerExecutor`. Signed schema-5 catalogs select its built-in `native-v1` engine. The app and DMG contain no Python interpreter or engine archive; Python is used for development scripts and the separate firmware tools.

## Images and releases

The nine distribution/desktop profiles and their payloads are maintained in [aurora-distributions](https://github.com/aurora-silicon/aurora-distributions). Image producers live in [fedora-aurora](https://github.com/aurora-silicon/fedora-aurora), [alarm-aurora](https://github.com/aurora-silicon/alarm-aurora) and [nixos-aurora](https://github.com/aurora-silicon/nixos-aurora).

Catalogs bind the selected profile and exact artifact hashes. Firmware and calibration are collected from the target Mac. Names required by existing installations and released payloads are recorded in `Sources/AuroraAppleInstaller/PublishedContractNames.swift`.

See [DMG release builds](docs/native-dmg-release.md) and [local payload testing](docs/private-local-payload-install.md). Current downloads and hardware qualification belong in the distribution repository.
