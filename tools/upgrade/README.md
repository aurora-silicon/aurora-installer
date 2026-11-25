# Upgrading the startup firmware of an installed system

The startup firmware is the small macOS ("stub") that your Mac starts before Aurora's boot loader. An installation keeps the one its installer chose. `aurora-upgrade` moves it to the newest version the installer supports for your Mac (today macOS 27.2, build 26B123) and puts the current Aurora boot loader (Stage 1) in place, without reinstalling Linux.

Status: the Linux side is here. The Recovery side (the in-place swap and Stage 1 enrollment) is built on the Recovery-first changes but has not run on a Mac yet, so `stage` is for testing only. Design: [UPGRADE-FLOW.md](UPGRADE-FLOW.md).

## What you do

1. `sudo aurora-upgrade plan` shows what would change. It writes nothing.
2. `sudo aurora-upgrade stage --payload <release>` asks you to type `UPGRADE`, then puts the Aurora Installer and the new Stage 1 on your startup volume. On M1 and M2 Macs whose startup volume is 2.5 GB it first moves the EFI partition (0.5 GB) into free space just before the startup volume, so Recovery can grow the startup volume into its place; the EFI partition keeps its identity and contents, and Linux starts as before.
3. Shut down. Hold the power button until the startup options appear and choose the Aurora volume. Join Wi-Fi when asked and type the Mac owner's password. Recovery replaces the startup firmware with Apple's macOS 27.2, puts the new Stage 1 in place and starts Linux.

Linux, your files and macOS stay as they are, and until the last step Linux still starts as it does now. Changed your mind before step 3? `sudo aurora-upgrade cancel` puts the volume back as it was. If your startup volume is too small for the swap, `plan` says so; then the upgrade makes a second startup volume next to it and takes a second visit.

## What it checks first

It stops, and changes nothing, when: this isn't an Aurora system started by Stage 1; the EFI partition's `asahi/stub_info.json` doesn't name the volume the Mac started from; the installer doesn't admit your Mac to the new firmware yet; your system firmware is older than the new version needs (update macOS first); the startup volume is too small for the swap and there are no 6 GB of free disk space for a second one; the EFI partition has under 100 MB free; another startup volume of that size already exists; or a different upgrade is already staged.

## What it writes

- Partition table: only when the plan moves the EFI partition, its entry's start (same entry, ID, type, name; the bytes are copied and checked first, and `cancel` moves it back).
- EFI partition: `aurora/upgrade/request.json` (the plan) and `journal.json` (each step, written before it is taken).
- The current startup volume's System volume, through apfs-linux-rs: `Aurora Installer.app`, `Aurora/Recovery/UpgradeData/` (the plan and the release's Stage 1), `SystemVersion.plist` renamed to `SystemVersion-disabled.plist`, and the `.IAPhysicalMedia` marker, last. Every file is written beside its name and renamed in, so a power cut leaves either the old state or a state `stage` finishes and `cancel` undoes.

Linux writes nothing else: not macOS, not Linux's partitions or boot entries, no other partition entry, NVRAM, Preboot, Recovery or a startup security policy.

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now, 3 internal error. Tests: `make check`.
