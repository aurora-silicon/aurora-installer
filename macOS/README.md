# Aurora Installer for macOS

Native SwiftUI front end for Aurora Linux on Apple Silicon. It shares the Apple boot, firmware-extraction, disk-planning and Recovery-account groundwork from the tested installer, with a separate Aurora application/helper identity and native macOS presentation. The repository's root command-line installer remains intact.

## Current status

The native preview offers **Aurora Fedora Remix**, **Aurora ALARM** and **UEFI**, with **KDE Plasma**, **GNOME** and **Minimal (shell)** for the Linux choices. UEFI has no desktop selection. The desktop cards use native vector mockups of Plasma, GNOME and a shell; they do not promise an exact wallpaper or desktop version in a future Aurora image.

This is a UI and integration preview, not a newly qualified Fedora/ALARM release. No Aurora Fedora or ALARM OS payload is published by this change. A live install requires a matching signed profile catalog; an existing Omarchy image is deliberately not accepted as one of these distributions. The current inherited full-OS engine also needs the layout and renamed Recovery-app contract changes described below before these profiles can perform live installation.

## Build the preview

Requires macOS 15 or newer, Swift 6.2 or newer and XcodeBuildMCP. From this directory:

```sh
XCODEBUILDMCP=/path/to/xcodebuildmcp Packaging/build-aurora-preview.sh /absolute/output
open "/absolute/output/Aurora Installer.app" --args --simulate
```

The preview is explicitly marked `AuroraPreviewOnly` and runs the in-memory simulator. It does not install a helper, repartition, create accounts, change startup policy or reboot. Simulation controls are in the menu bar. The production app and helper use `org.aurorasilicon.installer`; the preview has a separate bundle identifier. No production signing identity or public download service is configured yet.

## Distribution profiles

| Profile | Distribution | Desktop | Intended payload layout |
| --- | --- | --- | --- |
| `fedora-kde` | Aurora Fedora Remix | KDE Plasma | ESP, Boot, Root |
| `fedora-gnome` | Aurora Fedora Remix | GNOME | ESP, Boot, Root |
| `fedora-minimal` | Aurora Fedora Remix | Shell | ESP, Boot, Root |
| `arch-kde` | Aurora ALARM | KDE Plasma | ESP, Boot, Root |
| `arch-gnome` | Aurora ALARM | GNOME | ESP, Boot, Root |
| `arch-minimal` | Aurora ALARM | Shell | ESP, Boot, Root |
| `uefi` | UEFI boot environment | None | ESP only |

Every profile gets a distinct signed catalog under `Release/Profiles/<profile>/`. The existing release descriptor, public-key and catalog files live inside that directory. Each enabled catalog model must carry `installationProfile` equal to the selected profile. The GUI checks that signed field before accepting its assets. Download state, accepted catalog sequence and scratch files are separated by profile, so changing distribution cannot reuse another profile's plan or payload.

The main application preserves the shared native authorization and Recovery handoff. Actual release work must retain those checks while replacing distribution-specific filesystem assumptions; changing the product label is not a distribution port.

## Producing the images

Fedora's established path is [KIWI image descriptions](https://docs.pagure.org/fedora-asahi/kiwi-descriptions/), with KDE, GNOME and minimal profiles. Its producer creates a raw disk image and converts the partitions into the Asahi installer's ZIP payload. Aurora should maintain its own descriptions/release package, repositories and signing keys, with Aurora RPMs for the kernel, Mesa, boot tools and required hardware services. Our existing Arch `.pkg.tar.zst` packages are not Fedora RPMs; Fedora needs its own package builds.

The upstream producer's documented entry point is:

```sh
kiwi-ng --type=oem --profile=Workstation-KDE system build --description ./ --target-dir ./outdir
./make-asahi-installer-package.sh outdir/IMAGE.raw package.zip
```

Use `Workstation-GNOME` and `Minimal` for the other Fedora profiles after adapting the description to the Aurora repositories. Updates must continue to use those Aurora packages rather than replacing the working hardware stack with incompatible stock packages.

The [maintained ALARM image builder](https://github.com/asahi-alarm/asahi-alarm-builder/blob/main/build.sh) is a useful starting point. Aurora ALARM should start with the [Arch Linux ARM AArch64 root filesystem](https://archlinuxarm.org/platforms/armv8/generic), then install Aurora's signed pacman repository and the selected desktop during image construction. Three preassembled images keep the user's installation mostly offline; installing the desktop at first boot would add a large network-dependent step. The existing Arch package build and qualified Aurora boot stack can be reused, with first-boot account setup designed for these distributions rather than Omarchy's desktop setup.

The [Asahi installer metadata](https://github.com/AsahiLinux/asahi-installer-data) supplies the useful transport contract: OS templates describe partitions and map packaged files to them. This permits one GUI to select several distributions. Aurora should publish its own metadata and payloads and retain one common Aura/m1n1 + U-Boot + Limine build, selecting the matching machine DTB. Firmware and per-device calibration must still be extracted from the target Mac; another Mac's calibration must not enter a release image.

Before publishing these profiles, the inherited engine needs explicit layout kinds. Its current full-OS validator requires an Omarchy icon and exactly ESP + Boot + Root; it also assumes Omarchy's Btrfs tree and first-boot behavior. Fedora and ALARM should have profile-specific filesystem and package checks. UEFI needs the separate APFS-stub + ESP path, with no fake Linux root or desktop. Existing-install discovery and removal must use the same typed layout contract. The Recovery-app staging contract must also use the new Aurora app name while retaining its inventory, hash and paired-Recovery checks. No validator should be relaxed globally to accommodate a new distribution.

Online releases can download only the selected profile. Offline downloads can bundle one or more complete profiles using the existing verified-artifact mechanism. An all-desktop offline bundle will be larger than a single-profile package; the GUI should clearly show which profiles are included.

## Provenance and assets

The native code was imported from `aurora-silicon/omarchy-mac` at `55c855ce3f8dbdbfc5393aa4d929352142a0d1dc`, retaining its MIT license and upstream attribution. Internal module and protocol names remain where renaming them would break the engine contract. This is an independent Aurora product; those internal names are not the displayed product identity.

The Aurora mark comes from the supplied Aurora Silicon brand kit. Official Fedora, Arch Linux ARM, Plasma and GNOME artwork are recorded with source URLs and hashes in `Resources/BrandSources/manifest.json`. The desktop mockups are native vector views; UEFI uses the UEFI Forum mark.

## Validation

See [the recorded preview validation](docs/aurora-preview-validation.md) for native test counts, selector interaction checks, the remaining production-identity check and the unobserved final rerun after Neo returned to Linux.
