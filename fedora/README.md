# Fedora Aurora Remix

This directory starts the Fedora image producer for the native Aurora installer. The base is Fedora 44 with a pinned Fedora Asahi KIWI description, Aurora's hardware packages and Aurora's own release identity. KDE Plasma is the initial default; GNOME and minimal use the same package and boot contracts.

`configure.py` prepares the image description. It validates the source revision and repository signing key, replaces the upstream hardware and branding package selections, and keeps the Fedora partition layout. Image construction, Aurora RPM production and the native installer's Fedora layout adapter are subsequent steps; no installable Fedora payload is published here yet.

## Prepare a description

Requirements: Python 3.9+, Git and GnuPG. The image worker additionally needs a native AArch64 Linux host with KIWI and its Fedora build dependencies.

```sh
git clone --branch f44 https://pagure.io/fedora-asahi/kiwi-descriptions.git upstream-kiwi
git -C upstream-kiwi checkout 960ea8dc8fb33952a874bb4da94a07a055bb11ab
python3 fedora/configure.py \
  --upstream upstream-kiwi \
  --output out/fedora-kde \
  --profile fedora-kde \
  --repository-url https://YOUR-RPM-HOST/fedora/44/aarch64 \
  --signing-key /path/to/aurora-rpm-public-key.asc \
  --signing-key-fingerprint YOUR-OPENPGP-FINGERPRINT
```

The repository URL and public key must belong to the RPM set being tested. The script records their identities and produces the exact KIWI build command in `aurora-image.json`. The repository must provide all listed Aurora RPMs before that command can build an image. `fedora-gnome` and `fedora-minimal` select the other descriptions.

The upstream description and its GPL-3.0-or-later license are copied into the generated directory. `upstream.json` records the exact source revision. The producer leaves that checkout untouched and refuses to overwrite an existing output directory.

## Image and package contracts

| Component | Contract |
| --- | --- |
| Disk layout | EFI system partition, ext4 `/boot`, Btrfs root labeled `AURORA_ROOT` with `root` and `home` subvolumes |
| Boot | Aura Stage 1/Stage 2, Aurora U-Boot, Fedora GRUB/BLS and dracut |
| Kernel | `kernel-aurora` and `kernel-aurora-modules-extra`, with the same Aurora source/configuration across supported Macs |
| Graphics | `mesa-aurora-dri-drivers` and `mesa-aurora-vulkan-drivers` |
| Platform | `aurora-platform`, `aurora-firmware`, `alsa-ucm-conf-aurora`, `aurora-audio`, `speakerguardd` |
| Distribution | `aurora-release`, `aurora-logos`, `aurora-remix-scripts` |
| Updates | The Aurora RPM repository is retained in the installed image, with package and repository signature checking enabled |

These are RPM contracts, not renamed Arch archives. Kernel RPMs must integrate with Fedora's kernel-install, dracut and BLS conventions. Bootloader RPMs must provide the paths consumed by Fedora's `update-m1n1`. The release RPM must provide the Fedora release/identity capabilities required by the selected desktop groups; the scripts RPM must provide the first-boot service contracts inherited from the pinned image description. Device firmware and calibration continue to be extracted from the target Mac by the installer.

The native engine currently implements an Omarchy-specific full-OS payload contract. Fedora needs an explicit `fedora-btrfs-v1` adapter, its own volume icon and the Aurora Recovery app contract. The image producer records that intended layout; it does not make the existing live adapter accept a different filesystem implicitly.

## Distribution

Use the existing `aurora-silicon/aurora-installer` repository for native app source and release notes. The initial download can be a versioned native app ZIP/DMG on GitHub Releases. Public native builds use Developer ID signing and notarization; the current ad-hoc signed preview remains a development artifact. Signed per-profile catalogs should point to immutable, hashed OS payloads on object storage/CDN and to the corresponding native Recovery input. This keeps large desktop images independent of app updates and lets one app offer KDE, GNOME and minimal without downloading all three.

The RPM repository is a separate update channel: publish signed RPMs and signed `repodata`, retain older kernel/bootloader versions for rollback, and promote a tested set together. Copr is an option for RPM builds; a static repository on our storage is an option for serving the tested set. Hosting endpoints, production signing identities and release keys remain deployment choices; the current `.invalid` installer endpoints are placeholders.

For public branding, follow Fedora's [Remix guidance](https://fedoraproject.org/wiki/Remix), including replacing the Fedora release/logo packages. The final public name and artwork should also follow its naming guidance. This source work does not publish an app, repository or OS image.

## Checks

```sh
python3 fedora/test_configure.py
kiwi-ng --target-arch=aarch64 --type=oem --profile=Workstation-KDE image info \
  --description out/fedora-kde --print-xml
```

The first command tests profile selection, repository/key binding, source pinning and output preservation. The second runs KIWI's real description loader and schema checks. A successful description check is separate from resolving RPMs, building the image and installing it on Neo.
