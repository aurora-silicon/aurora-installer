# Startup firmware: pinned builds and slots

The startup firmware is the stub macOS that iBoot starts for Linux. Its Preboot volume holds the firmware iBoot loads for the coprocessors (GPU, DCP, AOP, ANE, AVE, ISP, PMP, SIO, SEP), so it changes only with a new stub. Until now the installer chose a stub once, at installation, and "Update Boot Loader" replaced only Stage 1. This document covers two additions: pinned firmware entries in the sealed policy, and slots, which move an existing installation to newer startup firmware without erasing Linux.

## Pinned entries

macOS 27.2 (26B123) and 27.2.1 (26B131) report the same iBoot version, `mBoot-20457.41.3`, but their DCP and SEP firmware differ. A version string can't tell them apart, so a policy entry may carry a `pin`:

| Field | Meaning |
| --- | --- |
| `build` | `BuildNumber` of the build identity the stub is made from; the source file name must end in `_<build>_Restore.ipsw`. |
| `sourceBytes` | The image's whole size as Apple's server reports it. Checked before any member is read. |
| `manifestSHA256` | SHA-256 of the image's `BuildManifest.plist`. Checked when the stub plan reads it, with the build number of the selected identity. |

`NativeFirmwareSelection` carries the pin to `NativeStubFilePlan`, which refuses a mismatch as `pinnedSourceMismatch` before any disk change ("Apple's server returned a different macOS restore image than build 26B123. Nothing on the disk changed."). Entries without a pin behave as before.

The 26B123 entry (`UniversalMac_27.2_26B123_Restore.ipsw`, 25,595,669,503 bytes) is last in the list. Selection keeps the last compatible entry, so a board listed in it takes 26B123 whenever its macOS is 27.2 or later (`minimumBoot` `mBoot-20457.41.3`, `minimumRecovery` `26.2.123.0.0,0`). A Mac below macOS 27.2 keeps its older entry rather than being told to update.

### Which boards

The entry starts with no models. `scripts/firmware-qualification.json` lists the boards admitted to each pinned build, each with the kernel release that shipped its support for that firmware, the distributions carrying it, and a link to the hardware result. `scripts/tests/test_firmware_qualification.py` requires the entry's `models` to equal that list, refuses a null model list (which would admit every Mac), and checks the pin fields against the record. Adding a board is a two-line change, reviewed with its evidence.

Release templates don't set `supported_fw`, so the model list is the only gate. A release that wants to hold a board back can still list older versions in `supported_fw`.

### Checks

- `NativeStartupFirmwareTests` covers the sealed entry, selection for a listed and an unlisted board, the macOS floor, a renamed source, and the 26B131 size, manifest and build refusals.
- `AURORA_LIVE_FIRMWARE_PIN=1 swift test --filter testOptInLivePinnedImagePlansEveryLabBoard` reads Apple's image (size, directory, manifest; about 35 MB) and plans the stub for the M1 Pro, M2, M4 Pro and MacBook Neo identities with the pin in force. It writes nothing.

## Slots

A slot is a second startup container, made from the pinned image, beside the installation's own. Its Recovery inputs name the installation's EFI partition and the Stage 1 it already enrolled, so both containers start the same Stage 2, kernel and root file system. The old container stays bootable until the owner removes it, which gives a way back while kernel support for the new firmware settles.

A slot is also the only way to move M1, M2 and M3 installations: their stub containers are 2.5 GB, a 26.0 or later stub needs 6 GB (`stubBytes`), and the EFI partition follows the container, so it can't grow in place.

### Plan (`NativeStartupFirmwareSlot`)

`decide(installation:slots:target:space:)` is the pure part, tested without disks:

- The target must be pinned. The current build comes from `asahi/stub_info.json` on the EFI partition (`manifest_info.build_number`, `system_version.ProductVersion`), which every installer since the native stub stage writes. Without it the installation is refused rather than guessed at.
- Same build: nothing to do. Older target: refused. A slot with the target build already: reported, nothing created. A slot with another build: refused until it is removed.
- Placement: the free extent right after the installation, then the smallest free extent that fits, then a macOS resize of exactly the slot's size. Extents are used from their 1 MiB-aligned start.
- Steps, in order: shrink macOS (if needed), create the container, restore the stub from the pinned image, stage Recovery inputs naming the installation's EFI partition, write the slot's vendor firmware, then the owner's enrollment in the slot's Recovery.

### Vendor firmware

The vendor firmware on the EFI partition (`vendorfw/`, `asahi/all_firmware.tar.gz`) is built from the stub's files plus this Mac's own calibration. A slot doesn't replace it. Its set goes to `aurora/firmware/<build>/` on the same partition, and `aurora/firmware/slots.json` maps the firmware version the device tree reports (`chosen/asahi,os-fw-version`, for example `27.2.0`) to that build. An initramfs that knows the index loads the matching set; one that doesn't keeps loading the top-level set, as today. When the old container is removed, the slot's set becomes the top-level set.

### What the owner does

The same as after a fresh install: shut down, hold the power button until the startup options appear, choose the slot's volume ("Aurora Fedora Remix 27.2"), and let its Recovery enroll Stage 1 with the owner's password (`bputil` and `kmutil configure-boot`, as the installation's own Recovery does). The Mac then starts the slot. To go back, choose the old volume in the startup options, or run `asahi-bless` from Linux.

### Not built yet

The planner, the pin and the selection rules are in place; the executor isn't wired. Before a slot can be made from the app:

1. A helper operation `startupFirmwareSlot` that reuses the fresh-install APFS, stub-file and staging-space stages against a container-only plan, with its own journal and transcript like `NativeStage1UpdateCoordinator`.
2. Recovery inputs for the slot copied from the installation's (`install-config.json` with the slot's system, group and Preboot UUIDs and the same `espUUID`; the enrolled `AuraPayloads`).
3. Slot vendor firmware: run the vendor stage against the slot's stub into `aurora/firmware/<build>/` and update `slots.json`.
4. Recognition and removal: a slot is an Aurora stub container whose Recovery names a recognized installation's EFI partition. Erase Linux and Reset must remove it with the installation; removing the old container alone must keep the EFI partition (the erase rule already keeps an EFI partition a kept startup container names) and promote the slot's vendor firmware.
5. Distribution initramfs: load `aurora/firmware/<build>/` when `slots.json` names the booted firmware version.
6. App: an "Update startup firmware" action beside "Update Boot Loader", shown only when the selection for this Mac is a pinned build newer than the installation's.
