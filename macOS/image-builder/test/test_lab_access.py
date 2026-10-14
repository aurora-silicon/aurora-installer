#!/usr/bin/env python3
"""Lab access: only public keys go in, a lab tree carries exactly the overlay,
and a release tree refuses lab access however it got there."""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lab_access", ROOT / "builder/lab_access.py")
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm3ZIe3P3NW/VLwzdZ6vgFvk4OAabP02rnxiZKmXG2r lab-controller"
THUNDERBOLT = "*M2 Max*|10.77.0.3/24\n*M1 Pro*|10.77.0.4/24\n"


def write(path: Path, body: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    os.chmod(path, mode)


class AccessInputTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        write(self.dir / "authorized_keys", KEY + "\n")
        write(self.dir / "thunderbolt", THUNDERBOLT)

    def test_public_keys_load(self):
        access = lab.load(self.dir)
        self.assertEqual(access["user"], "maralc")
        self.assertEqual(access["keys"], [KEY])
        self.assertEqual(access["thunderbolt"], [("*M2 Max*", "10.77.0.3/24"), ("*M1 Pro*", "10.77.0.4/24")])

    def test_refused_inputs(self):
        cases = {
            "a private key": ("authorized_keys", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n"),
            "a Tailscale key": ("authorized_keys", KEY + "\n# tskey-auth-kXXXX\n"),
            "an RSA key": ("authorized_keys", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ x\n"),
            "key options": ("authorized_keys", 'command="/bin/sh" ' + KEY + "\n"),
            "a key blob of another type": ("authorized_keys", "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABAQ x\n"),
            "no keys": ("authorized_keys", "# none\n"),
            "root": ("user", "root\n"),
            "a default route address": ("thunderbolt", "*M2 Max*|0.0.0.0/0\n"),
            "an unknown file": ("tailscale-authkey", "x\n"),
        }
        for what, (name, body) in cases.items():
            with self.subTest(what=what):
                directory = Path(tempfile.mkdtemp())
                self.addCleanup(shutil.rmtree, directory)
                write(directory / "authorized_keys", KEY + "\n")
                write(directory / name, body)
                with self.assertRaises(lab.LabAccessError):
                    lab.load(directory)


class TreeTest(unittest.TestCase):
    """A clean image root, as far as lab access is concerned."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        write(self.root / "usr/lib/systemd/system/sshd.service", "[Service]\n")
        write(self.root / "etc/ssh/sshd_config", "Include /etc/ssh/sshd_config.d/*.conf\n"
                                                 "AuthorizedKeysFile .ssh/authorized_keys\n")
        write(self.root / "etc/ssh/sshd_config.d/20-systemd-userdb.conf",
              "AuthorizedKeysCommand /usr/bin/userdbctl ssh-authorized-keys %u\nAuthorizedKeysCommandUser root\n")
        write(self.root / "etc/sudoers", "root ALL=(ALL:ALL) ALL\n# %wheel ALL=(ALL:ALL) NOPASSWD: ALL\n", 0o440)
        # What a real image ships: narrow grants and systemd's group rule.
        write(self.root / "etc/sudoers.d/omarchy-dns",
              "%wheel ALL=(root) NOPASSWD: /usr/bin/omarchy-dns Cloudflare, /usr/bin/omarchy-dns DHCP\n", 0o440)
        write(self.root / "usr/share/polkit-1/rules.d/empower.rules",
              'polkit.addRule(function(action, subject) {\n  if (subject.isInGroup("empower")) {\n'
              "    return polkit.Result.YES;\n  }\n});\n")
        write(self.root / "usr/share/polkit-1/rules.d/50-default.rules",
              'polkit.addAdminRule(function(action, subject) { return ["unix-group:wheel"]; });\n')
        (self.root / "etc/polkit-1/rules.d").mkdir(parents=True)
        (self.root / "home").mkdir()

    def lab_dir(self) -> Path:
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        write(directory / "authorized_keys", KEY + "\n")
        write(directory / "thunderbolt", THUNDERBOLT)
        return directory

    def test_a_clean_tree_passes_release(self):
        self.assertEqual(lab.findings(self.root), [])
        lab.check(self.root, "the image", lab=False)

    def test_the_overlay_passes_lab_and_fails_release(self):
        digest = lab.apply(lab.load(self.lab_dir()), self.root)
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        self.assertIn(f"access_sha256={digest}", (self.root / lab.PROFILE).read_text())
        lab.check(self.root, "the image", lab=True)
        with self.assertRaisesRegex(lab.LabAccessError, "carries lab access"):
            lab.check(self.root, "the image", lab=False)
        found = {path for path, _, _ in lab.findings(self.root)}
        for path in ("etc/sudoers.d/omarchy-lab", "etc/polkit-1/rules.d/49-omarchy-lab.rules",
                     "etc/ssh/sshd_config.d/40-omarchy-lab.conf", "etc/omarchy-lab/authorized_keys",
                     "etc/systemd/system/multi-user.target.wants/sshd.service"):
            self.assertIn(path, found)

    def test_the_overlay_is_idempotent(self):
        access = lab.load(self.lab_dir())
        self.assertEqual(lab.apply(access, self.root), lab.apply(access, self.root))
        lab.check(self.root, "the image", lab=True)

    def test_release_refuses_each_artifact_without_the_marker(self):
        artifacts = {
            "home/maralc/.ssh/authorized_keys": (KEY + "\n", 0o600),
            "etc/ssh/authorized_keys.d/maralc": (KEY + "\n", 0o644),
            "etc/ssh/sshd_config.d/10-access.conf": ("AuthorizedKeysFile /etc/ssh/keys/%u\n", 0o644),
            "etc/sudoers.d/zz-tester": ("maralc ALL=(ALL) NOPASSWD: ALL\n", 0o440),
            "etc/sudoers.d/zz-auth": ("Defaults:maralc !authenticate\n", 0o440),
            "etc/polkit-1/rules.d/10-tester.rules": (
                'polkit.addRule(function(a, s) { if (s.isInGroup("wheel")) return polkit.Result.YES; });\n', 0o644),
            "usr/share/polkit-1/rules.d/10-user.rules": (
                'polkit.addRule(function(a, s) { if (s.user == "maralc") return polkit.Result.YES; });\n', 0o644),
            "etc/systemd/system/multi-user.target.wants/sshd.service": None,
            "etc/systemd/system/sockets.target.wants/sshd.socket": None,
            "etc/systemd/system-preset/10-remote.preset": ("enable sshd.service\n", 0o644),
            "etc/ssh/sshd_config.d/10-ca.conf": ("TrustedUserCAKeys /etc/ssh/ca.pub\n", 0o644),
            "etc/sudoers.d/zz-setenv": ("maralc ALL=(ALL) NOPASSWD:SETENV: ALL\n", 0o440),
            "etc/NetworkManager/system-connections/lab-thunderbolt.nmconnection": ("[connection]\n", 0o600),
            "usr/local/bin/omarchy-lab-renamed": ("#!/bin/bash\n", 0o755),
        }
        for path, content in artifacts.items():
            with self.subTest(path=path):
                root = Path(tempfile.mkdtemp()) / "root"
                self.addCleanup(shutil.rmtree, root.parent)
                shutil.copytree(self.root, root, symlinks=True)
                target = root / path
                if content is None:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to("/usr/lib/systemd/system/sshd.service")
                else:
                    write(target, *content)
                with self.assertRaisesRegex(lab.LabAccessError, "carries lab access"):
                    lab.check(root, "the image", lab=False)

    def test_credentials_are_refused_in_every_profile(self):
        lab.apply(lab.load(self.lab_dir()), self.root)
        for path, body in (("etc/cryptsetup-keys.d/root.key", "k"),
                           ("etc/tailscale/authkey", "tskey-auth-k123-abc\n"),
                           ("var/lib/tailscale/tailscaled.state", "x tskey-auth-k123 x"),
                           ("var/log/lab.log", "joined with tskey-auth-k123\n"),
                           ("root/.ssh/id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\n")):
            with self.subTest(path=path):
                write(self.root / path, body, 0o600)
                with self.assertRaisesRegex(lab.LabAccessError, "credentials"):
                    lab.check(self.root, "the image", lab=True)
                (self.root / path).unlink()
        write(self.root / "etc/mkinitcpio.conf.d/99-lab-autounlock.conf", "FILES+=(/etc/cryptsetup-keys.d/root.key)\n")
        with self.assertRaisesRegex(lab.LabAccessError, "credentials"):
            lab.check(self.root, "the image", lab=True)

    def test_lab_refuses_anything_beyond_the_overlay(self):
        lab.apply(lab.load(self.lab_dir()), self.root)
        write(self.root / "home/maralc/.ssh/authorized_keys", KEY + "\n", 0o600)
        with self.assertRaisesRegex(lab.LabAccessError, "outside the overlay"):
            lab.check(self.root, "the image", lab=True)

    def test_lab_refuses_an_edited_or_missing_overlay_file(self):
        lab.apply(lab.load(self.lab_dir()), self.root)
        sudoers = self.root / "etc/sudoers.d/omarchy-lab"
        os.chmod(sudoers, 0o640)
        sudoers.write_text("maralc ALL=(ALL) NOPASSWD: ALL\nguest ALL=(ALL) NOPASSWD: ALL\n")
        os.chmod(sudoers, 0o440)
        with self.assertRaisesRegex(lab.LabAccessError, "not the lab overlay's"):
            lab.check(self.root, "the image", lab=True)
        sudoers.unlink()
        with self.assertRaisesRegex(lab.LabAccessError, "lacks /etc/sudoers.d/omarchy-lab"):
            lab.check(self.root, "the image", lab=True)

    def test_lab_needs_its_profile_record(self):
        lab.apply(lab.load(self.lab_dir()), self.root)
        (self.root / lab.PROFILE).unlink()
        with self.assertRaisesRegex(lab.LabAccessError, "has no /etc/omarchy-lab/profile"):
            lab.check(self.root, "the image", lab=True)

    def test_initramfs(self):
        self.assertEqual(lab.initramfs_findings(["usr/bin/cryptsetup", "etc/crypttab"], b"plain"), [])
        for members, contents in ((["etc/cryptsetup-keys.d/root.key"], b""), (["etc/omarchy-lab/x"], b""),
                                  (["root/.ssh/authorized_keys"], b""), (["etc/renamed"], b"x tskey-auth-1 x")):
            with self.subTest(members=members):
                self.assertTrue(lab.initramfs_findings(members, contents))


if __name__ == "__main__":
    unittest.main()
