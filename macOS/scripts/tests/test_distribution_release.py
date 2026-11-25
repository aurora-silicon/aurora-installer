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


VECTORS = (Path(__file__).resolve().parents[2]
           / "Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/legacy-testing-catalog-vectors.json")


def delivery_model(profile, run="41"):
    """A model of the published development delivery lineage."""
    repository = {"fedora": "fedora-aurora", "arch": "alarm-aurora", "nixos": "nixos-aurora",
                  "omarchy": "omarchy-aurora", "debian": "debian-aurora"}[profile.split("-")[0]]
    name = f"{profile}-build-{run}.zip"
    return {"status": "enabled", "installationProfile": profile, "evidenceRevision": f"image-build-{run}",
            "payloadArtifact": {"sourceURL": f"https://github.com/aurora-silicon/{repository}/releases/download/"
                                             f"payload-{profile}-{run}/{name}",
                                "fileName": name, "sizeBytes": 1}}


class LegacyTestingVectorTests(unittest.TestCase):
    def test_undeclared_testing_vectors_match_the_app(self):
        # ReleaseChannelAvailabilityTests runs the same vectors through
        # ReleaseCatalogChannelPolicy.validate, so both accept the same catalogs.
        cases = json.loads(VECTORS.read_text())["cases"]
        self.assertTrue(cases)
        for case in cases:
            with self.subTest(case=case["name"]):
                catalog = {"schemaVersion": 5, "sequence": 1, "models": case["models"]}
                self.assertEqual(module.is_legacy_testing_catalog(catalog, set(module.PROFILES)),
                                 case["acceptedAsTesting"])
                if case["acceptedAsTesting"]:
                    module.check_bundled_default(catalog, "testing", set(module.PROFILES), "vector")
                else:
                    with self.assertRaises(ValueError):
                        module.check_bundled_default(catalog, "testing", set(module.PROFILES), "vector")


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
        for profile in module.PROFILES + (module.OMARCHY_PROFILE,) + module.DEBIAN_PROFILES:
            directory = self.profiles / profile
            directory.mkdir(parents=True)
            descriptor = {"schema_version": 3, "default_channel": "testing", "trust_root_fingerprint": fingerprint,
                          "helper_mach_service_name": "invalid.example.installer.helper",
                          "helper_code_signing_requirement": 'identifier "invalid.example.installer.helper"',
                          "channels": {channel: {"catalog_url": "https://delivery.invalid/native/Profiles/"
                                                 + profile + "/channels/" + ("edge-alpha" if channel == "edge" else channel) + "/catalog.signed.json"}
                                       for channel in ("stable", "rc", "testing", "edge")}}
            (directory / "release.json").write_text(json.dumps(descriptor))
            (directory / "trust-root.ed25519.pub").write_bytes(self.public)
            catalog = {"schemaVersion": 5, "sequence": 1, "models": [delivery_model(profile)]}
            if profile in module.DEBIAN_PROFILES:
                # Debian has no catalogs from before the channel field.
                catalog["channel"] = "testing"
            (directory / "catalog.json").write_text(json.dumps(catalog))
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
                         set(module.PROFILES) | set(module.DEBIAN_PROFILES))
        self.assertEqual((output / "catalog.json").read_bytes(),
                         (self.profiles / "fedora-kde/catalog.json").read_bytes())

    def test_complete_native_only_set(self):
        for profile in module.PROFILES + module.DEBIAN_PROFILES:
            directory = self.profiles / profile
            catalog = json.loads((directory / "catalog.json").read_text())
            catalog["installer"] = {"minimumVersion": "0.1.0", "latestVersion": "0.1.0"}
            (directory / "catalog.json").write_text(json.dumps(catalog))
            self.sign(directory)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES) | set(module.DEBIAN_PROFILES))
        self.assertEqual(json.loads((output / "catalog.json").read_text())["schemaVersion"], 5)

    def declare(self, channel):
        for profile in module.PROFILES + module.DEBIAN_PROFILES:
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

    def rewrite(self, profile, edit):
        directory = self.profiles / profile
        catalog = json.loads((directory / "catalog.json").read_text())
        edit(catalog)
        (directory / "catalog.json").write_text(json.dumps(catalog))
        self.sign(directory)

    def set_default(self, channel):
        for path in [self.root / "Release/release.json"] + [self.profiles / p / "release.json"
                                                            for p in module.PROFILES + module.DEBIAN_PROFILES]:
            descriptor = json.loads(path.read_text())
            descriptor["default_channel"] = channel
            path.write_text(json.dumps(descriptor))

    def assert_refused_undeclared(self, profile, edit):
        self.rewrite(profile, edit)
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaisesRegex(
                ValueError, f"undeclared bundled catalog must be a Testing development delivery: {profile}"):
            module.prepare(self.profiles, output, sealed=True)
        self.assertFalse(output.exists())

    def test_an_undeclared_bundled_default_must_be_of_the_delivery_lineage(self):
        # The app reads an undeclared catalog as Testing only when every model
        # is of the published development delivery lineage.
        def foreign(catalog):
            catalog["models"][0]["payloadArtifact"]["sourceURL"] = "https://downloads.example.com/payload.zip"
        self.assert_refused_undeclared("nixos-gnome", foreign)

    def test_an_undeclared_bundled_default_of_only_disabled_macs_is_refused(self):
        def disabled(catalog):
            catalog["models"] = [{"deviceIdentifier": "apple,j274", "status": "disabled"}]
        self.assert_refused_undeclared("arch-kde", disabled)

    def test_the_bundled_default_must_be_the_default_channel(self):
        self.set_default("stable")
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), self.assertRaisesRegex(
                ValueError, "undeclared bundled catalog"):
            module.prepare(self.profiles, output, sealed=True)
        self.declare("testing")
        with patch.object(module, "ROOT", self.root), self.assertRaisesRegex(
                ValueError, "must declare stable"):
            module.prepare(self.profiles, output, sealed=True)
        self.assertFalse(output.exists())
        self.declare("stable")
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual(json.loads((output / "catalog.json").read_text())["channel"], "stable")

    def test_default_accepts_present_profiles_and_opt_in_requires_omarchy(self):
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
                         set(module.PROFILES) | set(module.DEBIAN_PROFILES))

    def test_opt_in_adds_the_signed_omarchy_profile(self):
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root), patch.dict(os.environ, {"AURORA_ENABLE_OMARCHY": "1"}):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES) | set(module.DEBIAN_PROFILES) | {module.OMARCHY_PROFILE})
        for name in ("catalog.json", "catalog.json.sig"):
            self.assertEqual((output / "Profiles" / module.OMARCHY_PROFILE / name).read_bytes(),
                             (self.profiles / module.OMARCHY_PROFILE / name).read_bytes())

    def test_debian_profiles_are_included_when_present_and_require_all_three(self):
        import shutil
        output = self.root / "output"
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()},
                         set(module.PROFILES) | set(module.DEBIAN_PROFILES))
        for profile in module.DEBIAN_PROFILES:
            for name in ("catalog.json", "catalog.json.sig"):
                self.assertEqual((output / "Profiles" / profile / name).read_bytes(),
                                 (self.profiles / profile / name).read_bytes())
        shutil.rmtree(output)
        shutil.rmtree(self.profiles / "debian-gnome")
        with patch.object(module, "ROOT", self.root):
            with self.assertRaisesRegex(ValueError, "missing debian-gnome"):
                module.prepare(self.profiles, output, sealed=True)
        self.assertFalse(output.exists())
        for profile in ("debian-kde", "debian-minimal"):
            shutil.rmtree(self.profiles / profile)
        with patch.object(module, "ROOT", self.root):
            module.prepare(self.profiles, output, sealed=True)
        self.assertEqual({entry.name for entry in (output / "Profiles").iterdir()}, set(module.PROFILES))

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
