# Upgrading an installed system's startup firmware and Stage 1

Status: design. The Linux side (`aurora-upgrade`) is built; the Recovery upgrade mode is not.

## 1. What the user does

1. In Linux: `sudo aurora-upgrade stage`. It checks the Mac, says plainly that this is a breaking change, and goes on only after the user types `UPGRADE`. `aurora-upgrade plan` does every check, prints the plan and writes nothing.
2. Shut down. Hold the power button until the startup options appear and choose the Aurora volume. Its Recovery opens the Aurora Installer in upgrade mode. Join Wi-Fi, type the Mac owner's password. Recovery replaces the startup firmware with Apple's macOS 27.2, enrolls the new Stage 1 and restarts into Linux.
3. First Linux boot on the new firmware: `aurora-upgrade finish` (a oneshot unit) checks the boot came from the upgraded firmware and closes the request.

One visit, one startup volume. A second startup volume ("slot", section 9) is the fallback only for a container too small for the swap.

## 2. The space facts that decide it

Measured with our APFS driver in real stub containers (bytes allocated):

| Mac | stub | container | used | Recovery | Preboot | System |
| --- | --- | --- | --- | --- | --- | --- |
| M3 MacBook Air (J615) | 27.2 | 6.00 GB | 1.88 GB | 1.50 GB | 0.21 GB | 0.15 GB |
| M2 Mac mini (J473) | 27.2 | 6.00 GB | 1.80 GB | 1.47 GB | 0.16 GB | 0.15 GB |
| M2 MacBook Air (J413) | 13.5 | 2.50 GB | 1.05 GB | 0.81 GB | 0.22 GB | 0.002 GB |

- A 27.2 stub needs about 1.8 GB. The installer's 6 GB (`stubBytes` for 26.0 and later) is our own room, not Apple's need; the System volume bytes are the installer's own payload copies.
- So a 27.2 stub fits a 2.5 GB M1/M2 container with room to spare, but only if the old Recovery image is replaced before the new one is written. Keeping both side by side would need about 2.85 GB.
- `aurora-upgrade` computes the peak for each Mac from its own container (`apfuse info/space/walk`) and the pinned image's Recovery member (read from Apple, after checking the image size and manifest hash): used − old Recovery image + new Recovery image + a second Preboot + the staged payload + the installer's 512 MiB Recovery room. On the lab J413: 2.44 GB of 2.50 GB.

## 3. Who does what

| Step | Where | Code | Writes |
| --- | --- | --- | --- |
| Plan | Linux | `aurora-upgrade plan`: selection rules from the installer's sealed policy (`NativeInspectionPolicySource.swift`, extracted at install) and `firmware-qualification.json` | nothing |
| Stage | Linux | `aurora-upgrade stage` through apfs-linux-rs (`apfuse-mount`) | section 4.1 |
| Upgrade | the stub's own Recovery (power button) | Aurora Installer.app `upgrade` mode: the Recovery stub writer (#202, #207, #194) in place, then the existing setup path (`bless`, `bputil -nc`, `kmutil configure-boot`) | section 4.2 |
| Finish | Linux, first boot | `aurora-upgrade finish`, `aurora-wifi-firmware` (follows `/chosen/asahi,os-fw-version`) | ESP |

## 4. What changes on disk

### 4.1 Linux stage
- ESP: `aurora/upgrade/request.json` (the plan, with its sha256) and `journal.json` (each step, written before it is taken).
- The stub's System volume: `Aurora Installer.app` (older copy kept beside for cancel), `Aurora/Recovery/UpgradeData/` (the plan and the release's unfilled Stage 1; Recovery fills it for this ESP with the installer's own code), `SystemVersion.plist` → `SystemVersion-disabled.plist`, and the `.IAPhysicalMedia` marker last ({AppName "Aurora Installer.app", ProductBuildVersion "00A191", ProductVersion "12.1"}).
- Measured on a J413: a normal restart with this staged still starts Linux; `aurora-upgrade cancel` gives back the exact tree.

### 4.2 Recovery, in place, in this order
1. Recheck the request against this volume group, chip and ESP; read Apple's image size and manifest hash (nothing changes if Apple serves anything else or there is no network).
2. Plan the stub files for this board's Customer/Erase identity (`RestoreImageStubPlan`, the Recovery port of `NativeStubFilePlan`).
3. Preboot: write the new restore bundle as `<group>/Restore.new` (trimmed BuildManifest, Bootability, trust caches, manifest components), then swap names (`Restore` → `Restore.old`, `Restore.new` → `Restore`). The personalized boot files under `<group>/boot/` are not touched yet, so Linux still starts from the old ones.
4. Recovery volume: remove the old Recovery image, write the new one (decoded from the image's AEA archive, stored compressed). From here until step 6 the stub's own Recovery is the new one; the Mac's system Recovery is always there.
5. System volume: `bootcaches.plist`, `PlatformSupport.plist`, stub `SystemVersion.plist` (27.2), the `Restore` link.
6. `bless` with the owner's password: Apple personalizes the 27.2 boot files for this Mac (network).
7. `bputil -nc` and `kmutil configure-boot -c aura-boot.macho -v <volume>` (Stage 1 b17; unpadded on M1-M3), the existing setup sequence.
8. Remove `Restore.old`, record the receipt, update `asahi/stub_info.json` on the ESP, put the marker away, restart into Linux.

## 5. What is never touched
- macOS: container, volumes, Preboot, LocalPolicy, FileVault, users and data.
- Linux: `/boot`, the root file system, boot entries, the kernel. Stage 2 on the ESP (it already starts on 13.5 and 27.2 firmware).
- The partition table, the system Recovery, NVRAM other than what `bless` sets, any other startup volume.

## 6. Version jump and the paired Recovery
- The stub's Recovery image and its boot files come from the same pinned image as the stub's boot files, so after the upgrade the group boots a 27.2 Recovery paired with 27.2 firmware.
- The upgrade runs in the old (13.x) Recovery, which is already in memory when step 4 replaces its image.
- Floors: system firmware ≥ the target's `minimumBoot` (Linux reads `/chosen/asahi,iboot1-version`); Recovery checks the system Recovery version before step 3. Below it: update macOS first; without macOS and below the floor: refused.
- The board must be admitted to the pinned entry (qualified or experimental in `scripts/firmware-qualification.json`). The warning shows the board's recorded caution.

## 7. Refused before anything changes
Not started by Stage 1; `asahi/stub_info.json` doesn't name the booted group; board not admitted; system firmware below the floor; already on the target or newer; peak above the container and no room for a slot; ESP under 100 MB free; no room on the System volume for the payload; a foreign marker; a different plan already staged; Apple serves a different image; no network; no owner who can approve (a whole-disk install without a finalized recovery account).

## 8. Failure and the way back
| When | State | Way back |
| --- | --- | --- |
| Plan, or Linux stage cut short | old stub boots Linux; files written beside then renamed, marker last | `aurora-upgrade cancel` or rerun |
| Restart after staging | Linux starts as before (measured) | `aurora-upgrade cancel` |
| Wrong volume picked | macOS starts, or another volume's Recovery finds no request for it | shut down, pick again |
| Wrong password / no network | nothing written past step 1 | retry |
| Power loss in steps 3-5 | Linux still starts (old boot files, old LocalPolicy); the group's Recovery may be half written | power button → Aurora → Recovery reruns the request (each step adopts finished files); if the group's Recovery doesn't start, the system Recovery can rerun it from the stub (`aura` command) |
| Step 6/7 refused | Linux still starts from the old boot files; nothing enrolled | rerun; the Recovery the group now boots is 27.2 |
| Linux misbehaves on 27.2 | upgraded | report; returning to 13.5 is a reinstall of the stub (no second volume to fall back to in this path) |

## 9. Fallback: a second startup volume
Only when the computed peak doesn't fit the container: the installer's startup firmware slot (`macOS/docs/startup-firmware-update.md`), a 6 GB-class container in free space beside the old one, which stays as the way back. It needs a second power-button visit (the new volume's own Recovery enrolls Stage 1). The warning says so.

## 10. Sizing new installs
New stubs can shrink from 6 GB to the measured need plus one in-place Recovery swap and, on M4 and later, the padded Stage 1 (about 3.5 GB). Separate change, with an M4 check.

## 11. Open questions (to settle on hardware)
1. Answered on a J413: a staged marker on the default, enrolled stub leaves a normal restart alone.
2. Does the running 13.x Recovery accept `bless` + `kmutil configure-boot` against the group's new 27.2 files in the same visit? If not, the user enters the (now 27.2) Recovery once more; still one volume.
3. AEA decode inside a 13.x Recovery: the key unwrap is ours (#194); the stream decode is the open part of #207.
