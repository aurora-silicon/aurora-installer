# Wi-Fi and Bluetooth firmware of the installed macOS

macOS runs the Wi-Fi and Bluetooth firmware its own system volume ships, so
every macOS update can bring new radio firmware. A Linux install keeps the
set its installer took:

- the Asahi installer takes it from its stub's Recovery image, macOS 13.5
  (22G74) for most installs. A MacBook Pro M1 Pro installed that way runs
  BCM4387 firmware 20.96.31 (May 2023) while its macOS 26.2 runs 20.131.4;
- the Aurora installer takes it from the macOS it runs on (the installed
  system volume, or for the MacBook Neo's MediaTek MT7932 the IPSW of the
  same build), so an install matches that macOS until macOS updates.

`aurora-wifi-firmware` brings the installed macOS's firmware over from Linux:

| Radio | macOS files | ESP package (`vendorfw/`) |
| --- | --- | --- |
| Broadcom Wi-Fi | `/usr/share/firmware/wifi` | `brcm/brcmfmac*` |
| Broadcom Bluetooth | `/usr/share/firmware/bluetooth` | `brcm/brcmbt*` |
| MediaTek MT7932 Wi-Fi | `AppleSunriseWLAN.dext/IZUBA`: patch, RAM, power profile, configuration | `mediatek/mt7932/` |
| MediaTek MT7932 Bluetooth | `/usr/share/firmware/bluetooth/MT7932*` | `mediatek/MT7932*`, `mediatek/mt7932/bt-*` |

A Mac follows the radios its ESP package carries today. The MT7932's
calibration (`oca2`, `wcal`, `btcal`), its Bluetooth address and the
regulatory policies are this Mac's own records; they stay as the installer
wrote them.

```sh
sudo aurora-wifi-firmware status    # board, ESP and running firmware, installed macOS
sudo aurora-wifi-firmware check     # dry run
sudo aurora-wifi-firmware update    # put the installed macOS's firmware on the ESP
sudo aurora-wifi-firmware revert    # put the files from before the last change back
```

After a `revert` the boot service leaves that macOS build alone; `update`,
or the next macOS update, brings the firmware back.

`check` and `update` take `--macos DIR` to read a macOS root somewhere else
(a mounted or copied System volume) instead of the installed macOS. The boot
service still follows the installed macOS: after the first boot with such a
set, it puts the installed macOS's set back for the boot after.

The `aurora-wifi-firmware` service runs `boot` at every start-up, so a Mac
follows its macOS as macOS does.

## What it does

1. **Which macOS.** Every APFS container on the Mac is read with `apfs_ro`, a
   small read-only APFS reader (no mount, no kernel module, no FUSE). The
   System volume is not encrypted, with or without FileVault, so no password
   is needed. The boot stub's volume group (`asahi/stub_info.json`) is left
   out. With more than one macOS installed, the newest build is used.
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
always tries again; `update --macos DIR` leaves the boot's record alone.

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now
(no readable macOS volume, the ESP mounted read only), 3 internal error.

## Packaging

```sh
make -C tools/wifi-firmware install DESTDIR="$pkgdir" PREFIX=/usr
make -C tools/wifi-firmware check
```

installs the launcher, the tool with `apfs_ro` and the `asahi_firmware`
modules it needs (`__init__`, `core`, `cpio`, `wifi`, `bluetooth`,
`mt7932`), and
`aurora-wifi-firmware.service` (enable it). `apfs_ro.py` is vendored from
speakerguardd's `packaging/upgrade`, with the volume group added.

Tests: `tests/test_wifi_firmware_refresh.py` and
`tests/test_wifi_firmware_radios.py` (synthetic trees and the native
converter's test vectors, no Apple files).
