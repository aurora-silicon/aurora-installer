import json
import importlib.util
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

import main as installer_main
import osinstall

make_icns_spec = importlib.util.spec_from_file_location(
    "make_icns", ROOT / "tools" / "make-icns.py"
)
make_icns = importlib.util.module_from_spec(make_icns_spec)
make_icns_spec.loader.exec_module(make_icns)


class FakeDiskUtil:
    def __init__(self):
        self.calls = []

    def addPartition(self, after, partition_type, label, size):
        self.calls.append((after, partition_type, label, size))
        return SimpleNamespace(
            name=f"disk0s{len(self.calls) + 2}",
            uuid=f"00000000-0000-0000-0000-00000000000{len(self.calls)}",
        )


class AuroraInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((ROOT / "data" / "installer_data.json").read_text())

    def test_only_aurora_specific_options_are_offered(self):
        options = self.data["os_list"]
        self.assertEqual(3, len(options))
        self.assertTrue(all("Aurora" in option["name"] for option in options))
        self.assertTrue(all(option["name"].startswith("Aurora m1n1 proxy") for option in options[:2]))
        self.assertTrue(all(option["next_object"] == "m1n1/boot.bin" for option in options))
        self.assertTrue(all(option["package"] == "aurora-stage2-proxy.zip" for option in options[:2]))
        self.assertEqual("aurora-windows-bootstrap.zip", options[2]["package"])

    def test_reserved_windows_space_uses_basic_data_guid_and_expands(self):
        reserved = self.data["os_list"][1]["partitions"][1]
        self.assertEqual("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", reserved["type"])
        self.assertEqual("64GB", reserved["size"])
        self.assertTrue(reserved["expand"])
        self.assertNotIn("format", reserved)
        self.assertNotIn("image", reserved)
        self.assertNotIn("source", reserved)

    @mock.patch("osinstall.subprocess.run")
    def test_existing_partition_path_is_used_without_partitioning_changes(self, run):
        dutil = FakeDiskUtil()
        template = self.data["os_list"][1]
        installer = osinstall.OSInstaller(dutil, self.data, template)
        installer.partition_disk("disk0s2", installer.min_size)

        self.assertEqual("disk0s2", dutil.calls[0][0])
        self.assertEqual("%EFI%", dutil.calls[0][1])
        self.assertEqual("disk0s3", dutil.calls[1][0])
        self.assertEqual("%EBD0A0A2-B9E5-4433-87C0-68B6B72699C7%", dutil.calls[1][1])
        self.assertTrue(run.called)

    def test_unknown_apple_silicon_devices_are_not_rejected(self):
        chip_min, device = installer_main.resolve_device_support(
            chip_id=0xDEAD,
            device_class="futuremacap",
            macos_ver="26.6.1",
        )
        self.assertEqual("26.6.1", chip_min)
        self.assertEqual("26.6.1", device.min_ver)
        self.assertFalse(device.expert_only)

    def test_m1_through_m5_generations_never_require_expert_mode(self):
        chips = (0x8103, 0x8112, 0x8122, 0x8132, 0x8142)
        for generation, chip in enumerate(chips, start=1):
            with self.subTest(generation=generation):
                _, device = installer_main.resolve_device_support(
                    chip_id=chip,
                    device_class=f"aurora-m{generation}-machine",
                    macos_ver="26.6.1",
                )
                self.assertFalse(device.expert_only)

    def test_stage2_contract_is_replaceable_at_stable_path(self):
        contract = json.loads((ROOT / "data" / "stage2.json").read_text())
        self.assertEqual("m1n1/boot.bin", contract["path"])
        self.assertEqual("proxy", contract["mode"])
        self.assertTrue(contract["replaceable"])
        self.assertIn("Mu", contract["boot_method"])

    def test_icns_wrapper_contains_png_payload(self):
        png = make_icns.PNG_SIGNATURE + b"aurora"
        icon = make_icns.build_icns(png)
        self.assertEqual(b"icns", icon[:4])
        self.assertEqual(len(icon), int.from_bytes(icon[4:8], "big"))
        self.assertEqual(b"ic10", icon[8:12])
        self.assertEqual(png, icon[16:])


if __name__ == "__main__":
    unittest.main()
