# Image 2 from the signed candidate set 99ace4070

Built 2026-09-26 (02:44–03:00 AEST) on the M1 Pro's Omarchy side by `image-builder/bin/build-mac-image` at `d1eef33` (clean tree), from the signed test candidate set `apple-test-99ace4070354-20260926` (omacom/omarchy-mac#555: omarchy-mac `99ace4070354`, signer `E11E851AF82E02AEF54C8794599A6024E3D35379`). The set carries the runtime built from that commit, omarchy-mac-boot 20260925-3 and the boot packages from omacom edge, and the 35 other packages of the Apple default set's closure that the Apple repository order takes from edge (44 in all).

| | |
| --- | --- |
| Payload | `omarchy-2026.09.25-aarch64-apple-silicon-mac-edge-os-package.zip`, 3,568,410,221 bytes |
| sha256 | `3b975200296c139f316e44a6b3c78b40aeb0e6920ae8a8bade2f3b84eff12221` |
| Location | `omarchy-m1-pro:/var/tmp/omarchy-images/apple-test-99ace4070354-20260926/image/`, beside the inputs record, the candidate set and the package cache that rebuild it; a copy (sha256 checked) on the owner's Mac under `~/dev/omarchy/outputs/image2/` for the next M2 Max reinstall |
| Inspection | passed, 17 checks (`INSPECTION`), including `boot-splash`, `snapshots`, `pacman-config` and `installed-system` with the speaker stack |
| `package_set_sha256` | `f697d5f5a9dfa1495acfceba7eac7ddc500ca5e626230ca70f4360b6fd0e481e` (927 packages) |
| Hardware setup | deferred to first boot (omacom/omarchy-mac#528) |
| Test image pin | `IgnorePkg = omarchy omarchy-mac omarchy-settings` in `/etc/pacman.conf`, marked test-image-only |

Not installed: `obs-studio`, which the pinned repositories do not carry for aarch64. Commits after `d1eef33` on this branch change the README and read `candidate_only` from the manifest instead of assuming it; the importer already refuses any other set, so the image is the same.

## VM acceptance

`tools/acceptance/mac-image/run` from omacom/omarchy-mac branch `mac/28-update-case` on the M1 Pro (KVM, generic ALARM kernel 7.2.3 with the image's initramfs hooks, Apple root compatible). `run.txt` of the two runs that count is in `acceptance/`; serial and guest logs stay in `~/vm-evidence/mac-image-<run-id>/` on the M1 Pro.

| Scenario | Result |
| --- | --- |
| first-boot | passed: install.conf consumed, the deferred Limine step rebuilt the menu and UKI, owner setup and console login; Plymouth theme `omarchy` in the configuration and the UKI's initramfs; `/.snapshots` a btrfs subvolume. Default audio sink skipped: no Apple audio device in a VM |
| conversion | passed: LUKS2 in the initrd (56 s), re-keyed to the owner's password and a recovery key in two slots, temporary key gone, Limine unlocks with no key file |
| second-boot | passed: a wrong password refused, the owner's unlocks to the login prompt |
| password-change | one known failure: `omarchy-drive-password` finds no encrypted drive until root has run `blkid` (fixed by omacom/omarchy-mac#556, after this set's commit). With the harness's `sudo blkid` first, the new password opens the disk, the old one does not, the recovery key stays, and the next boot logs in the owner and root with it |
| update | passed: `omarchy update -y` exits 0 with the boot files verified by update-verify and a snapshot taken. Nothing was newer than the image's databases, and pacman ignored edge's `omarchy` and `omarchy-settings` 4.0.2-1, so the set's runtime stayed. The updated disk boots to the login prompt |
| snapshot-restore | skipped: the image has no `/etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check` (ticket 36) |
| factory-reset | skipped: omarchy-mac-boot 20260925-3 has no `/usr/lib/omarchy/mac-boot/reset-prepare` (omacom/omarchy-mac#552 ships in the next re-pin) |

Runs: `image2-99ace40-20260925T171639Z` (harness `64b7c48`) ran every scenario. Its update case reported the pinned `omarchy` missing because the console's escape sequences hid the first `pacman -Q` line; the harness now strips them, and `image2-99ace40-update-20260925T174237Z` (harness `8836e7a`) passed update. An earlier run stopped the conversion guest 40 s after owner setup, before btrfs had committed the setup log's last lines; the harness now waits 75 s.

Also seen in the serial logs: `omarchy-mac-encrypt.service` reports `Failed to parse output specifier ... journal+kmsg` (fixed by omacom/omarchy-mac#556), and speakersafetyd fails without an audio device.

This is VM acceptance, not hardware qualification: GPU, audio, Wi-Fi, suspend and the boot chain before the kernel are checked on the Macs.
