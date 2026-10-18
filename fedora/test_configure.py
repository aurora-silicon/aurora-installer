#!/usr/bin/env python3
"""Exercise image preparation without building or installing an operating system."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("configure.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="aurora-fedora-test-")
        cls.root = Path(cls.temporary.name)
        cls.source = cls.root / "upstream"
        cls.source.mkdir()
        for name in ("components", "platforms", "repositories", "root"):
            (cls.source / name).mkdir()
        (cls.source / "config.xml").write_text('''<image name="Fedora-Asahi-Remix">
          <description><author>Upstream</author><contact>upstream@example.org</contact><specification>Upstream</specification></description>
          <preferences><release-version>44</release-version><rpm-check-signatures>true</rpm-check-signatures></preferences>
          <include from="this://./repositories/asahi.xml"/></image>''')
        for path, (profile, _) in configure.PACKAGES.items():
            (cls.source / path).write_text(
                f'<image><packages type="image" profiles="{profile}"><package name="kernel-16k"/>'
                '<package name="fedora-release-kde"/><package name="mesa-dri-drivers"/></packages></image>')
        (cls.source / "repositories/asahi.xml").write_text("<image/>")
        for name in ("config.sh", "post_bootstrap.sh", "pre_disk_sync.sh"):
            (cls.source / name).write_text("#!/bin/bash\n# kernel-16k-core\n")
        (cls.source / "COPYING").write_text("upstream license fixture\n")
        subprocess.run(["git", "init", "-q", str(cls.source)], check=True)
        subprocess.run(["git", "-C", str(cls.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(cls.source), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.org", "commit", "-qm", "fixture"], check=True)
        cls.lock = {"commit": configure.git(cls.source, "rev-parse", "HEAD"), "fedora_release": "44"}
        cls.home = cls.root / "gpg"
        cls.home.mkdir(mode=0o700)
        subprocess.run(["gpg", "--no-options", "--homedir", str(cls.home), "--batch",
                        "--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
                        "Aurora fixture <fixture@example.org>", "ed25519", "sign", "0"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key = cls.root / "key.asc"
        cls.key.write_bytes(subprocess.check_output([
            "gpg", "--no-options", "--homedir", str(cls.home), "--armor", "--export",
        ]))
        cls.fingerprint = configure.signing_fingerprint(cls.key)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def prepare(self, output, **kwargs):
        args = dict(source=self.source, destination=output, profile="fedora-kde",
                    repository_url="https://packages.example.org/fedora/44/aarch64",
                    key=self.key, fingerprint=self.fingerprint, lock=self.lock)
        args.update(kwargs)
        return configure.prepare(**args)

    def test_all_profiles_keep_fedora_layout_and_aurora_packages(self):
        for profile, kiwi in configure.PROFILES.items():
            with self.subTest(profile=profile):
                out = self.root / profile
                receipt = self.prepare(out, profile=profile)
                self.assertEqual(receipt["kiwi_profile"], kiwi)
                self.assertFalse(receipt["image_built"])
                self.assertIn("--target-arch=aarch64", receipt["build_command"])
                self.assertEqual(receipt["layout"]["root_subvolume"], "root")
                self.assertEqual(receipt["layout"]["boot_manager"], "grub2")
                image = ET.parse(out / "config.xml").getroot()
                self.assertEqual(image.get("name"), "Fedora-Aurora-Remix")
                self.assertEqual(image.find("preferences/rpm-check-signatures").text, "true")
                names = {n.get("name") for p in out.rglob("*.xml")
                         for n in ET.parse(p).getroot().iter("package")}
                self.assertFalse(configure.REPLACED & names)
                self.assertIn("kernel-aurora", names)
                self.assertIn("mesa-aurora-vulkan-drivers", names)
                self.assertFalse((out / "repositories/asahi.xml").exists())
                self.assertIn("repo_gpgcheck=1", (out / "root/etc/yum.repos.d/aurora.repo").read_text())
                self.assertEqual((out / "root/etc/pki/rpm-gpg/RPM-GPG-KEY-aurora").read_bytes(), self.key.read_bytes())
                self.assertEqual((out / "COPYING").read_text(), "upstream license fixture\n")
                self.assertEqual(json.loads((out / "aurora-image.json").read_text()), receipt)
        self.assertEqual(configure.git(self.source, "status", "--porcelain"), "")

    def test_rejects_wrong_source_key_profile_and_unsafe_repository(self):
        cases = [dict(lock={**self.lock, "commit": "0" * 40}),
                 dict(fingerprint="0" * 40), dict(profile="not-fedora"),
                 dict(repository_url="http://packages.example.org"),
                 dict(repository_url="https://user:secret@packages.example.org"),
                 dict(repository_url="https://packages.example.org/?token=secret")]
        for index, kwargs in enumerate(cases):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.prepare(self.root / f"rejected-{index}", **kwargs)
            self.assertFalse((self.root / f"rejected-{index}").exists())

    def test_does_not_overwrite_an_existing_description(self):
        destination = self.root / "existing"
        destination.mkdir()
        (destination / "keep").write_text("preserve")
        with self.assertRaises(ValueError):
            self.prepare(destination)
        self.assertEqual((destination / "keep").read_text(), "preserve")

    def test_output_cannot_recurse_into_the_upstream_checkout(self):
        with self.assertRaisesRegex(ValueError, "outside"):
            self.prepare(self.source / "generated")
        self.assertFalse((self.source / "generated").exists())


if __name__ == "__main__":
    unittest.main()
