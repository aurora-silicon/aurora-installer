"""Exercise disposable-volume failure cleanup without any real disk commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "test" / "with-fat-fixture.sh"


class FATFixtureCleanupTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "commands"
            commands.mkdir()
            temporary = root / "temporary"
            temporary.mkdir()
            log = root / "calls.jsonl"
            image = root / "image-path"
            (commands / "uname").write_text("#!/bin/bash\necho Darwin\n")
            (commands / "df").write_text("#!/bin/bash\necho 'Filesystem 1024-blocks Used Available Use% Mounted'\necho 'mock 20971520 0 20971520 0% /'\n")
            mock = '''#!PYTHON
import json,os,plistlib,sys
from pathlib import Path
log=Path(os.environ['MOCK_LOG'])
with log.open('a') as out: out.write(json.dumps(sys.argv)+'\\n')
mode=os.environ['MOCK_MODE']; image=Path(os.environ['MOCK_IMAGE'])
if Path(sys.argv[0]).name=='sudo': raise SystemExit(97)
operation=sys.argv[1]
if operation=='create':
    image.write_text(sys.argv[-1]); Path(sys.argv[-1]).write_bytes(b'disposable')
elif operation=='attach':
    if mode=='partial': raise SystemExit(96)
    if mode=='malformed': sys.stdout.write('not a plist')
    else: plistlib.dump({'system-entities':[{'dev-entry':'/dev/disk99'}]},sys.stdout.buffer)
elif operation=='info':
    path='/another/image.dmg' if mode=='foreign' else image.read_text()
    plistlib.dump({'images':[{'image-path':path,'system-entities':[{'dev-entry':'/dev/disk99'}]}]},sys.stdout.buffer)
elif operation!='detach': raise SystemExit(95)
'''.replace("PYTHON", sys.executable)
            for name in ("hdiutil", "sudo"):
                (commands / name).write_text(mock)
            for file in commands.iterdir():
                file.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), "true"],
                env={**os.environ, "PATH": str(commands) + ":" + os.environ["PATH"],
                     "RUNNER_TEMP": str(temporary), "MOCK_LOG": str(log),
                     "MOCK_IMAGE": str(image), "MOCK_MODE": mode},
                capture_output=True, text=True, timeout=10,
            )
            self.assertTrue(log.exists(), result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            actions = [(Path(call[0]).name, call[1:]) for call in calls]
            leftovers = list(temporary.iterdir())
            self.assertNotEqual(result.returncode, 0)
            if mode == "verified":
                self.assertEqual(result.returncode, 97)
                self.assertIn(("hdiutil", ["detach", "/dev/disk99"]), actions)
                self.assertFalse(leftovers)
                self.assertTrue(any(name == "sudo" for name, _ in actions))
            else:
                self.assertEqual(len(leftovers), 1)
                self.assertTrue((leftovers[0] / "volume.dmg").is_file())
                self.assertFalse(any(name == "sudo" or args[0] == "detach" for name, args in actions))
                self.assertIn("Retained potentially attached fixture", result.stderr)

    def test_malformed_attachment_retains_its_backing_image(self):
        self.exercise("malformed")

    def test_foreign_device_identity_is_never_formatted_or_detached(self):
        self.exercise("foreign")

    def test_partial_attachment_failure_preserves_evidence(self):
        self.exercise("partial")

    def test_verified_format_failure_detaches_only_its_owned_device(self):
        self.exercise("verified")
