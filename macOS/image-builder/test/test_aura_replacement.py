#!/usr/bin/env python3
"""aura, Aurora's bootloader, fills m1n1-aurora's place in an installed image; nothing else does."""
import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "builder"))
from verify_installed_system import installed_package_names  # noqa: E402

loader = importlib.machinery.SourceFileLoader("mac_image_check", str(ROOT / "bin/mac-image-check"))
spec = importlib.util.spec_from_loader("mac_image_check", loader)
check = importlib.util.module_from_spec(spec)
loader.exec_module(check)


def install(root: Path, name: str, provides=()):
    entry = root / "var/lib/pacman/local" / f"{name}-1-1"
    entry.mkdir(parents=True)
    text = f"%NAME%\n{name}\n\n%VERSION%\n1-1\n\n"
    if provides:
        text += "%PROVIDES%\n" + "".join(p + "\n" for p in provides) + "\n"
    (entry / "desc").write_text(text)


class AuraReplacementTest(unittest.TestCase):
    def names(self, packages):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, provides in packages:
                install(root, name, provides)
            return installed_package_names(root), check.installed_packages(root)

    def test_aura_fills_m1n1_aurora(self):
        for names in self.names([("aura", ["m1n1=1.6.1", "m1n1-aurora=1.0b1", "m1n1-neo"])]):
            self.assertIn("aura", names)
            self.assertIn("m1n1-aurora", names)
            # Only the mapped role, not everything aura provides.
            self.assertNotIn("m1n1", names)
            self.assertNotIn("m1n1-neo", names)

    def test_aura_without_the_provide_fills_nothing(self):
        for names in self.names([("aura", [])]):
            self.assertNotIn("m1n1-aurora", names)

    def test_another_package_claiming_m1n1_aurora_fills_nothing(self):
        for names in self.names([("m1n1-fork", ["m1n1-aurora"])]):
            self.assertNotIn("m1n1-aurora", names)

    def test_legacy_m1n1_aurora_still_counts(self):
        for names in self.names([("m1n1-aurora", ["m1n1"])]):
            self.assertIn("m1n1-aurora", names)


if __name__ == "__main__":
    unittest.main()
