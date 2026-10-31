# SPDX-License-Identifier: MIT
"""All payloads in these tests are generated synthetic data, never Apple bytes."""

import io
from dataclasses import replace
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from asahi_firmware.avd import (
    AVD_SOCS, AVDSource, AVDFWCollection, collect_avd, collect_from_restore,
    firmware_name, reload_image, selected_chip_id,
)
from asahi_firmware import asn1
from asahi_firmware.core import FWFile, FWPackage
from asahi_firmware.update import update_firmware


def synthetic_image():
    return bytes((index * 17 + 3) & 255 for index in range(60616))


def synthetic_im4p(data, image_type="test", raw_size=None):
    encoder = asn1.Encoder()
    encoder.start()
    encoder.enter(asn1.Numbers.Sequence)
    for value in ["IM4P", image_type, "synthetic"]:
        encoder.write(value, asn1.Numbers.IA5String)
    encoder.write(data, asn1.Numbers.OctetString)
    if raw_size is not None:
        encoder.enter(asn1.Numbers.Sequence)
        encoder.write(1, asn1.Numbers.Integer)
        encoder.write(raw_size, asn1.Numbers.Integer)
        encoder.leave()
    encoder.leave()
    return encoder.output()


class AVDFirmwareTests(unittest.TestCase):
    def synthetic_rule(self):
        # Synthetic component/tag names are deliberately not production rules.
        return replace(AVD_SOCS["t6040"], sources=(AVDSource("SyntheticAVD", "test"),))

    def test_selected_component_unwrap_absence_tag_bounds_and_conflicts(self):
        data = synthetic_image()
        with patch.dict(AVD_SOCS, {"t6040": self.synthetic_rule()}):
            self.assertIsNone(collect_avd(0x6040, {}))
            self.assertIsNone(collect_avd(0xFFFF, {"SyntheticAVD": b"unused"}))
            file = collect_avd(0x6040, {"SyntheticAVD": synthetic_im4p(data)})
            self.assertEqual(file.data, data)
            with patch("asahi_firmware.img4.decode_lzfse", return_value=data) as decode:
                compressed = synthetic_im4p(b"synthetic compressed stream", raw_size=len(data))
                self.assertEqual(collect_avd(0x6040, {"SyntheticAVD": compressed}).data, data)
                decode.assert_called_once_with(b"synthetic compressed stream", len(data))
            for malformed in [synthetic_im4p(data, "nope"), synthetic_im4p(data[:-1]),
                              synthetic_im4p(b"", raw_size=60617), b"not DER"]:
                with self.assertRaises((ValueError, AssertionError, asn1.Error)):
                    collect_avd(0x6040, {"SyntheticAVD": malformed})
            spec = replace(self.synthetic_rule(), sources=(
                AVDSource("SyntheticAVD", "test"), AVDSource("SyntheticOther", "test"),
            ))
            with patch.dict(AVD_SOCS, {"t6040": spec}):
                with self.assertRaises(ValueError):
                    collect_avd(0x6040, {"SyntheticAVD": synthetic_im4p(data),
                                         "SyntheticOther": synthetic_im4p(bytes(60616))})

    def test_restore_uses_only_selected_component_and_confines_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "synthetic.im4p").write_bytes(synthetic_im4p(synthetic_image()))
            identity = {"ApChipID": "0x6040", "Manifest": {
                "SyntheticAVD": {"Info": {"Path": "synthetic.im4p"}},
                "Other": {"Info": {"Path": "../not-selected"}},
            }}
            with patch.dict(AVD_SOCS, {"t6040": self.synthetic_rule()}):
                self.assertEqual(collect_from_restore(root, identity, 0x6040).data,
                                 synthetic_image())
                identity["ApChipID"] = "0x8112"
                with self.assertRaises(ValueError):
                    collect_from_restore(root, identity, 0x6040)
                identity["ApChipID"] = "0x6040"
                for path in ["../outside", "/outside", "a//b", "a/./b", "a\\b"]:
                    identity["Manifest"]["SyntheticAVD"]["Info"]["Path"] = path
                    with self.assertRaises(ValueError):
                        collect_from_restore(root, identity, 0x6040)

    def test_per_soc_names_and_observed_t6040_identity(self):
        for soc in AVD_SOCS:
            self.assertEqual(firmware_name(int(soc[1:], 16)), f"apple/avd-apple-{soc}.bin")
        self.assertIsNone(firmware_name(0xFFFF))
        self.assertIsNone(firmware_name("../t6040"))
        self.assertEqual(AVD_SOCS["t6040"].size, 60616)
        self.assertEqual(AVD_SOCS["t6040"].version, 0x23F3B998)
        self.assertTrue(AVD_SOCS["t6040"].preloaded)

    def test_absent_unknown_and_other_soc_images_are_not_collected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(AVDFWCollection(directory, 0x6040).files(), [])
            root = Path(directory)
            (root / "apple").mkdir()
            (root / "apple/avd-apple-t6040.bin").write_bytes(synthetic_image())
            for chip in [None, 0xFFFF, 0x6000, 0x8112, 0x8140]:
                self.assertEqual(AVDFWCollection(root, chip).files(), [])

    def test_reload_copy_is_exact_and_rejects_short_or_long_input(self):
        data = synthetic_image()
        image = reload_image(data, 0x6040)
        self.assertEqual(image.name, "apple/avd-apple-t6040.bin")
        self.assertEqual(image.data, data)
        self.assertEqual(image.version, 0x23F3B998)
        for malformed in [b"", data[:-1], data + b"\0"]:
            with self.assertRaises(ValueError):
                reload_image(malformed, 0x6040)

    def test_reload_copy_cannot_follow_archive_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "apple").mkdir()
            (root / "outside").write_bytes(synthetic_image())
            (root / "apple/avd-apple-t6040.bin").symlink_to("../outside")
            with self.assertRaises(OSError):
                AVDFWCollection(root, 0x6040)
            (root / "apple/avd-apple-t6040.bin").unlink()
            (root / "apple").rmdir()
            (root / "apple").symlink_to(".")
            with self.assertRaises(ValueError):
                AVDFWCollection(root, 0x6040)

    def test_archive_and_manifest_round_trip(self):
        data = synthetic_image()
        image = reload_image(data, 0x6040)
        with tempfile.TemporaryDirectory() as directory:
            package = FWPackage(directory)
            package.add_file("unversioned.bin", FWFile("unversioned.bin", b"synthetic"))
            package.add_file(image.name, image)
            package.close()
            manifest = (Path(directory) / "manifest.txt").read_text()
            self.assertIn(f"FILE {image.name} SHA256 {image.sha}\n", manifest)
            self.assertIn(f"VERSION {image.name} 0x23f3b998 SIZE 60616\n", manifest)
            self.assertEqual(manifest.count("VERSION"), 1)
            with tarfile.open(Path(directory) / "firmware.tar") as archive:
                self.assertEqual(archive.extractfile(image.name).read(), data)
            self.assertIn(manifest.encode(), (Path(directory) / "firmware.cpio").read_bytes())

    def test_selected_identity_is_from_install_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(selected_chip_id(root))
            (root / "stub_info.json").write_text(json.dumps({
                "manifest_info": {"chip_id": "0x6040"},
            }))
            self.assertEqual(selected_chip_id(root), 0x6040)
            path = root / "BuildManifest.plist"
            path.write_bytes(plistlib.dumps({"BuildIdentities": [{"ApChipID": "0x6040"}]}))
            self.assertEqual(selected_chip_id(root), 0x6040)
            path.write_bytes(plistlib.dumps({"BuildIdentities": [{"ApChipID": "0x8112"}]}))
            with self.assertRaises(ValueError):
                selected_chip_id(root)
            path.write_bytes(plistlib.dumps({"BuildIdentities": [{}, {}]}))
            with self.assertRaises(ValueError):
                selected_chip_id(root)

    def test_refresh_collects_selected_machine_reload_copy(self):
        self.refresh_case(fresh=False)

    def test_refresh_prefers_new_selected_source_over_old_fallback(self):
        self.refresh_case(fresh=True)

    def test_refresh_accepts_old_archives_without_avd_or_identity(self):
        self.refresh_case(fresh=False, has_copy=False, has_identity=False)

    def test_refresh_skips_absent_avd_on_a_known_machine(self):
        self.refresh_case(fresh=False, has_copy=False)

    def refresh_case(self, fresh, has_copy=True, has_identity=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, dest = root / "source", root / "vendorfw"
            source.mkdir()
            dest.mkdir()
            if has_identity:
                (source / "stub_info.json").write_text(json.dumps({
                    "manifest_info": {"chip_id": "0x6040"},
                }))
            name = "apple/avd-apple-t6040.bin"
            data = synthetic_image()
            with tarfile.open(source / "all_firmware.tar.gz", "w:gz") as archive:
                if has_copy:
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            if fresh:
                (source / "BuildManifest.plist").write_bytes(plistlib.dumps({"BuildIdentities": [{
                    "ApChipID": "0x6040", "Manifest": {
                        "SyntheticAVD": {"Info": {"Path": "synthetic.im4p"}},
                    },
                }]}))
                data = bytes(60616)
                (source / "synthetic.im4p").write_bytes(synthetic_im4p(data))
            # Other collectors are independent of AVD and require real vendor
            # inputs. This integration test supplies only the synthetic AVD copy.
            with patch.dict(AVD_SOCS, {"t6040": self.synthetic_rule()}), patch.multiple("asahi_firmware.update", **{
                name: lambda *_: type("Empty", (), {"files": lambda self: []})()
                for name in ["WiFiFWCollection", "BluetoothFWCollection", "MultitouchFWCollection",
                             "ISPFWCollection", "AlsFWCollection", "KernelFWCollection"]
            }):
                update_firmware(source, dest)
            with tarfile.open(dest / "firmware.tar") as archive:
                self.assertEqual(archive.getnames(), [name] if fresh or has_copy else [])
                if fresh or has_copy:
                    self.assertEqual(archive.extractfile(name).read(), data)
            manifest = (dest / "manifest.txt").read_text()
            if fresh or has_copy:
                self.assertIn("0x23f3b998 SIZE 60616", manifest)
            else:
                self.assertNotIn("VERSION", manifest)


if __name__ == "__main__":
    unittest.main()
