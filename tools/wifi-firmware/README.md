# Wi-Fi firmware of the installed macOS

macOS runs the Broadcom Wi-Fi firmware its own system volume ships, so every
macOS update can bring new Wi-Fi firmware. A Linux install keeps the set its
installer took:

- the Asahi installer takes it from its stub's Recovery image, macOS 13.5
  (22G74) for most installs. A MacBook Pro M1 Pro installed that way runs
  BCM4387 firmware 20.96.31 (May 2023) while its macOS 26.2 runs 20.131.4;
- the Aurora installer takes it from the macOS it runs on (the installed
  system volume), so an install matches that macOS until macOS updates.

`aurora-wifi-firmware` brings the installed macOS's firmware over from Linux:

```sh
sudo aurora-wifi-firmware status    # board, ESP and running firmware, installed macOS
sudo aurora-wifi-firmware check     # dry run
sudo aurora-wifi-firmware update    # put the installed macOS's firmware on the ESP
sudo aurora-wifi-firmware revert    # put the files from before the last change back
```

After a `revert` the boot service leaves that macOS build alone; `update`,
or the next macOS update, brings the firmware back.

The `aurora-wifi-firmware` service runs `boot` at every start-up, so a Mac
follows its macOS as macOS does.

## What it does

1. **Which macOS.** Every APFS container on the Mac is read with `apfs_ro`, a
   small read-only APFS reader (no mount, no kernel module, no FUSE). The
   System volume is not encrypted, with or without FileVault, so no password
   is needed. The boot stub's volume group (`asahi/stub_info.json`) is left
   out. With more than one macOS installed, the newest build is used.
2. **Convert.** `/usr/share/firmware/wifi` is copied out of the volume and
   converted with this repository's `asahi_firmware.wifi`, the converter the
   installers use, into `brcm/brcmfmac*` names.
3. **Check.** The new set must carry this Mac's board (the device tree's
   `brcm,board-type`, which aura takes from the Apple device tree) for every
   chip revision the ESP has today: firmware, regulatory data (`.clm_blob`)
   and NVRAM. When the ESP already holds exactly this set, nothing happens.
4. **Rebuild.** `vendorfw/` is rebuilt with the new `brcm/brcmfmac*` files
   and every other file kept, by path and hash (checked before anything is
   written). `asahi/all_firmware.tar.gz` gets the macOS tree under
   `firmware/wifi/`, so a later rebuild (`asahi-fwupdate`) gives the same set.
5. **Swap.** Both are backed up to `/var/lib/aurora-rollback/wifi-firmware-*`
   (the last two backups are kept), copied to the ESP and swapped in. On any
   failure the ESP keeps its old files.
6. **Next boot.** The boot unpacks `vendorfw/` as always and brcmfmac loads
   the new firmware. Nothing is reloaded in the running system: on a Mac
   whose only network is Wi-Fi, reloading brcmfmac can leave it unreachable.
7. **Verify.** The first boot after a change checks that the unpacked file is
   the one put on the ESP and that brcmfmac reported a running firmware
   without a setup error. Otherwise it puts the previous files back (they
   load at the following boot) and does not try that macOS build again by
   itself; `aurora-wifi-firmware update` retries.

Nothing from macOS leaves the Mac. Apple's firmware is never part of this
repository or of a distribution package; it goes from the Mac's own macOS
volume to the same Mac's ESP.

Requirements: python3, liblzfse (LZFSE-compressed files on the macOS volume;
set `AURORA_LZFSE_LIB` where the library is not on the search path),
util-linux (`lsblk`, `blkid`, `findmnt`, `mount`), systemd.

Exit codes: 0 done or nothing to do, 1 refused (nothing changed), 2 not now
(no readable macOS volume, the ESP mounted read only), 3 internal error.

## Packaging

```sh
make -C tools/wifi-firmware install DESTDIR="$pkgdir" PREFIX=/usr
make -C tools/wifi-firmware check
```

installs the launcher, the tool with `apfs_ro` and the four
`asahi_firmware` modules it needs (`__init__`, `core`, `cpio`, `wifi`), and
`aurora-wifi-firmware.service` (enable it). `apfs_ro.py` is vendored from
speakerguardd's `packaging/upgrade`, with the volume group added.

Tests: `tests/test_wifi_firmware_refresh.py` (synthetic trees, no Apple
files).
