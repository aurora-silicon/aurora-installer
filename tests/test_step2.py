# SPDX-License-Identifier: MIT
"""step2.sh in raw and Mach-O modes, with every system tool replaced by a stub.

The stubs only log their arguments: nothing here touches a boot policy. The
script itself writes /tmp/bp.txt, as it does in recoveryOS."""
import os, subprocess, sys, tempfile, unittest
from types import SimpleNamespace

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "..", "src")
sys.path.insert(0, SRC)

import stub  # noqa: E402

VGID = "11111111-2222-3333-4444-555555555555"
TOOLS = ("bputil", "kmutil", "csrutil", "bless", "diskutil", "mount", "shutdown", "reboot")
STUB_TOOL = r"""#!/bin/sh
echo "$(basename "$0") $*" >> "$CALLS"
case "$(basename "$0") $1" in
    "bputil -d") printf 'OS Type: one true recoveryOS\nLocal Policy: Paired\nKernel CTRR Status: %s\n' "$CTRR" ;;
    "kmutil inspect") printf 'kcbz : %s\n' "$KCBZ" ;;
esac
exit 0
"""

def render(mode):
    ins = stub.StubInstaller(None, None, None)
    ins.boot_mode = mode
    ins.osi = SimpleNamespace(vgid=VGID, preboot_vgid="disk9s2")
    with open(os.path.join(SRC, "step2", "step2.sh")) as fd:
        return ins.render_step2(fd.read())


class Step2Test(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.system = os.path.join(root, "System-volume")
        self.res = os.path.join(self.system, "a", "b", "c")
        os.makedirs(self.res)
        self.bin = os.path.join(root, "bin")
        os.makedirs(self.bin)
        for tool in TOOLS:
            path = os.path.join(self.bin, tool)
            with open(path, "w") as fd:
                fd.write(STUB_TOOL)
            os.chmod(path, 0o755)
        self.calls = os.path.join(root, "calls.log")

    def tearDown(self):
        self.tmp.cleanup()

    def run_step2(self, mode, boot_object=True, ctrr="Disabled", kcbz="0", answer="enroll"):
        script = os.path.join(self.res, "step2.sh")
        with open(script, "w") as fd:
            fd.write(render(mode))
        os.chmod(script, 0o755)
        if boot_object:
            name = "boot.macho" if mode == "macho" else "boot.bin"
            with open(os.path.join(self.res, name), "wb") as fd:
                fd.write(b"boot object")
        env = dict(PATH=self.bin + ":/usr/bin:/bin", CALLS=self.calls, CTRR=ctrr, KCBZ=kcbz)
        # The Mach-O gate reads one answer first; the rest are "Press enter" prompts.
        stdin = (answer.encode() + b"\n" if mode == "macho" else b"") + b"\n" * 20
        res = subprocess.run(["/bin/sh", script], input=stdin, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        calls = []
        if os.path.exists(self.calls):
            with open(self.calls) as fd:
                calls = fd.read().splitlines()
        return res, calls

    def test_rendered_script_parses(self):
        for mode in ("raw", "macho"):
            text = render(mode)
            self.assertIn(f'BOOT_MODE="{mode}"', text)
            for placeholder in ("##BOOT_MODE##", "##VGID##", "##PREBOOT##", "##DISTRO##"):
                self.assertNotIn(placeholder, text)
            subprocess.run(["/bin/sh", "-n"], input=text.encode(), check=True)

    def test_unknown_mode_refused(self):
        with self.assertRaises(Exception):
            render("other")

    def test_raw_mode_unchanged(self):
        res, calls = self.run_step2("raw")
        self.assertEqual(res.returncode, 0, res.stdout.decode())
        self.assertIn(f"bputil -nc -v {VGID}", calls)
        self.assertIn("kmutil configure-boot -c boot.bin --raw --entry-point 2048 "
                      f"--lowest-virtual-address 0 -v {self.system}", calls)
        self.assertFalse(any(c.startswith("csrutil") for c in calls))
        self.assertIn("reboot ", calls)

    def test_macho_mode_enrolls(self):
        res, calls = self.run_step2("macho")
        self.assertEqual(res.returncode, 0, res.stdout.decode())
        self.assertIn(f"bputil -nkcas -v {VGID}", calls)
        self.assertIn("csrutil allow-research-guests enable", calls)
        self.assertIn(f"kmutil configure-boot -c boot.macho -v {self.system}", calls)
        self.assertFalse(any("--raw" in c for c in calls))
        # the kcbz check precedes enrollment
        inspect = next(i for i, c in enumerate(calls) if c.startswith("kmutil inspect"))
        configure = next(i for i, c in enumerate(calls) if c.startswith("kmutil configure-boot"))
        self.assertLess(inspect, configure)

    def test_macho_missing_object_changes_nothing(self):
        res, calls = self.run_step2("macho", boot_object=False)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn(b"boot.macho is missing", res.stdout)
        self.assertEqual([c for c in calls if not c.startswith("bputil -d")], [])

    def test_macho_stub_test_stops_at_the_gate(self):
        # The stub test: the pairing check runs and passes, then nothing changes.
        res, calls = self.run_step2("macho", answer="")
        self.assertEqual(res.returncode, 0, res.stdout.decode())
        self.assertIn(b"Pairing check passed", res.stdout)
        self.assertIn(b"Stopped before any change", res.stdout)
        self.assertEqual(calls, [f"bputil -d -v {VGID}"])

    def test_raw_mode_has_no_gate(self):
        res, calls = self.run_step2("raw", answer="")
        self.assertEqual(res.returncode, 0, res.stdout.decode())
        self.assertNotIn(b"Pairing check passed", res.stdout)
        self.assertIn(f"bputil -nc -v {VGID}", calls)

    def test_macho_refuses_nonzero_kcbz(self):
        res, calls = self.run_step2("macho", kcbz="65536")
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(any(c.startswith("kmutil configure-boot") for c in calls))

    def test_macho_refuses_ctrr_enabled(self):
        res, calls = self.run_step2("macho", ctrr="Enabled")
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(any(c.startswith("kmutil") for c in calls))


if __name__ == "__main__":
    unittest.main()
