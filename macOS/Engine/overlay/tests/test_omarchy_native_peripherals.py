# SPDX-License-Identifier: MIT
"""Synthetic prepared snapshots; no original firmware or device calibration."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import omarchy_als as als
import omarchy_isp as isp
import omarchy_mt7932 as mt
import omarchy_native_peripherals as native


def fixture():
    root = Path(__file__).resolve().parents[3]
    return json.loads((root / "Tests/NativeFirmwareFixtureSupport/Fixtures/neo-conversion-vectors.json").read_text())


def outputs(value):
    raw = {name: base64.b64decode(data) for name, data in value["rawFiles"].items()}
    local = {name: base64.b64decode(data) for name, data in value["local"].items()}
    registry = [isp.SetFile(0, entry["magic"], entry["name"], entry["size"]) for entry in value["registry"]
                if entry["magic"] != isp.IMX558_1925.magic]
    result = isp.extract(raw["camera/synthetic.bin"], registry)
    with patch.object(mt, "_read", side_effect=lambda root, *parts: raw["/".join(parts)]), patch.object(
        mt.glob, "glob", return_value=["synthetic-factory"]
    ), patch.object(mt, "open", create=True, return_value=io.BytesIO(local["factory"])):
        result.update(mt.collect(raw_directory="synthetic", chosen={"mac-address-bluetooth0": local["address"]}))
    result[als.FIRMWARE_NAME] = als.calibration(local["lsci"])
    result["fallback/lsci.bin"] = local["lsci"]
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(value["payload"]))) as archive:
        result["mediatek/mt7932/policy/world-XZ.bin"] = archive.read("installer-inputs/mt7932-policy/world-XZ.bin")
    return result


class PreparedPeripheralTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "snapshot"
        self.root.mkdir(mode=0o700)
        self.value = fixture()
        self.manifest = self.value["manifest"]
        self.files = outputs(self.value)
        for name, data in self.files.items():
            path = self.root / "files" / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
            path.chmod(0o600)
        self.save()

    def save(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(self.manifest, sort_keys=True, separators=(",", ":")))
        path.chmod(0o600)

    def load(self, **changes):
        m = self.value["manifest"]
        args = dict(device=m["device_identifier"], binding=m["binding_digest"], plan=m["plan_digest"],
                    metadata=m["metadata_digest"], payload=m["payload_digest"], recipe=m["recipe_sha256"])
        args.update(changes)
        return native.load(str(self.root), **args)

    def test_reference_snapshot_is_consumed_without_collection_or_conversion(self):
        with patch.object(mt, "collect", side_effect=AssertionError("no collector")), patch.object(
            isp, "extract", side_effect=AssertionError("no converter")
        ), patch.object(als, "read_lsci", side_effect=AssertionError("no host query")):
            result = self.load()
        flat = {name: data for role in result.values() for name, data in role.items()}
        self.assertEqual(flat, self.files)
        self.assertEqual({name: hashlib.sha256(data).hexdigest() for name, data in flat.items()}, self.value["outputSHA256"])

    def add_policy(self, country, version, size):
        # Opaque synthetic producer output: structural validation belongs to Swift.
        name = f"mediatek/mt7932/policy{'-v2' if version == 2 else ''}/{country}.bin"
        data = b"J7RP" + version.to_bytes(2, "little") + country.encode("ascii") + bytes(size - 8)
        path = self.root / "files" / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(data)
        path.chmod(0o600)
        self.manifest["files"][name] = dict(role="policy", bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        return name

    def test_complete_v1_and_v2_native_inventory_is_adopted_with_both_paths(self):
        countries = [a + b for a in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" for b in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                     if a + b != "XZ"][:243]
        for country in countries:
            self.add_policy(country, 1, 10240)
        for country in countries[:120]:
            self.add_policy(country, 2, 28537)
        self.save()
        result = self.load()["policy"]
        self.assertEqual(len(result), 364)
        self.assertEqual(sum("/policy-v2/" in name for name in result), 120)
        self.assertIn("mediatek/mt7932/policy/world-XZ.bin", result)

    def test_v2_cannot_replace_v1_or_escape_the_v2_size_budget(self):
        name = self.add_policy("US", 2, 28537)
        self.save()
        self.assertIn(name, self.load()["policy"])
        record = self.manifest["files"][name]
        record["bytes"] = 65537
        self.save()
        with self.assertRaisesRegex(native.NativePeripheralError, "policy size"):
            self.load()
        record["bytes"] = 28537
        self.save()
        path = self.root / "files" / name
        data = bytearray(path.read_bytes())
        data[4:6] = (1).to_bytes(2, "little")
        path.write_bytes(data)
        record["sha256"] = hashlib.sha256(data).hexdigest()
        self.save()
        with self.assertRaisesRegex(native.NativePeripheralError, "directory/version"):
            self.load()
        name = self.add_policy("CA", 1, 10240)
        path = self.root / "files" / name
        data = bytearray(path.read_bytes())
        data[4:6] = (2).to_bytes(2, "little")
        path.write_bytes(data)
        self.manifest["files"][name]["sha256"] = hashlib.sha256(data).hexdigest()
        # Remove the first invalid entry to isolate v2 misplaced in policy/.
        del self.manifest["files"]["mediatek/mt7932/policy-v2/US.bin"]
        (self.root / "files/mediatek/mt7932/policy-v2/US.bin").unlink()
        (self.root / "files/mediatek/mt7932/policy-v2").rmdir()
        self.save()
        with self.assertRaisesRegex(native.NativePeripheralError, "directory/version"):
            self.load()

    def test_sensor_inputs_require_both_complete_bound_files(self):
        # Synthetic opaque containers: the native producer validates DER; this
        # adoption boundary verifies the private snapshot and exact bytes.
        for name, key in ((native.SENSOR, "sensorCalibration"), (native.SENSOR_ROOT_KEY, "sensorRootKey")):
            data = ("synthetic:" + name).encode()
            path = self.root / "files" / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
            path.chmod(0o600)
            self.manifest["files"][name] = dict(role="sensor", bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            self.manifest["local_inputs"][key] = hashlib.sha256(data).hexdigest()
        self.save()
        self.assertEqual(set(self.load()["sensor"]), {native.SENSOR, native.SENSOR_ROOT_KEY})
        del self.manifest["files"][native.SENSOR_ROOT_KEY]
        self.save()
        with self.assertRaisesRegex(native.NativePeripheralError, "missing or changed"):
            self.load()

    def test_all_context_fields_refuse_another_job_plan_payload_or_recipe(self):
        for key, changed in [("device", "apple,j613"), ("binding", "sha256:" + "d" * 64),
                             ("plan", "d" * 64), ("metadata", "sha256:" + "d" * 64),
                             ("payload", "sha256:" + "d" * 64), ("recipe", "d" * 64)]:
            with self.subTest(key=key), self.assertRaises(native.NativePeripheralError):
                self.load(**{key: changed})

    def test_plan_digest_requires_the_engine_bare_hex_contract(self):
        self.manifest["plan_digest"] = "sha256:" + "c" * 64
        self.save()
        with self.assertRaisesRegex(native.NativePeripheralError, "invalid native peripheral plan"):
            self.load()

    def test_links_hardlinks_changed_bytes_and_extra_inventory_are_refused(self):
        path = self.root / "files/fallback/lsci.bin"
        original = path.read_bytes()
        path.write_bytes(b"x" * len(original))
        with self.assertRaises(native.NativePeripheralError): self.load()
        path.write_bytes(original)
        alias = self.root.parent / "alias"
        os.link(path, alias)
        with self.assertRaises(native.NativePeripheralError): self.load()
        alias.unlink()
        path.unlink()
        path.symlink_to(self.root / "manifest.json")
        with self.assertRaises(native.NativePeripheralError): self.load()
        path.unlink(); path.write_bytes(original); path.chmod(0o600)
        extra = self.root / "files/unexpected"
        extra.write_bytes(b"extra")
        with self.assertRaises(native.NativePeripheralError): self.load()
        extra.unlink()
        extra.mkdir()
        with self.assertRaises(native.NativePeripheralError): self.load()

    def test_manifest_types_roles_missing_files_and_writable_entries_fail_closed(self):
        original = json.loads(json.dumps(self.manifest))
        for field, value in [("schema", True), ("converter", "other"), ("local_inputs", {}), ("files", {})]:
            self.manifest = dict(original, **{field:value}); self.save()
            with self.subTest(field=field), self.assertRaises(native.NativePeripheralError): self.load()
        self.manifest = original; self.save()
        path = self.root / "files/fallback/lsci.bin"
        path.chmod(0o664)
        with self.assertRaises(native.NativePeripheralError): self.load()
        path.chmod(0o600)
        self.manifest["files"]["fallback/lsci.bin"]["role"] = []
        self.save()
        with self.assertRaises(native.NativePeripheralError): self.load()

    def test_missing_world_policy_and_wrong_local_input_digest_are_refused(self):
        name = "mediatek/mt7932/policy/world-XZ.bin"
        del self.manifest["files"][name]; self.save()
        with self.assertRaises(native.NativePeripheralError): self.load()
        self.manifest = fixture()["manifest"]
        self.manifest["local_inputs"]["lsci"] = "0" * 64; self.save()
        with self.assertRaises(native.NativePeripheralError): self.load()


if __name__ == "__main__": unittest.main()
