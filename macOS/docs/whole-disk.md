# Whole disk: removing macOS

Some owners want Aurora to have the whole internal disk. This is a destructive, one-way opt-in: macOS, its apps and its files are deleted, and the only way back is a DFU erase and restore. This page is the design; the user page is [aurora-distributions docs/whole-disk.md](https://github.com/aurora-silicon/aurora-distributions/blob/main/docs/whole-disk.md).

## What stays and what goes

Kept, always: Apple's iSC container (first partition: iSCPreboot with every OS's LocalPolicy, xART, Hardware), Apple's System Recovery container (last partition), this installation's startup container with its System, Data, Preboot and paired Recovery volumes, its EFI partition, the Linux partitions, other startup containers (firmware slots) and anything that isn't APFS. Deleted: exactly one APFS container holding a full macOS, recognized as a System volume and a Data volume in one volume group plus an Update volume. Installer-made startup containers have no Update volume.

Each OS's LocalPolicy is a per-volume-group directory in iSCPreboot, so deleting the macOS container leaves Aurora's policy untouched. A LocalPolicy whose group no longer exists is left behind and is harmless: lab Macs already carry one from deleted installs and boot normally. Measurements and citations: `traces/installer/20261121-whole-disk/README.md` on the lab store.

## Owner first

With macOS gone, every later startup-security change for Aurora (Stage 1 updates, startup firmware slots, `bputil`, `kmutil configure-boot`, `bless`) needs an owner of the startup container, authenticated in its paired Recovery. The first enrollment uses the macOS owner (`source-volume-owner` bootstrap), and that owner is deleted with macOS. So removal requires the Recovery account (Recovery Step 2) to be:

- `finalized` in its record,
- an APFS volume owner of the startup container's Data volume now (`diskutil apfs listUsers`, `RecoveryAccountInstaller.requireOwnership`),
- and the password typed at the confirmation must verify against its APFS credential (`diskutil apfs unlockVolume <data> -user <uuid> -verify`).

When the account is missing, removal stops before reading the disk and says why: with no account started, the app offers Create Recovery Account… (the existing Step 2 form) and the command names it; with one started but not authorized, both say to finish it in Startup Disk; with one whose creation was interrupted, both say to open Aurora Installer again to finish it. Only `finalized` goes ahead (`MacOSRemoval.ownerGate`).

Removal runs only in the installation's own paired Recovery (the same `bputil -d -v <group>` gate as enrollment), which proves that 1TR works before it becomes the Mac's only paired Recovery.

## Flow

Post-install ("reclaim macOS space"), from Aurora:

1. `sudo aurora-whole-disk plan`: a dry run. It reads the GPT, the APFS containers (read-only, `apfs_ro.py`) and `chosen/apfs-preboot-uuid` and `chosen/asahi,efi-system-partition` from the device tree, applies the same rule as Recovery, and prints what Recovery would delete and keep. It refuses (exit 3) when the startup container has no Aurora Recovery or no recovery account, naming the fix.
2. In the installation's paired Recovery (hold the power button, Options, Terminal): `'/Volumes/<name>/aura'` opens Aurora Installer, then Utilities → Remove macOS…; or in Terminal `'/Volumes/<name>/aura' remove-macos --dry-run`, then `'/Volumes/<name>/aura' remove-macos`. The menu item and the command run the same preparation (`prepareMacOSRemoval`) and deletion (`performMacOSRemoval`); the app shows the plan in a confirmation with Cancel as the default button and fields for the phrase and the password. Preflight, in order: paired-Recovery gate, owner record and ownership, this installation is the default startup disk, Find My off (no `fmm-mobileme-token-FMM` in NVRAM), one reading of the disk planned by `MacOSRemoval.plan`. It prints the plan and the consequences, asks for the exact phrase `remove macos and all its data`, then the owner's password (verified), reads the disk again and requires the same plan, journals, runs `diskutil apfs deleteContainer <partition>`, reads the disk again and requires that only the macOS partition went, then writes `aurora/whole-disk/removed.json` on the ESP.
3. Restart into Aurora. `aurora-whole-disk-claim.service` (or `sudo aurora-whole-disk claim`) checks the record against the disk (removed partition absent, the freed extent still free, the record names this ESP and startup container), creates one Linux partition in the freed extent, clears the old APFS signatures on it, and adds it to the btrfs root with `btrfs device add`. It records `aurora/whole-disk/claimed.json` and removes `removed.json`.

Fresh install ("whole disk" mode) is the same engine after a normal installation: install Aurora at the largest size the installer offers, finish Recovery setup including the recovery account and its Startup Disk authorization, then run steps 2 and 3. No separate executor exists for it, so there is one deletion path to qualify.

## From Recovery

Everything that deletes or authorizes happens in recoveryOS: enrollment, the recovery account (the owner from then on), and the removal. Recovery builds tell recoveryOS from a booted macOS by `/System/Installation/CDIS`, which only recoveryOS has (`RecoveryActions.inRecovery`); the paired-Recovery check (`bputil -d -v <group>`) then proves it is this installation's Recovery. In a normal macOS the menu item isn't there and the command refuses.

The macOS part of the installation (planning, partitioning, writing images, firmware) still runs in the macOS app. Starting the whole installer from macOS's Recovery with one command, before the Aurora installation exists, isn't built: the main app targets macOS 15 and has not been checked against recoveryOS's frameworks, and it hands privileged work to a helper it registers with launchd (SMAppService or SMJobBless); neither has been tried in recoveryOS.

## Why the space is added and not grown into

macOS sits before the startup container, so the freed extent is not adjacent to the root partition and the root partition can't grow into it. Moving the startup container or the ESP is out of the question. All Aurora distributions use a btrfs root with a separate ext4 /boot, so the freed extent becomes a second device of the root file system; the boot loader reads only /boot. A root on dm-crypt is refused (adding a plain partition would store data unencrypted) and a non-btrfs root is refused; in both cases the space stays free and nothing changes.

## Interruptions

- Before `deleteContainer` nothing is written except the Recovery journal `Aurora/Recovery/State/whole-disk-removal.json`.
- If `deleteContainer` fails and the disk still equals the plan, the journal is removed: nothing changed.
- If it fails part way, running `aura remove-macos` again checks the disk against the journal: the macOS partition gone and every kept partition exactly as recorded completes the record; anything else stops with the log.
- `claim` is idempotent: once `claimed.json` exists it reports that the space was already added.

## Consequences shown to the owner

macOS and macOS apps are gone. Apple software updates stop: the Mac's system firmware (iBoot1, `chosen/asahi,system-fw-version`) stays at its version, so update macOS first; Aurora's startup firmware is updated with startup-firmware slots, which need only the startup container's owner. Startup-security changes need the recovery account's password, in Aurora's Recovery. Getting macOS back means a DFU erase restore, from a second Mac (Finder or Apple Configurator) or from Linux (`idevicerestore -e -R`), followed by reinstalling Aurora.

## Tests

- `Recovery/Tests/MacOSRemovalCheck.swift` (in `Recovery/test-all.sh`): planner, freed extent, record, review/verify, the confirmation phrase, the owner step and the refusal cases on a fixture of a real M2 layout.
- `tests/test_whole_disk.py`: the Linux tool on a GPT image file with synthetic APFS containers.
- `tools/whole-disk/image-test.sh` (root): a loop-device image with 4096-byte sectors, synthetic Apple containers, real FAT/ext4/btrfs; simulates Recovery's deletion and runs the real `claim`.

Not yet run: `aura remove-macos` on a real Mac, and a boot after it.
