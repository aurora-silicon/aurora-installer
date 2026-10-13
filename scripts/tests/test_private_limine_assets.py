import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("limine_assets", ROOT / "Packaging/private-test/prepare-limine-assets.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivateLimineAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.catalog = self.root / "catalog.json"
        self.product = self.root / "product.json"
        self.output = self.root / "prepared"
        payload = "omarchy-private-limine-fixture.zip"
        values = {"engine": (MODULE.ENGINE_NAME, b"fixture engine"),
                  "metadata": ("installer_data.json", json.dumps({"os_list": [{"omarchy_target": "apple-silicon-full-os", "package": payload}]}).encode()),
                  "payload": (payload, b"fixture Limine image")}
        model = {"deviceIdentifier": "apple,j516s", "status": "enabled", "engineVersion": "v0.9.2-omarchy.17",
                 "evidenceRevision": "quattro-private-limine-fixture"}
        for role, (name, data) in values.items():
            (self.assets / name).write_bytes(data)
            model[role + "Artifact"] = {"fileName": name, "sizeBytes": len(data)}
            model[role + "Digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
        self.document = {"schemaVersion": 4, "models": [model]}
        self.catalog.write_text(json.dumps(self.document))
        self.product.write_text(json.dumps({"boot_backend": "asahi-limine", "kernel_package": "linux-asahi", "package_filename": payload}))
        self.engine_pin = mock.patch.multiple(MODULE, ENGINE_SHA=model["engineDigest"][7:], ENGINE_SIZE=len(values["engine"][1]))
        self.engine_pin.start()
        self.addCleanup(self.engine_pin.stop)

    def prepare(self):
        return MODULE.prepare(self.catalog, self.product, self.assets, self.output)

    def test_fresh_assets_stage_only_in_separate_limine_workspace(self):
        record = self.prepare()
        shutil.copyfile(self.catalog, self.output / "catalog.json")
        self.assertEqual(MODULE.verify_release(self.output), record)
        shutil.copytree(self.assets, self.output / "limine-assets")
        home = self.root / "user"
        home.mkdir(mode=0o700)
        result = subprocess.run(["bash", "-c", 'OMARCHY_STAGE_SOURCE_ONLY=1 source "$1"; stage_bundle "$2" "$3"',
                                 "stage-test", str(self.output / "Stage assets.command"), str(self.output), str(home)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        staged = home / "Library/Application Support" / MODULE.WORKSPACE / "staging/quattro-private-limine-fixture"
        self.assertEqual(sorted(p.name for p in staged.iterdir()), sorted(p.name for p in self.assets.iterdir()))
        for source in self.assets.iterdir():
            self.assertEqual((staged / source.name).read_bytes(), source.read_bytes())
        self.assertFalse((home / "Library/Application Support" / MODULE.APP_IDENTIFIER).exists())
        self.assertFalse((home / "Library/Application Support" / MODULE.PLAIN_WORKSPACE).exists())
        self.assertNotIn("@APP_IDENTIFIER@", (self.output / "Stage assets.command").read_text())

    def test_ordinary_or_stale_plain_catalog_rejected(self):
        self.document["models"][0]["evidenceRevision"] = "quattro-private-m3-family-1c595bb6030c-20260922"
        self.catalog.write_text(json.dumps(self.document))
        with self.assertRaisesRegex(ValueError, "Limine evidence"):
            self.prepare()

    def test_grub_product_and_aurora_kernel_are_rejected(self):
        for changed in ({"boot_backend": "asahi-grub"}, {"kernel_package": "linux-aurora"}):
            product = {"boot_backend": "asahi-limine", "kernel_package": "linux-asahi", "package_filename": "omarchy-private-limine-fixture.zip", **changed}
            self.product.write_text(json.dumps(product))
            with self.assertRaisesRegex(ValueError, "Asahi Limine"):
                self.prepare()

    def test_changed_asset_or_engine_pin_cannot_prepare(self):
        payload = self.assets / self.document["models"][0]["payloadArtifact"]["fileName"]
        payload.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "catalog asset differs"):
            self.prepare()
        self.document["models"][0]["engineDigest"] = "sha256:" + "f" * 64
        with self.assertRaisesRegex(ValueError, "engine changed"):
            MODULE.catalog_contract(self.document)

    def test_divergent_model_assets_and_unsafe_names_rejected(self):
        second = copy.deepcopy(self.document["models"][0])
        second["payloadDigest"] = "sha256:" + "e" * 64
        self.document["models"].append(second)
        with self.assertRaisesRegex(ValueError, "share the exact"):
            MODULE.catalog_contract(self.document)
        self.document["models"] = [second]
        second["metadataArtifact"]["fileName"] = "../installer_data.json"
        with self.assertRaisesRegex(ValueError, "unsafe artifact"):
            MODULE.catalog_contract(self.document)

    def test_sealed_catalog_mutation_invalidates_receipt(self):
        self.prepare()
        self.document["sequence"] = 2
        (self.output / "catalog.json").write_text(json.dumps(self.document))
        with self.assertRaisesRegex(ValueError, "receipt differs"):
            MODULE.verify_release(self.output)

    def test_output_and_asset_symlinks_are_rejected(self):
        payload = self.assets / self.document["models"][0]["payloadArtifact"]["fileName"]
        data = payload.read_bytes()
        payload.unlink()
        outside = self.root / "outside"
        outside.write_bytes(data)
        payload.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "unsafe input"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
