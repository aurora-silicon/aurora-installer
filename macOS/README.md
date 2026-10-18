# Aurora Installer for macOS

Native SwiftUI front end for Aurora Linux on Apple Silicon. It shares the Apple boot, firmware-extraction, disk-planning and Recovery-account groundwork from the tested installer, with a separate Aurora application/helper identity and native macOS presentation. The repository's root command-line installer remains intact.

## Current status

The native preview offers **Fedora Aurora Remix**, **Aurora ALARM** and **Aurora NixOS**, with **KDE Plasma**, **GNOME** and **Minimal (shell)** for the Linux choices. The desktop cards use native vector mockups of Plasma, GNOME and a shell; they do not promise an exact wallpaper or desktop version in a future Aurora image.

This is a UI and integration preview, not a newly qualified Fedora/ALARM release. No Aurora Fedora, ALARM or NixOS OS payload is published by this change. A live install requires a matching signed profile catalog; an existing Omarchy image is deliberately not accepted as one of these distributions. The engine now validates explicit Fedora Btrfs, ALARM ext4 and NixOS ext4 layouts and the Aurora Recovery app contract; a live install still needs matching built payloads and signed profile catalogs.

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
| `fedora-kde` | Fedora Aurora Remix | KDE Plasma | ESP, Boot, Root |
| `fedora-gnome` | Fedora Aurora Remix | GNOME | ESP, Boot, Root |
| `fedora-minimal` | Fedora Aurora Remix | Shell | ESP, Boot, Root |
| `arch-kde` | Aurora ALARM | KDE Plasma | ESP, Boot, Root |
| `arch-gnome` | Aurora ALARM | GNOME | ESP, Boot, Root |
| `arch-minimal` | Aurora ALARM | Shell | ESP, Boot, Root |
| `nixos-kde` | Aurora NixOS | KDE Plasma | ESP, Boot, Root |
| `nixos-gnome` | Aurora NixOS | GNOME | ESP, Boot, Root |
| `nixos-minimal` | Aurora NixOS | Shell | ESP, Boot, Root |

Every profile gets a distinct signed catalog under `Release/Profiles/<profile>/`. The existing release descriptor, public-key and catalog files live inside that directory. Each enabled catalog model must carry `installationProfile` equal to the selected profile. The GUI checks that signed field before accepting its assets. Download state, accepted catalog sequence and scratch files are separated by profile, so changing distribution cannot reuse another profile's plan or payload.

The main application preserves the shared native authorization and Recovery handoff. Actual release work must retain those checks while replacing distribution-specific filesystem assumptions; changing the product label is not a distribution port.

## Producing the images

The [Fedora Aurora Remix producer](../fedora/README.md) now prepares pinned Fedora 44 KIWI descriptions for KDE, GNOME and minimal. It selects Aurora RPMs and records the Fedora filesystem contract. Its source/key checks and KIWI description loading are tested; the Aurora RPM set, image build and live Fedora engine adapter are not complete yet.

Fedora's established path is [KIWI image descriptions](https://docs.pagure.org/fedora-asahi/kiwi-descriptions/), with KDE, GNOME and minimal profiles. Its producer creates a raw disk image and converts the partitions into the Asahi installer's ZIP payload. Aurora should maintain its own descriptions/release package, repositories and signing keys, with Aurora RPMs for the kernel, Mesa, boot tools and required hardware services. Our existing Arch `.pkg.tar.zst` packages are not Fedora RPMs; Fedora needs its own package builds.

The upstream producer's documented entry point is:

```sh
kiwi-ng --type=oem --profile=Workstation-KDE system build --description ./ --target-dir ./outdir
./make-asahi-installer-package.sh outdir/IMAGE.raw package.zip
```

Use `Workstation-GNOME` and `Minimal` for the other Fedora profiles after adapting the description to the Aurora repositories. Updates must continue to use those Aurora packages rather than replacing the working hardware stack with incompatible stock packages.

The [maintained ALARM image builder](https://github.com/asahi-alarm/asahi-alarm-builder/blob/main/build.sh) is a useful starting point. Aurora ALARM should start with the [Arch Linux ARM AArch64 root filesystem](https://archlinuxarm.org/platforms/armv8/generic), then install Aurora's signed pacman repository and the selected desktop during image construction. Three preassembled images keep the user's installation mostly offline; installing the desktop at first boot would add a large network-dependent step. The existing Arch package build and qualified Aurora boot stack can be reused, with first-boot account setup designed for these distributions rather than Omarchy's desktop setup.

The [Asahi installer metadata](https://github.com/AsahiLinux/asahi-installer-data) supplies the useful transport contract: OS templates describe partitions and map packaged files to them. This permits one GUI to select several distributions. Aurora should publish its own metadata and payloads and retain one common Aura + U-Boot hardware boot chain, selecting the matching machine DTB. The Fedora configuration retains Fedora's GRUB/BLS and dracut integration. Firmware and per-device calibration must still be extracted from the target Mac; another Mac's calibration must not enter a release image.

The engine admits explicit `fedora-btrfs-v1`, `alarm-ext4-v1` and `nixos-ext4-v1` layouts, bound to the matching distro/desktop profile and Aurora volume icon. It verifies the boot and root image filesystem signatures before disk mutation. The imported Omarchy layout remains separate for existing artifacts; no general validator is relaxed to accept a different distribution. Aurora's native Recovery app uses the immutable external install-data layout and retains inventory, hash and paired-Recovery checks.

Distribution packaging and CI live in [fedora-aurora](https://github.com/aurora-silicon/fedora-aurora), [alarm-aurora](https://github.com/aurora-silicon/alarm-aurora) and [nixos-aurora](https://github.com/aurora-silicon/nixos-aurora). All use the same recorded Aurora hardware source revisions. A completed package or source build does not qualify a live installation.

Online releases can download only the selected profile. Offline downloads can bundle one or more complete profiles using the existing verified-artifact mechanism. An all-desktop offline bundle will be larger than a single-profile package; the GUI should clearly show which profiles are included.

## Provenance and assets

The native code was imported from `aurora-silicon/omarchy-mac` at `55c855ce3f8dbdbfc5393aa4d929352142a0d1dc`, retaining its MIT license and upstream attribution. Internal module and protocol names remain where renaming them would break the engine contract. This is an independent Aurora product; those internal names are not the displayed product identity.

The Aurora mark comes from the supplied Aurora Silicon brand kit. Official Fedora, Arch Linux ARM, Plasma and GNOME artwork are recorded with source URLs and hashes in `Resources/BrandSources/manifest.json`. The desktop mockups are native vector views; UEFI uses the UEFI Forum mark.

## Validation

See [the recorded preview validation](docs/aurora-preview-validation.md) for native test counts, selector interaction checks, the remaining production-identity check and the unobserved final rerun after Neo returned to Linux.
