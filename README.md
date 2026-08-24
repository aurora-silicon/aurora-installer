# Aurora Windows installer

Aurora prepares Apple Silicon Macs for Windows-oriented boot and deployment. It
offers three operations:

1. Install an Aurora m1n1 proxy boot environment.
2. Install the same environment and reserve an expandable, unformatted
   Microsoft Basic Data partition for a future Windows installation.
3. Create an ESP, internal Windows setup-media partition, MSR, and expandable
   Windows target; download and verify a pinned Windows 11 ARM64 ISO; then stage
   an Aurora driver-injected WinPE deployment.

The installer offers all three options on physical M1 through M5 Macs without a
model allowlist or expert-mode gate. The installed macOS and system firmware
still have to be new enough to create a valid Apple boot stub. Actual Windows
boot remains limited by the target-specific Mu bring-up described below.

## Boot layout

The layout preserves the two-stage design used by the upstream installer:

- A dedicated 2.5 GB APFS volume group contains the stub macOS and stage-1
  m1n1 boot object.
- Stage 1 chainloads `m1n1/boot.bin` from a dedicated FAT32 EFI System
  Partition.
- The initial stage-2 file is a payload-free Aurora m1n1 build, so it always
  enters m1n1 proxy mode.

The stage-2 path is a stable update contract. A future Aurora updater can mount
the EFI partition and atomically replace only `m1n1/boot.bin` with a compatible
autonomous m1n1/Mu image. Stage 1, boot policy, the APFS stub, and the partition
map do not need to change. `aurora/stage2.json` describes the installed mode and
path.

The shipping stage 2 remains proxy mode. The proven Mu/Windows flow currently
requires a tethered host to launch the machine-specific Mu firmware through
m1n1's hypervisor. Appending a Mu FD to m1n1 does not make an autonomous loader,
so the installer does not pretend that it does. A build can supply a future
validated autonomous stage 2 and matching manifest without changing storage
code.

## Windows deployment

The Windows option resolves [Microsoft's official ARM64 download
link](https://www.microsoft.com/en-us/software-download/windows11arm64) at
install time, but accepts only the exact pinned SKU, file size, and SHA-256 in
`data/windows-iso.json`. The current pin is Windows 11 25H2 English ARM64,
image build 26200.8037. The ISO is downloaded directly from Microsoft and is
never redistributed by Aurora.

Microsoft may reject automated creation of its 24-hour download link. In that
case, download the same English ARM64 ISO from the official page and export
`AURORA_WINDOWS_ISO=/absolute/path/to/Win11_25H2_English_Arm64_v2.iso` before
starting the installer. The local ISO is subject to the same exact size and
SHA-256 checks before any partition changes.

The public installer contains no Aurora driver or HAL-extension binaries. When
the staged-Windows option is selected, it asks for an assembled driver-pack
directory. `AURORA_WINDOWS_DRIVERS=/absolute/path/to/AuroraDrivers` can provide
the path non-interactively. The directory must contain exactly one
`AppleNvme.inf` package and one `HalExtAppleInterruptController.inf` package,
including their payload binaries and catalogs. Every other file is carried
recursively, so keyboard, trackpad, keyboard-backlight, GPU, audio, and other
driver packages and their dependencies may be included in the same tree.

Before partitioning, the installer validates Windows-safe paths and every INF
catalog reference, snapshots and hashes the complete user-supplied tree,
verifies the ISO and deployment scripts, and resolves its bundled tools. It
then copies the ISO to a 10 GB exFAT partition, puts a patched WinPE `boot.wim`
on the ESP, and writes unique deployment markers to the ESP, media, and
temporary exFAT target. On the first Mu boot, WinPE:

- starts with TESTSIGNING enabled and loads the boot-critical Apple NVMe
  package embedded in both WinPE indexes;
- proves the exact GPT disk ID and requires exactly one matching target marker;
- formats only that marker-selected target as NTFS;
- applies the pinned Windows 11 Pro image and injects the complete Aurora driver
  pack offline with `/ForceUnsigned`;
- runs BCDBoot, enables BCD test signing, and changes the ESP fallback loader
  from setup to the installed Windows Boot Manager.

Failure before the verified write boundary leaves the target untouched. Later
failures stop in a WinPE shell instead of rebooting or selecting another disk.
Test signing is deliberately enabled; `nointegritychecks` is not.

Catalog creation and code signing remain driver-build responsibilities. Use
the WDK `Inf2Cat` and signing workflow before supplying a package: Inf2Cat only
generates an unsigned catalog, and 64-bit Windows still requires every kernel
image to have a digital signature even in test mode. The installer validates
that catalogs referenced by every supplied INF are present, preserves the
complete package tree, and enables TESTSIGNING in both the setup BCD and the
installed Windows BCD; it never handles signing private keys.

## Storage safety

Partition discovery, APFS resize calculations, stub creation, boot-policy
setup, and adjacent partition creation remain inherited from the Asahi
installer. Aurora metadata selects the existing safe paths; it does not add a
second partitioning implementation. The boot environment is always placed in
its own APFS volume group and adjacent partitions, without writing into the
macOS volume group.

The reserve-only option adds one unformatted Microsoft Basic Data partition.
The staged-Windows option writes only the newly created Aurora ESP, setup-media,
and Windows-target partitions; the MSR remains raw. It never reuses a macOS
volume as installation media or as a Windows target.

## Building

Initialize the Aurora m1n1 submodule and run:

```sh
git submodule update --init m1n1
./build.sh
```

The build uses [`Aurora-Silicon/m1n1@main`](https://github.com/Aurora-Silicon/m1n1)
for both stages and bundles the stage-2 ZIP and installer metadata inside the
installer archive. `M1N1_STAGE1` and `M1N1_STAGE2` may point to prebuilt
binaries; `LOGO` may point to a custom ICNS file. The default icon is generated
from Aurora m1n1 artwork.

Every public build includes the Windows option, WinPE mutation tools, and
deployment scripts, but no private Aurora drivers. Driver/HAL packages are
selected by the installer user before any storage changes. The default Windows
stage 2 is the proxy image. A future autonomous image may be supplied with both
`AURORA_WINDOWS_STAGE2` and
`AURORA_WINDOWS_STAGE2_MANIFEST`; the manifest must retain the stable
`m1n1/boot.bin` replacement contract.

`scripts/bootstrap.sh` targets a local HTTP server. The dev and production
bootstrap scripts default to the latest GitHub release and can be redirected by
setting `VERSION_FLAG` and `INSTALLER_BASE`.

## Upstream and license

Aurora is based on the
[Asahi Linux installer](https://github.com/AsahiLinux/asahi-installer) because
it already implements the sensitive Apple Silicon storage and boot-policy
work. Upstream history and the MIT `LICENSE` are retained. The bundled
`asahi_firmware` module and internal `chosen.asahi,*` boot variables keep their
upstream names for compatibility.
