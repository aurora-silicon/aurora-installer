import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "prepare-distribution-release.py"
spec = importlib.util.spec_from_file_location("distribution_release", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DistributionReleaseTests(unittest.TestCase):
    def setUp(self):
        mode = patch.dict(os.environ, {"AURORA_ENABLE_OMARCHY": "0"})
        mode.start()
        self.addCleanup(mode.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Packaging").mkdir()
        (self.root / "Packaging/identity.conf").write_text(
            'INSTALLER_PUBLIC_BASE="https://delivery.invalid"\nINSTALLER_STREAM_PATH="native"\n'
            'INSTALLER_HELPER_IDENTIFIER="invalid.example.installer.helper"\n')
        self.profiles = self.root / "profiles"
        self.key = self.root / "private.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.key)], check=True)
        der = subprocess.check_output(["openssl", "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"])
        self.public = der[-32:]
        release = self.root / "Release"
        release.mkdir()
        (release / "trust-root.ed25519.pub").write_bytes(self.public)
        import hashlib
        fingerprint = "sha256:" + hashlib.sha256(self.public).hexdigest()
        for profile in module.PROFILES + (module.OMARCHY_PROFILE,):
            directory = self.profiles / profile
            directory.mkdir(parents=True)
            descriptor = {"schema_version": 3, "trust_root_fingerprint": fingerprint,
                          "helper_mach_service_name": "invalid.example.installer.helper",
                          "helper_code_signing_requirement": 'identifier "invalid.example.installer.helper"',
                          "channels": {channel: {"catalog_url": "https://delivery.invalid/native/Profiles/"
                                                 + profile + "/channels/" + ("edge-alpha" if channel == "edge" else channel) + "/catalog.signed.json"}
                                       for channel in ("stable", "rc", "testing", "edge")}}
            (directory / "release.json").write_text(json.dumps(descriptor))
            (directory / "trust-root.ed25519.pub").write_bytes(self.public)
            (directory / "catalog.json").write_text(json.dumps({"schemaVersion": 5, "sequence": 1,
                "models": [{"status": "enabled", "installationProfile": profile}]}))
            self.sign(directory)
        (release / "release.json").write_text(json.dumps(descriptor))

    def sign(self, directory):
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in",
                        str(directory / "catalog.json"), "-out", str(directory / "catalog.json.sig")], check=True)

    def test_complete_authenticated_set(self):
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES))
        self.assertEqual((output / "catalog.json").read_bytes(),
                         (self.profiles / "fedora-kde/catalog.json").read_bytes())

    def test_complete_native_only_set(self):
        for profile in module.PROFILES:
            directory = self.profiles / profile
            catalog = json.loads((directory / "catalog.json").read_text())
            catalog["installer"] = {"minimumVersion": "0.1.0", "latestVersion": "0.1.0"}
            (directory / "catalog.json").write_text(json.dumps(catalog))
            self.sign(directory)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES))
        self.assertEqual(json.loads((output / "catalog.json").read_text())["schemaVersion"], 5)

    def declare(self, channel):
        for profile in module.PROFILES:
            directory = self.profiles / profile
            catalog = json.loads((directory / "catalog.json").read_text())
            catalog["channel"] = channel
            (directory / "catalog.json").write_text(json.dumps(catalog))
            self.sign(directory)

    def test_a_delivery_declaring_testing_is_the_bundled_default(self):
        self.declare("testing")
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual(json.loads((output / "catalog.json").read_text())["channel"], "testing")

    def test_a_delivery_signed_for_another_channel_emits_no_release(self):
        for channel in ("stable", "rc", "edge", "", 5):
            with self.subTest(channel=channel):
                self.declare(channel)
                output = self.root / f"output-{channel}"
                with patch.object(module, "ROOT", self.root), self.assertRaises(ValueError):
                    module.prepare(self.profiles, output, sealed=True)
                self.assertFalse(output.exists())

    def test_default_accepts_nine_profiles_and_opt_in_requires_omarchy(self):
        import shutil
        shutil.rmtree(self.profiles / module.OMARCHY_PROFILE)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            with patch.dict(os.environ, {"AURORA_ENABLE_OMARCHY": "1"}):
                with self.assertRaisesRegex(ValueError, "missing omarchy-hyprland"):
                    module.prepare(self.profiles, output, sealed=True)
                self.assertFalse(output.exists())
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES))

    def test_opt_in_adds_the_signed_omarchy_profile(self):
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), patch.dict(os.environ, {"AURORA_ENABLE_OMARCHY": "1"}):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES) | {module.OMARCHY_PROFILE})
        for name in ("catalog.json", "catalog.json.sig"):
            self.assertEqual((output / "Profiles" / module.OMARCHY_PROFILE / name).read_bytes(),
                             (self.profiles / module.OMARCHY_PROFILE / name).read_bytes())

    def test_engine_pinning_catalogs_emit_no_release(self):
        directory = self.profiles / "fedora-kde"
        catalog = json.loads((directory / "catalog.json").read_text())
        catalog["schemaVersion"] = 4
        (directory / "catalog.json").write_text(json.dumps(catalog))
        self.sign(directory)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaisesRegex(ValueError, "native-only schema 5"):
            module.prepare(self.profiles, output)
        self.assertFalse(output.exists())
        catalog["schemaVersion"] = 5
        catalog["models"][0]["engineArtifact"] = {"fileName": "engine.tar.gz"}
        (directory / "catalog.json").write_text(json.dumps(catalog))
        self.sign(directory)
        with patch.object(module, "ROOT", self.root), self.assertRaisesRegex(ValueError, "execution archive"):
            module.prepare(self.profiles, output)
        self.assertFalse(output.exists())

    def test_tampered_catalog_emits_no_partial_release(self):
        directory = self.profiles / "nixos-minimal"
        with (directory / "catalog.json").open("a") as stream:
            stream.write(" ")
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaises(subprocess.CalledProcessError):
            module.prepare(self.profiles, output)
        self.assertFalse(output.exists())

    def test_valid_signature_cannot_substitute_another_profile(self):
        directory = self.profiles / "arch-kde"
        catalog = json.loads((directory / "catalog.json").read_text())
        catalog["models"][0]["installationProfile"] = "fedora-kde"
        (directory / "catalog.json").write_text(json.dumps(catalog))
        self.sign(directory)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaises(ValueError):
            module.prepare(self.profiles, output)
        self.assertFalse(output.exists())

    def test_descriptor_must_use_the_configured_host(self):
        directory = self.profiles / "fedora-kde"
        descriptor = json.loads((directory / "release.json").read_text())
        descriptor["channels"]["edge"]["catalog_url"] = "https://foreign.invalid/catalog.signed.json"
        (directory / "release.json").write_text(json.dumps(descriptor))
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaises(ValueError):
            module.prepare(self.profiles, output)
        self.assertFalse(output.exists())

    def test_named_build_binds_root_and_all_profiles_without_changing_signed_catalogs(self):
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True, signing_team="TESTTEAM01")
        expected = ('anchor apple generic and identifier "invalid.example.installer.helper" '
                    'and certificate leaf[subject.OU] = "TESTTEAM01"')
        descriptors = [output / "release.json"] + [output / "Profiles" / p / "release.json" for p in module.PROFILES]
        for descriptor in descriptors:
            self.assertEqual(json.loads(descriptor.read_text())["helper_code_signing_requirement"], expected)
        for profile in module.PROFILES:
            for name in ("catalog.json", "catalog.json.sig", "trust-root.ed25519.pub"):
                self.assertEqual((output / "Profiles" / profile / name).read_bytes(),
                                 (self.profiles / profile / name).read_bytes())

    def test_invalid_team_and_changed_helper_emit_no_partial_named_release(self):
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaises(ValueError):
            module.prepare(self.profiles, output, signing_team='bad"team')
        self.assertFalse(output.exists())
        path = self.profiles / "arch-minimal/release.json"
        descriptor = json.loads(path.read_text())
        descriptor["helper_mach_service_name"] = "invalid.example.foreign.helper"
        path.write_text(json.dumps(descriptor))
        with patch.object(module, "ROOT", self.root), self.assertRaises(ValueError):
            module.prepare(self.profiles, output, signing_team="TESTTEAM01")
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
