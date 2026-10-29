# Aurora Installer for macOS

Native SwiftUI installer for Aurora Linux on Apple Silicon, with a separate Aurora application/helper identity and native Recovery app. The repository's root Windows command-line installer remains intact.

## Current status

The native app offers **Fedora Aurora Remix**, **Aurora ALARM** and **Aurora NixOS**, each with **KDE Plasma**, **GNOME** and **Minimal (shell)**. All nine development images and signed delivery catalogs have been built. Their current sources, downloads and device qualification are recorded in [aurora-distributions](https://github.com/aurora-silicon/aurora-distributions).

Developer apps are ad hoc signed, their packages are unsigned, and notarization is not configured. Public catalogs admit their listed M1–M3 models; Neo remains a private developer delivery. Physical Mac installation, Recovery, hardware updates and reboot qualification remain pending. The final NixOS minimal image has passed Linux owner/encryption, installed-configuration rebuild and rebuilt-generation boot checks in native AArch64 KVM; [validation evidence](https://github.com/aurora-silicon/aurora-distributions/blob/main/docs/VALIDATION.md) records the scope and captured results.

## Build a UI preview

Requires macOS 15 or newer, Swift 6.2 or newer and XcodeBuildMCP. From this directory:

```sh
XCODEBUILDMCP=/path/to/xcodebuildmcp Packaging/build-aurora-preview.sh /absolute/output
open "/absolute/output/Aurora Installer.app" --args --simulate
```

This separate preview is marked `AuroraPreviewOnly` and runs the in-memory simulator. Simulation controls are in the menu bar. It does not register a helper or alter disks. The live application/helper identity comes from `Packaging/identity.conf`; the preview has a separate bundle identifier.

## Developer application and package

The [native developer build workflow](https://github.com/aurora-silicon/aurora-distributions/blob/main/.github/workflows/native-developer-build.yml) authenticates the current profile catalogs and Recovery template, builds through XcodeBuildMCP on macOS ARM and packages the result. Its [release procedure](https://github.com/aurora-silicon/aurora-distributions/blob/main/docs/RELEASING.md) separates candidate artifacts from live download publication.

For an explicitly marked developer app with sealed catalogs, `Packaging/build-developer-pkg.sh APP OUTPUT.pkg` builds the unsigned package. The app's embedded ad-hoc daemon configuration denies clients and has no self-registration declaration. The package derives the final signed app's code hash and writes its exact client requirement into the external system LaunchDaemon. The app's root and all profile descriptors pin the signed helper's code hash before app signing. See [packaging](Packaging/README.md) and `test/macos-developer-peer-binding.sh` for the macOS acceptance/rejection checks.

## Distribution profiles

| Profile | Distribution | Desktop | Payload layout |
| --- | --- | --- | --- |
| `fedora-kde` | Fedora Aurora Remix | KDE Plasma | ESP, Boot, Root |
| `fedora-gnome` | Fedora Aurora Remix | GNOME | ESP, Boot, Root |
| `fedora-minimal` | Fedora Aurora Remix | Minimal | ESP, Boot, Root |
| `arch-kde` | Aurora ALARM | KDE Plasma | ESP, Boot, Root |
| `arch-gnome` | Aurora ALARM | GNOME | ESP, Boot, Root |
| `arch-minimal` | Aurora ALARM | Minimal | ESP, Boot, Root |
| `nixos-kde` | Aurora NixOS | KDE Plasma | ESP, Boot, Root |
| `nixos-gnome` | Aurora NixOS | GNOME | ESP, Boot, Root |
| `nixos-minimal` | Aurora NixOS | Minimal | ESP, Boot, Root |

Each profile has a separate release descriptor, public key and catalog under `Release/Profiles/<profile>/`. Every enabled model in its signed catalog must carry the matching `installationProfile`. The GUI verifies the signature, profile binding and artifact identities before planning. Download state, accepted catalog sequence and scratch files are separated by profile.

Current payloads use explicit `fedora-btrfs-v1`, `alarm-btrfs-v1` and `nixos-btrfs-v1` contracts: a FAT ESP, ext4 Boot, and Btrfs root/home subvolumes. The installer checks filesystem signatures before disk changes. Native Recovery retains the external install-data inventory, hash and paired-Recovery checks. The shared [aurora-platform](https://github.com/aurora-silicon/aurora-platform) first-boot adapter handles in-place encryption and owner setup on the first Linux boot.

## Images, packages and updates

The native AArch64 producers and signed update repositories live in [fedora-aurora](https://github.com/aurora-silicon/fedora-aurora), [alarm-aurora](https://github.com/aurora-silicon/alarm-aurora) and [nixos-aurora](https://github.com/aurora-silicon/nixos-aurora). They record common Aurora hardware source revisions while using each distribution's own package, initrd and update tooling. The earlier KIWI configuration prototype remains under `fedora/`; current released images come from the distribution repositories.

`scripts/assemble-distribution-payload.py` combines verified filesystem outputs with native Recovery and records their delivery identities. `scripts/prepare-distribution-release.py` authenticates the complete nine-profile set before preparing app resources. The delivery pipeline supports separately pinned download parts and a whole-payload digest. Package signing, image assembly, signed delivery and physical qualification are separate gates.

Target firmware and calibration are collected from the target Mac. On the MacBook Neo, the native installer also fetches the model's firmware through its authenticated range recipe, reads the Mac's own radio, light-sensor and Touch ID records, and derives the Wi-Fi country policies before any disk change. The boot gate requires `world-XZ.bin`. Payloads and catalogs carry none of these inputs. Each of the nine profiles is one image for every supported Mac, the Neo included, and payload assembly has no board-only or privately supplied-input variant.

## Native execution

Inspection, planning, disk preparation, image writing, firmware and Recovery handoff, retry and preserved reset are all Swift, run by the app and its privileged helper. The installer has no Python engine or runtime, and its signed app and DMG contain no Python. It accepts only signed schema-5 catalogs, which name the built-in `native-v1` engine; an older catalog that pins an engine archive is refused with a message to choose another channel. A job an older installer left awaiting Recovery authorization continues natively from its retained package; a job that relied on the retired engine's repair operation asks the person to start over.

## Provenance and checks

The native code was imported from `aurora-silicon/omarchy-mac` at `55c855ce3f8dbdbfc5393aa4d929352142a0d1dc`, retaining its MIT license and upstream attribution. Names fixed by published payloads, released Recovery templates, installed launchd jobs and existing installations keep their original spelling; `Sources/AuroraAppleInstaller/PublishedContractNames.swift` lists the payload and Recovery ones. The Aurora mark comes from the supplied brand kit; project artwork sources and hashes remain in `Resources/BrandSources/manifest.json`.

`./test/all` runs unprivileged portable source, script and packaging-fixture checks. The native CI workflow runs strict Swift formatting and Debug/Release tests through XcodeBuildMCP, plus actual macOS code-signing/package fixtures. Historical preview results remain in [aurora-preview-validation.md](docs/aurora-preview-validation.md). Build and VM results do not qualify a physical installation.
