# Upgrading an existing Aurora install: new startup macOS + new Stage 1

Status: design. The Linux side (`aurora-upgrade`) is built; the Recovery upgrade mode is not.

## 1. What the user does

1. In Linux: `sudo aurora-upgrade`. It checks the Mac, prints what will change, and says plainly that
   this is a breaking change. The user types `UPGRADE` to go on. `aurora-upgrade plan` does every
   check and prints the plan, and writes nothing.
2. Linux stages the upgrade and asks the user to shut down.
3. **Visit 1.** Hold the power button and pick the current **Aurora** volume. Its own Recovery opens the
   Aurora Installer in upgrade mode. The user joins Wi-Fi, types the Mac owner's password once. The
   installer makes the new startup volume ("Aurora 27.2") from Apple's macOS 27.2 restore image and
   shuts down.
4. **Visit 2.** Hold the power button again and pick **Aurora 27.2**. Its Recovery (macOS 27.2) asks for
   the owner's password and enrolls the new Stage 1 (`bputil` + `kmutil configure-boot`), then restarts
   into Linux. Linux, the user's files and macOS are as they were.
5. First Linux boot on the new firmware: `aurora-upgrade` runs once more by itself (`aurora-upgrade finish`) to
   switch the Wi-Fi/Bluetooth firmware to the 27.2 set and report the result.

Why two visits and not one: see section 2. On Macs whose stub can't be replaced in place (every M1, M2
and M3 install made with a 13.x stub) there is no way to make the new volume from Linux, and Stage 1
can only be enrolled from the new volume's own Recovery, entered with the power button.

## 2. The decision: a second startup volume ("slot"), not an in-place rewrite

Facts that decide it:
- A 13.5 stub container is 2.5 GB (`stubBytes` 2,499,805,184). A 26.0 or later stub needs 6 GB
  (5,999,951,872). The ESP sits right after the stub container, so it can't grow. On the J413 the stub
  is `nvme0n1p3` (2.3 GiB) with the ESP `p4` right behind it.
- Our APFS driver reads and writes volumes macOS made. It has no `mkfs`/`newfs_apfs` and no way to make
  a container, volume group or volume roles, by design (`apfs-linux-rs/docs/installing.md`, `asahi.md`).
- The stub's boot files are personalized for this Mac by Apple's tools (`bless`, and `bputil`/`kmutil` for
  the LocalPolicy) with the owner's password. Linux can't do that.
- The installer already has a design for exactly this: **startup firmware slots**
  (`macOS/docs/startup-firmware-update.md`). Planner, pin and journal are merged
  (`NativeStartupFirmwareSlot.decide`); the executor isn't wired. The slot design says a slot is the only
  way to move M1-M3 installs.
- An in-place rewrite would also overwrite the stub's own Recovery, so a failure halfway leaves no
  working Recovery for that volume group and no way back. A slot leaves the old volume untouched.

So the upgrade is the slot executor, driven from Linux, with the macOS-only steps done in Recovery by
the installer's own code. One implementation: Linux decides and stages; Recovery runs the installer's
existing stub-file, staging and enrollment code.

## 3. Who does what

| Step | Where | Code (reused / new) | Writes |
| --- | --- | --- | --- |
| Preflight + plan | Linux | new `aurora-upgrade` (Python, `tools/upgrade/` in aurora-installer), same rules as `NativeStartupFirmwareSlot.decide` and `NativeFirmwareSelection` (read from the installer's sealed policy JSON, not copied) | nothing |
| Stage | Linux | `aurora-upgrade`, apfs-linux-rs (`apfuse-mount` rw) on the **old** stub's System volume; ESP via plain vfat | see 4.1 |
| Visit 1: make the slot | old stub's Recovery (13.x) | Aurora Installer.app, new `upgrade` mode: `diskutil` for the container and volumes (as `NativeStubVolumes`), Recovery-first stub writer (#202/#207/#194), Recovery inputs (as `NativeRecoveryInstallation`), `bless --setBoot` with the owner | new container; old stub's marker back to normal |
| Visit 2: enroll | slot's Recovery (27.2) | the existing Recovery setup path, unchanged (`bputil -nc`, `kmutil configure-boot`, receipt) with `bootstrap: source-volume-owner` | slot's LocalPolicy |
| Finish | Linux, first boot on 27.2 | `aurora-upgrade finish`: `aurora-wifi-firmware` (follows `/chosen/asahi,os-fw-version`), stub_info, report | ESP vendorfw |

## 4. What changes on disk

### 4.1 Linux stage (step 2)
On the **ESP** (vfat, already writable from Linux):
- `aurora/upgrade/request.json`: target pin (build `26B123`, `sourceBytes` 25,595,669,503,
  `manifestSHA256` 0fbfae04…2510, URL on updates.cdn-apple.com), board/chip, the chosen free extent
  (start, size, 1 MiB aligned), the ESP PARTUUID, the old stub's group UUID, the new Stage 1 digest,
  plan digest. Written to a temp name, fsynced, renamed.
- `aurora/upgrade/journal.json`: step log, appended by every later step (Linux and Recovery).
- No change to `m1n1/boot.bin` (Stage 2). The current Stage 2 must already start on both 13.5 and
  27.2 firmware; preflight checks its version against the minimum that does (aura b17 on the J413).

On the **old stub's System volume** (apfs-linux-rs, `rw,experiment` mount of that one volume; the stub is
not sealed or encrypted):
- `Aurora Installer.app` from the release (replaces any older copy by write-beside-then-rename).
- `Finish Installation.app/Contents/Resources/step2.sh`: the relative launcher (same bytes the main
  installer writes).
- `Aurora/Recovery/InstallData/` built beside and renamed in: `upgrade-config.json` (copy of the request
  + the slot's Recovery inputs template) and `AuraPayloads/` (aura b17 Stage 1 Mach-O for this chip,
  manifest with sha256).
- Arm the launcher exactly as Update Boot Loader does: `.IAPhysicalMedia` = {AppName "Aurora
  Installer.app", ProductBuildVersion "00A191", ProductVersion "12.1"}, and `SystemVersion.plist` →
  `SystemVersion-disabled.plist`. The old values are kept beside as `*.aurora-upgrade-prev` so Recovery
  (or `aurora-upgrade cancel` from Linux) can put them back.
- Nothing in Preboot, Recovery, iSCPreboot, NVRAM, the LocalPolicy or the partition table.

### 4.2 Visit 1 (old stub's Recovery)
- New GPT partition + APFS container in the chosen free extent (`diskutil addPartition` or
  `apfs createContainer` on a partition made there), 5,999,951,872 bytes.
- Volumes as `NativeStubVolumes`: Data → "Aurora 27.2 - Data", System "Aurora 27.2" grouped with it,
  Preboot, Recovery.
- From the pinned 26B123 image, for this board's Customer/Erase identity (J413 = `j413ap`, chip 0x8112,
  board 0x28), the files `NativeStubFilePlan` picks (Recovery port `RestoreImageStubPlan`, #202):
  - System: `usr/standalone/bootcaches.plist`, `System/Library/CoreServices/PlatformSupport.plist`,
    stub `SystemVersion.plist` ("27.2 (stub)"), `Restore` link to Preboot.
  - Preboot `<group>/Restore/`: SystemVersion, RestoreVersion, bootcaches, trimmed BuildManifest
    (one identity), the Bootability tree + trust cache, the restore manifests (incl. the apticket),
    every boot component the manifest names (kernelcache, iBoot, coprocessor firmware im4p, trust
    caches); Preboot `<group>/var/db/AdminUserRecoveryInfo.plist` from the source owner's Preboot.
  - Recovery `<group>/usr/standalone/firmware/arm64eBaseSystem.dmg`: the image's own BaseSystem
    (AEA; decoded with the key from Apple's key server, #194; stored compressed).
  - About 76 MB plus the Recovery image (≈1.1-1.3 GB) on J615/J713.
- Slot `Aurora/Recovery/InstallData/install-config.json` (schema 2) with the slot's System/group/Preboot
  UUIDs, the **same ESP** UUID, `bootMode` `macho`, `stage2Path` `m1n1/boot.bin`, `bootstrap`
  `source-volume-owner`; `AuraPayloads/` copied from the staged one; `Aurora Installer.app`; launcher;
  `.IAPhysicalMedia` armed on the slot.
- `bless --setBoot --mount <slot System> --user <owner>` (owner password typed in the app). This is
  where Apple personalizes the slot's boot files (network needed).
- Old stub: `.IAPhysicalMedia` and `SystemVersion.plist` put back (prepareForStartup), so the old
  volume boots Linux exactly as before. Then `shutdown -h`.

### 4.3 Visit 2 (slot's Recovery)
- The existing setup sequence: Stage 1 staged into `Aurora/Recovery/State/<op>/`, `bputil -nc -v
  <slot group>`, `kmutil inspect` (kcbz 0 on M1-M3), `kmutil configure-boot -c aura-boot.macho -v
  <slot>`, receipt `installation.json`, launcher disarmed, SystemVersion visible, recovery account
  form, restart. This adds one LocalPolicy for the slot's group in iSCPreboot. The old stub's
  LocalPolicy and macOS's are not touched.

### 4.4 First Linux boot on the slot
- `aurora-upgrade finish` (oneshot unit that runs only while `request.json` is open): checks
  `/chosen/apfs-preboot-uuid` == the slot group and `asahi,os-fw-version` == 27.2; runs
  `aurora-wifi-firmware` (radio firmware from the pinned image, merged #226) so vendorfw matches 27.2;
  writes `asahi/stub_info.json` for the slot (old one kept as `aurora/firmware/22G74/stub_info.json`);
  marks the journal done. If any check fails it changes nothing and says how to go back.

## 5. What is never touched
- macOS: its container, volumes, Preboot, LocalPolicy, FileVault state, users and data. Not mounted
  read-write by anything here.
- Linux: `/boot`, the root file system and home, GRUB/BLS entries, the kernel. (The kernel already
  runs on both firmware versions; preflight checks it is a fleet/release kernel that does.)
- The old stub's Preboot, Recovery and LocalPolicy. Only its System volume gets the staged app, the
  launcher and the marker, and visit 1 puts the marker back.
- System Recovery (`RecoveryOSContainer`), iSCPreboot except the one new LocalPolicy, NVRAM except
  what `bless --setBoot` itself sets (the startup disk).
- Stage 2 on the ESP.

## 6. The version jump and the paired Recovery
- The slot's Recovery is the BaseSystem of the same pinned image, so the slot always boots a 27.2
  Recovery paired with its 27.2 boot files. Nothing ever mixes 13.5 boot files with a 27.2 Recovery.
- Visit 1 runs in the **old** stub's 13.x Recovery. It only uses `diskutil`, file writes, HTTPS range
  reads and `bless`, all present in 13.x; the Recovery app builds for macOS 13.0+
  (`Recovery/build-app.sh` LSMinimumSystemVersion 13.0).
- iBoot floors for a 27.2 stub, checked before staging: system firmware ≥ `mBoot-20457.41.3`
  (Linux reads `/chosen/asahi,iboot1-version`), system Recovery ≥ 26.2.123 (from the policy; Linux
  can't read SFR, so it takes system firmware as the proxy and Recovery checks the real value before
  any disk change). If macOS is present and older, the user is told to update macOS first. A Mac
  without macOS and with old system firmware is refused: there is nothing to update it from Linux.
- The board must be in the 26B123 entry's `models` (qualified or experimental in
  `scripts/firmware-qualification.json`). J413 is not admitted yet; until it is, the command refuses it.
- Known regressions to list in the warning, from the selection data, not hard-coded per board: on
  T8112 the ANE does not run on 27.2 yet. The warning text comes
  from the qualification file's `caution` for the board.

## 7. Refused states (preflight; each says why in one line and what to do)
- Not booted from an Aurora stub, or `/chosen/apfs-preboot-uuid` doesn't name a stub whose
  `asahi/stub_info.json` agrees (vgid). Without `stub_info.json`: refused, never guessed.
- Current build already the target, or newer: nothing to do. A slot that already holds another build:
  refused until it is removed. A half-made slot from an earlier run: offered as "resume" (Recovery
  adopts identical files, #207) or "remove".
- Board not admitted to the pinned entry, or system firmware below the floor.
- No free extent ≥ 6 GB (1 MiB aligned). Linux offers, but doesn't do silently: for a whole-disk
  install, shrink the btrfs root and its partition from the end (`aurora-whole-disk` code). With macOS
  present, it says how much to free in macOS (macOS shrink is a macOS/Recovery job, not Linux).
- Less than 2 GB free on the old stub's System volume for the app + payloads (measured: app ≈ 30 MB).
- ESP with less than 100 MB free (rule: ESP keeps ≥ 100 MB).
- More than one Aurora stub group already (a previous slot, an Asahi second install): refused unless
  the user names the one to upgrade (`--stub <group>`); the booted one is the default.
- FileVault: the stub volumes are never encrypted; refused if they are. macOS FileVault doesn't matter
  (not mounted), but the owner password typed in Recovery is the macOS owner's (whoever can unlock
  macOS), and the warning says so.
- No owner known: on whole-disk installs the stub's recovery account must be a finalized volume owner
 . Otherwise refused: there would be no one who can approve.
- The APFS driver can't mount the stub System volume read-write cleanly (dirty container, checkpoint
  mismatch, unknown feature flags): refused; nothing written.
- No network in Linux (it fetches the release payload and checks Apple's image size and manifest
  hash once). Visit 1 needs Wi-Fi too; the warning says so.

## 8. Failure and rollback at each step
| When | What happens | How the user gets back |
| --- | --- | --- |
| Preflight / dry-run | nothing written | - |
| Power loss during Linux stage | Every file is written beside and renamed in; the marker is the last write. Before it, the old stub boots Linux as before and `aurora-upgrade` resumes or cancels. | nothing to do |
| After the stage, user just reboots | iBoot boots the old stub's enrolled Stage 1 (the marker only changes what Startup Options and Recovery show, as with Update Boot Loader). Linux comes up; `aurora-upgrade` says the upgrade is waiting. Measured on a J413 (Asahi-made 13.5 stub). | `aurora-upgrade cancel` puts the marker back |
| Wrong volume picked in Startup Options (visit 1) | macOS: boots macOS, nothing happens. System Recovery / "Options": Options opens the *default* volume's Recovery, which is the old stub, so it works. Another stub: its Recovery has no upgrade request for it and the app says so, changing nothing. | shut down, pick again |
| Wrong password (either visit) | `bless`/`bputil` refuse; the app asks again; no disk change follows a failed auth. | retype |
| No Wi-Fi / Apple unreachable in visit 1 | Before any disk change the app reads the image size + manifest hash; refuses with "Nothing on the disk changed". | join Wi-Fi, Retry |
| Power loss in visit 1 while writing the slot | Old stub untouched except its marker. The slot is half made; files are published by hard link only after their check, so a rerun adopts what is identical and finishes. | pick the old Aurora volume again; the app resumes. Or Cancel: removes the slot container and restores the marker |
| Power loss after the slot `bless`, before the old marker is restored | Default startup disk is now the slot (not enrolled): the Mac opens the slot's Recovery, which runs visit 2. | continue with visit 2, or pick old Aurora |
| Visit 2 fails (kmutil/bputil refuse, power loss) | No LocalPolicy change is recorded until enrollment succeeds (existing Recovery rule). The slot stays install media. | pick Aurora 27.2 again; or pick the old Aurora volume to boot Linux on 13.5 (`aurora-bless` it back as default from Linux) |
| Linux misbehaves on 27.2 (display, Wi-Fi, ANE) | Old stub is still enrolled and bootable. | Startup Options → old "Aurora", or `aurora-bless` from Linux. Removing the old stub later is a separate, explicit `aurora-upgrade --remove-old` (Recovery-side container delete; keeps the ESP) |
| macOS updates later | macOS updates its own group only (as today). | - |

Rollback of the whole thing = pick the old volume and delete the slot. The only thing that can't be
undone by files is the slot's LocalPolicy, and an orphan LocalPolicy for a removed group is harmless
(measured on the M2, `whole-disk-macos-removal`).

## 9. macOS present vs whole-disk, multiple stubs
- macOS present (J413): owner = the macOS owner via `source-volume-owner` (bound by UUIDs, as a fresh
  install). AdminUserRecoveryInfo comes from macOS's Preboot (not encrypted).
- Whole-disk (no macOS): owner = the stub's finalized recovery account. AdminUserRecoveryInfo is
  copied from the **old stub's** Preboot. The free extent comes from shrinking Linux. Supported only
  when the old stub is an Aurora install with a finalized recovery account; Asahi-made whole-disk
  installs are refused (no owner who can approve).
- Several stubs: the request names one old group; the slot names the same ESP; every other stub is
  left alone. `aurora-bless --list-volumes` shows them all.

## 10. What is new code and where
- aurora-installer `tools/upgrade/aurora_upgrade.py` (+ tests): preflight, plan, warning, confirm,
  dry-run, stage, cancel, finish. Reads the sealed policy JSON the Swift app builds from
  (`NativeInspectionPolicySource`), so the board list and floors have one source.
- aurora-installer Recovery: `upgrade` mode (read `upgrade-config.json`, run slot prepare, hand over to
  the normal setup path in the slot). Builds on #202/#207/#194; needs #207's pending parts (AEA decode
  + compressed Recovery image write, AdminUserRecoveryInfo, System Restore link, launcher, marker,
  receipts). These build on the Recovery-first work in #202 and #207.
- apfs-linux-rs: nothing new in the format code; package `apfuse-mount` (and the `apfuse` checker) for
  the distros; a `--volume-role System --group <uuid>` selector so the tool never picks by index.
- fedora-aurora (then alarm/nixos): package `aurora-upgrade` + `apfuse`, the `--finish` oneshot unit.
- aurora-distributions: plain-words user page "Upgrading the startup firmware".

## 11. Tests
- Host tests: plan/refusal table (every row of section 7), request/journal round trip, the stage's
  file set against a golden list, cancel restores bytes exactly, dry-run writes nothing (checked by
  hashing the disk image before/after).
- Disk-image rehearsal before any Mac: a GPT image with an APFS stub container made by macOS
  (apfs-linux-rs `harness/oracle` images, or a copy of the J413 stub's System volume layout), loop
  device, run `aurora-upgrade --stage` against it, then `apfuse` check + read back, and the macOS
  oracle (`fsck_apfs`) if a macOS is available to the harness.
- Hardware rows on an M2 MacBook Air (J413): see the PR.


## 12. Open questions (to settle by measurement, not guess)
1. Answered on a J413: with the marker armed on the default, enrolled stub, a normal restart starts Linux as before.
2. Does `bless --setBoot` of a new stub work from a 13.x Recovery with the macOS owner (it works from
   macOS and in the Recovery repair path)? First tried in C4; failure there changes no LocalPolicy.
3. #207's Recovery image write (AEA decode in Recovery) is unbuilt. Until it lands, visit 1 can't run.
