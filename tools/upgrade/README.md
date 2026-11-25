# Upgrading the startup firmware of an installed system

The startup firmware is the small macOS ("stub") that your Mac starts before Aurora's boot loader. An installation keeps the one its installer chose. `aurora-upgrade` moves it to the newest version the installer supports for your Mac (today macOS 27.2, build 26B123) and puts the current Aurora boot loader (Stage 1) in place, without reinstalling Linux.

Status: the Linux side is here. The Recovery side (making the new volume and enrolling Stage 1) is not built yet, so `stage` is for testing only. Design: [UPGRADE-FLOW.md](UPGRADE-FLOW.md).

## What you do

1. `sudo aurora-upgrade plan` shows what would change. It writes nothing.
2. `sudo aurora-upgrade stage --payload <release>` asks you to type `UPGRADE`, then puts the Aurora Installer and the new Stage 1 on your current startup volume.
3. Shut down. Hold the power button until the startup options appear and choose your current Aurora volume. Join Wi-Fi when asked and type the Mac owner's password. Recovery makes a new volume, "Aurora 27.2", from Apple's restore image, then shuts down.
4. Hold the power button again and choose "Aurora 27.2". Type the owner's password. The Mac starts Linux.

Linux, your files and macOS stay as they are. The old volume stays and still starts the same Linux: choose it in the startup options to go back. Changed your mind before step 3? `sudo aurora-upgrade cancel` puts the volume back as it was.

## What it checks first

It stops, and changes nothing, when: this isn't an Aurora system started by Stage 1; the EFI partition's `asahi/stub_info.json` doesn't name the volume the Mac started from; the installer doesn't admit your Mac to the new firmware yet; your system firmware is older than the new version needs (update macOS first); there are no 6 GB of free disk space outside every partition; the EFI partition has under 100 MB free; another startup volume of that size already exists; or a different upgrade is already staged.

## What it writes

- EFI partition: `aurora/upgrade/request.json` (the plan) and `journal.json` (each step, written before it is taken).
- The current startup volume's System volume, through apfs-linux-rs: `Aurora Installer.app`, `Aurora/Recovery/UpgradeData/` (the plan and the release's Stage 1), `SystemVersion.plist` renamed to `SystemVersion-disabled.plist`, and the `.IAPhysicalMedia` marker, last. Every file is written beside its name and renamed in, so a power cut leaves either the old state or a state `stage` finishes and `cancel` undoes.

Nothing else: not macOS, not Linux's partitions or boot entries, not the partition table, NVRAM, Preboot, Recovery or a startup security policy.

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now, 3 internal error. Tests: `make check`.
