# SPDX-License-Identifier: MIT
"""tools/wifi-firmware: the first boot after a native install changes nothing.

The native installer takes both Broadcom radios from the installed macOS when
its system volume has this Mac's board, and its fallback archive keeps the
macOS trees as they are, an alias naming an alias included. The boot service
then finds that the ESP already holds this macOS's radio firmware.

Synthetic trees only. The package is converted here with asahi_firmware; on
the macOS 27.0 (26A428) system volume of a J414s the native converters give
the same 489 Wi-Fi and 114 Bluetooth files.
"""
import os
import pathlib
import tarfile
import unittest

from test_wifi_firmware_refresh import Case, awf
from asahi_firmware.bluetooth import BluetoothFWCollection
from asahi_firmware.core import FWFile, FWPackage

BT_STEM = "BCM4387C2_19.3.395.4044_PCIE_macOS_hokkaido_CLPC_OS_USI_20250101"


def trees(tag):
    """A macOS's /usr/share/firmware/wifi and bluetooth trees, shaped like
    macOS's: an antenna SKU's alias names the board's alias, which names a
    file the boards share."""
    d = "C-4387__s-C2"
    wifi = {
        f"{d}/guam.trx": f"{tag} shared firmware".encode(),
        f"{d}/hokkaido.trx": ("link", "guam.trx"),
        f"{d}/hokkaido-X0.trx": ("link", "hokkaido.trx"),
        f"{d}/hokkaido.clmb": f"{tag} clm".encode(),
        f"{d}/hokkaido.txcb": f"{tag} txcap".encode(),
        f"{d}/P-hokkaido_M-YSBC_V-u__m-7.5.txt": f"boardrev=0x1\nname={tag}\n".encode(),
    }
    bluetooth = {
        BT_STEM + ".bin": f"{tag} bluetooth".encode(),
        BT_STEM + ".ptb": f"{tag} patch table".encode(),
    }
    return wifi, bluetooth


def native_esp(root, wifi, bluetooth, archived_wifi=None):
    """An ESP as the native installer leaves it: all_firmware with the radio
    trees the package came from (archived_wifi: another firmware/wifi/), and
    vendorfw converted from those trees."""
    root = pathlib.Path(root)
    esp = root / "esp"
    (esp / "asahi").mkdir(parents=True)
    with tarfile.open(esp / "asahi" / "all_firmware.tar.gz", "w:gz") as tar:
        for prefix, tree in ((awf.RAW_PREFIX, archived_wifi or wifi),
                             (awf.RAW_BT_PREFIX, bluetooth)):
            for ti, fd in awf.tar_entries(tree, prefix):
                tar.addfile(ti, fd)
    for name, tree in (("wifi", wifi), ("bluetooth", bluetooth)):
        for rel, v in tree.items():
            p = root / "raw" / name / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(v, tuple):
                os.symlink(v[1], p)
            else:
                p.write_bytes(v)
    (esp / "vendorfw").mkdir()
    pkg = FWPackage(str(esp / "vendorfw"))
    pkg.add_files(sorted(awf.converted(root / "raw" / "wifi").items()))
    pkg.add_files(sorted(BluetoothFWCollection(str(root / "raw" / "bluetooth")).files()))
    pkg.add_file("asmedia/asm2214a-apple.bin", FWFile("asm", b"asmedia"))
    pkg.close()
    return esp


class NativeInstallTest(Case):
    def macos(self, wifi, bluetooth):
        mac = super().macos(wifi)
        for name, data in bluetooth.items():
            mac.volume._add(f"{awf.BLUETOOTH}/{name}", data)
        return mac

    def check(self, esp, wifi, bluetooth):
        return self.update(esp, self.macos(wifi, bluetooth), dry_run=True)

    def test_first_boot_changes_nothing(self):
        wifi, bluetooth = trees("26.7.3")
        esp = native_esp(self.root, wifi, bluetooth)
        before = awf.tree_hashes(esp)
        self.assertEqual(self.check(esp, wifi, bluetooth), "identical")
        self.assertIn("Broadcom Bluetooth: ESP 2 files, macOS 2 files (the same)", self.out)
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_an_alias_archived_as_its_final_file_is_a_rebuild(self):
        """The fallback archive once named each alias's final file, so its
        tree was not macOS's and the first boot rebuilt the ESP."""
        wifi, bluetooth = trees("26.7.3")
        flat = dict(wifi, **{"C-4387__s-C2/hokkaido-X0.trx": ("link", "guam.trx")})
        esp = native_esp(self.root, wifi, bluetooth, archived_wifi=flat)
        self.assertEqual(self.check(esp, wifi, bluetooth), "dry-run")

    def test_recovery_bluetooth_is_a_rebuild(self):
        """Bluetooth from the stub's older Recovery, with the installed
        macOS's Wi-Fi, as before: the first boot rebuilt the ESP."""
        wifi, bluetooth = trees("26.7.3")
        esp = native_esp(self.root, wifi, trees("13.5")[1])
        self.assertEqual(self.check(esp, wifi, bluetooth), "dry-run")
        self.assertIn("Broadcom Bluetooth: ESP 2 files, macOS 2 files", self.out)


if __name__ == "__main__":
    unittest.main()
