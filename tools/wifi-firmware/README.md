# Wi-Fi and Bluetooth firmware of the stub firmware's release

Radio firmware is per-model, per-version data, so a Linux install takes it
from one source only: Apple's restore image (IPSW) of the macOS version its
stub firmware runs, for its board. The boot chain reports that version as
`/chosen/asahi,os-fw-version` (for example 26.6.2 or 27.2); the board is the
device tree's first compatible (`apple,j413`). Nothing is read from an
installed macOS: updating or erasing macOS changes nothing here.

`aurora-wifi-firmware` keeps the ESP's package on that restore image's set:

| Radio | macOS files | ESP package (`vendorfw/`) |
| --- | --- | --- |
| Broadcom Wi-Fi | `/usr/share/firmware/wifi` | `brcm/brcmfmac*` |
| Broadcom Bluetooth | `/usr/share/firmware/bluetooth` | `brcm/brcmbt*` |
| MediaTek MT7932 Wi-Fi | `AppleSunriseWLAN.dext/IZUBA`: patch, RAM, power profile, configuration | `mediatek/mt7932/` |
| MediaTek MT7932 Bluetooth | `/usr/share/firmware/bluetooth/MT7932*` | `mediatek/MT7932*`, `mediatek/mt7932/bt-*` |

A Mac follows the radios its ESP package carries today. The MT7932's
calibration (`oca2`, `wcal`, `btcal`), its Bluetooth address and the
regulatory policies are this Mac's own records; they stay as the installer
wrote them. The N1 firmware of the M5 and later Macs
(`apple/centauri/*-ftab.bin`) is not refreshed here either: the installer
makes it from the startup firmware's restore files, the kernel driver speaks
that firmware's protocol, and the file stays as the installer wrote it.

```sh
sudo aurora-wifi-firmware status    # board, ESP and running firmware, the restore image used
sudo aurora-wifi-firmware check     # dry run
sudo aurora-wifi-firmware update    # put the restore image's firmware on the ESP
sudo aurora-wifi-firmware revert    # put the files from before the last change back
```

After a `revert` the boot service leaves that build alone; `update`, or a
new stub firmware version, brings the firmware back.

The `aurora-wifi-firmware` service runs `boot` at every start-up, so a Mac
follows its stub firmware.

## What it does

1. **Which restore image.** `asahi_firmware.ipsw` lists the restore images
   of the stub's version (the packaged catalog `restore-images.json`, which
   holds every stub firmware the installer admits, then Apple's IPSW feed)
   and uses the first whose BuildManifest carries this board. Its root file
   system is read by HTTP ranges: `aea_ro` for Apple Encrypted Archives
   (macOS 15 and later), `udif_ro` for the disk images of older releases
   (13.5), then `apfs_ro` for its System volume. A few MB are fetched. An
   image that is not the build it is listed as, or a version no known image
   carries for this board, refuses; an unreachable image is "not now".
2. **Convert.** The radio files are copied out of the volume and converted
   with this repository's `asahi_firmware`, the converters the installers
   use: `wifi` and `bluetooth` into `brcm/brcmfmac*` and `brcm/brcmbt*`,
   `mt7932` into the names the MT7932 drivers load (the same conversion as
   the native installer's `NeoFirmwareConversions`). The MT7932 Bluetooth
   images keep their macOS names; the newest of each kind is also at
   `mediatek/mt7932/bt-b0.bin`, `bt-b1.bin` and `bt-ptb.ptx`, which do not
   change with macOS.
3. **Check.** The new set must carry what this Mac loads today. Broadcom:
   this Mac's board (the device tree's `brcm,board-type`, which aura takes
   from the Apple device tree) for every chip revision the ESP has today:
   Wi-Fi firmware, regulatory data (`.clm_blob`) and NVRAM, and every
   Bluetooth firmware and PTB name the ESP has for the board. MT7932: every
   Wi-Fi file and a Bluetooth image of each kind, each with the layout its
   driver checks. When the ESP already holds exactly this set, and
   `asahi/all_firmware.tar.gz`'s raw trees convert to it too, nothing
   happens. The raw trees are compared by what they convert to, not byte
   for byte: the installer took them from the Recovery image, which lacks
   files no converter reads. A radio whose files this macOS does not ship
   keeps its files.
4. **Space.** The ESP must hold the new `vendorfw/` (and `all_firmware`)
   beside the current one until the swap. `vendorfw.new` and
   `all_firmware.tar.gz.new` left by a run that did not finish are removed
   first. Too little free space for the new `vendorfw/` is refused before
   anything is built; the exact need, with the rebuilt `all_firmware`, is
   checked once both are built.
5. **Rebuild.** `vendorfw/` is rebuilt with the new files and every other
   file kept, by path, hash and mode (checked before anything is written).
   On Broadcom Macs `asahi/all_firmware.tar.gz` gets the macOS trees under
   `firmware/wifi/` and `firmware/bluetooth/`, so a later rebuild
   (`asahi-fwupdate`) gives the same set.
6. **Swap.** Both are backed up to `/var/lib/aurora-rollback/wifi-firmware-*`
   (the last two backups are kept), copied to the ESP and swapped in. On any
   failure the ESP keeps its old files.
7. **Next boot.** The boot unpacks `vendorfw/` as always and the drivers load
   the new firmware. Nothing is reloaded in the running system: on a Mac
   whose only network is Wi-Fi, reloading the driver can leave it
   unreachable.
8. **Verify.** The first boot after a change checks that the unpacked files
   are the ones put on the ESP, that no driver reported a firmware error and
   that the drivers came up: brcmfmac reported a running firmware, and each
   radio that was up when the change was made is up again (a network
   interface of `mt7932-fullmac`, a Bluetooth controller of
   `hci_bcm4377` or `mt7932_bt_pcie` that is powered). Otherwise it puts the
   previous files back (they load at the following boot) and does not try
   that macOS build again by itself; `aurora-wifi-firmware update` retries.

Nothing from macOS leaves the Mac. Apple's firmware is never part of this
repository or of a distribution package; it goes from the Mac's own macOS
volume to the same Mac's ESP.

Requirements: python3, liblzfse (LZFSE-compressed files on the macOS volume;
set `AURORA_LZFSE_LIB` where the library is not on the search path),
util-linux (`lsblk`, `blkid`, `findmnt`, `mount`), systemd.

When the system ESP is not mounted, the tool mounts it for root only
(`dmask=0077,fmask=0177,nodev,nosuid,noexec`: directories 0700, files 0600)
and unmounts it afterwards. An ESP that is already mounted is used with its
own options; a warning is logged when those let every user read its files
(for example `fmask=0022`).

At boot, a macOS build that was checked against the ESP's radio set is not
read again while the build, that set and the tool stay the same; a newer
tool (one that follows more radios or converts differently) checks it once.
A refusal is remembered with the macOS build, the ESP's radio
set and the tool (a digest of its code and the converters) it was made
for; later boots skip the work until one of them changes or, for a lack of
space, the ESP has the space. A copy or swap that failed is not
remembered: the next boot tries again. `aurora-wifi-firmware update`
always tries again.

With aurora-secboot set up, a signed boot unpacks only the `vendorfw/firmware.cpio` whose digest its UKI command line carries (`aurora.vendorfw=`), and aurora-secboot takes that digest from `vendorfw.sha256` in its key directory, which is the only source of truth. A rebuild keeps every other file of the ESP's package, so before building, the tool refuses unless that package is the pinned one: `firmware.cpio` has the pinned digest, and `firmware.tar` and `manifest.txt` hold what it holds. A pinned `none` is refused too: the owner removes the pin to trust a new archive. After the change it pins the `firmware.cpio` it built, only when the ESP holds exactly that file, and runs `aurora-secboot hook add` for each of this Mac's UKIs, the same step kernel-install runs. A backup records the pin its package was checked against; a revert (the boot check's or `revert`) restores a backup only when it still matches that pin and then pins it again, and restores a backup without one but leaves the pin, so signed boots refuse it until the owner removes the pin. When a pin or a rebuild fails the tool exits 1 and says what to run; until then signed boots refuse the new firmware and the boot check puts the previous files back. Without aurora-secboot, or when it uses another ESP, nothing changes.

Exit codes: 0 done or nothing to do, 1 refused (nothing changed) or the secure boot UKIs were not rebuilt for a change (the message says what to run), 2 not now (the restore image cannot be reached, the ESP mounted read only), 3 internal error.

## Packaging

```sh
make -C tools/wifi-firmware install DESTDIR="$pkgdir" PREFIX=/usr
make -C tools/wifi-firmware check
```

installs the launcher, the tool, the `asahi_firmware` modules it needs
(`__init__`, `core`, `cpio`, `wifi`, `bluetooth`, `mt7932`, and the
restore image reader `ipsw`, `aea_ro`, `udif_ro`, `apfs_ro`, `remotezip`
with `restore-images.json`), and `aurora-wifi-firmware.service` (enable
it). Run-time needs: python3-cryptography (AEA keys), liblzfse, network
access to Apple's CDN and key service.

Tests: `tests/test_wifi_firmware_refresh.py`,
`tests/test_wifi_firmware_radios.py`, `tests/test_wifi_firmware_apfs_bounds.py`
and `tests/test_ipsw_source.py` (synthetic trees and the native
converter's test vectors, no Apple files).
