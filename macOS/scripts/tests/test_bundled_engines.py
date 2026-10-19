import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "Packaging/verify-bundled-engines.py"
spec = importlib.util.spec_from_file_location("bundled_engines", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BundledEngineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Fixture.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)

    def offline(self):
        directory = self.resources / "Artifacts"
        directory.mkdir()
        archive = directory / "engine.data"
        archive.write_bytes(b"synthetic archive selection")
        release = self.resources / "Release"
        release.mkdir()
        model = {"status": "enabled", "engineDigest": "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest(),
                 "engineArtifact": {"fileName": archive.name, "sizeBytes": archive.stat().st_size}}
        (release / "catalog.json").write_text(json.dumps({"schemaVersion": 4, "models": [model]}))
        return archive

    def test_on_demand_app_has_no_optional_archive(self):
        with patch.object(module.subprocess, "run") as run:
            self.assertEqual(module.verify(self.app, signatures=True), 0)
            run.assert_not_called()

    def test_offline_catalog_engine_reaches_native_signature_verifier(self):
        archive = self.offline()
        with patch.object(module.subprocess, "run") as run:
            self.assertEqual(module.verify(self.app, signatures=True), 1)
            self.assertIn("--signatures", run.call_args.args[0])
            self.assertIn(str(archive), run.call_args.args[0])

    def test_both_resource_locations_are_checked(self):
        offline = self.offline()
        directory = self.resources / "Engine/artifacts"
        directory.mkdir(parents=True)
        private = directory / "fixture.tar.gz"
        private.write_bytes(b"second synthetic archive selection")
        catalog_path = self.resources / "Release/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["models"].append({"status": "enabled",
                                 "engineDigest": "sha256:" + hashlib.sha256(private.read_bytes()).hexdigest(),
                                 "engineArtifact": {"fileName": private.name, "sizeBytes": private.stat().st_size}})
        catalog_path.write_text(json.dumps(catalog))
        (self.resources / "Artifacts" / private.name).write_bytes(private.read_bytes())
        self.assertEqual(set(module.engine_paths(self.app)),
                         {offline, private, self.resources / "Artifacts" / private.name})

    def test_private_archive_requires_a_catalog_identity(self):
        directory = self.resources / "Engine/artifacts"
        directory.mkdir(parents=True)
        (directory / "fixture.tar.gz").write_bytes(b"unbound archive")
        with self.assertRaises(ValueError):
            module.engine_paths(self.app)

    def test_offline_bytes_must_still_match_the_catalog(self):
        archive = self.offline()
        archive.write_bytes(b"changed")
        with self.assertRaises(ValueError), patch.object(module.subprocess, "run") as run:
            module.verify(self.app)
        run.assert_not_called()

    def test_symlinks_and_unexpected_private_resources_are_rejected(self):
        directory = self.resources / "Engine/artifacts"
        directory.mkdir(parents=True)
        unexpected = directory / "extra"
        unexpected.write_bytes(b"x")
        with self.assertRaises(ValueError):
            module.engine_paths(self.app)
        unexpected.unlink()
        (directory / "linked.tar.gz").symlink_to(SCRIPT)
        with self.assertRaises(ValueError):
            module.engine_paths(self.app)


if __name__ == "__main__":
    unittest.main()
