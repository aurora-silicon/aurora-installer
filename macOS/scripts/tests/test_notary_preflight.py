import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NotaryPreflightTests(unittest.TestCase):
    """Tool fixtures prove rejection precedes submission; macOS qualifies real signatures."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        identity = dict(re.findall(r'^(INSTALLER_[A-Z0-9_]+)="([^"\n]+)"$',
                                   (ROOT / "Packaging/identity.conf").read_text(), re.MULTILINE))
        self.app = self.root / (identity["INSTALLER_APP_NAME"] + ".app")
        self.helper = self.app / "Contents/Library/LaunchServices" / identity["INSTALLER_HELPER_IDENTIFIER"]
        self.decoder = self.app / "Contents/Helpers/omarchy-restore-image"
        self.recovery = self.app / "Contents/Resources/RecoveryTemplate" / self.app.name
        self.recovery.mkdir(parents=True)
        for path in (self.helper, self.decoder):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic code fixture")
        self.signatures = {str(path): {"identifier": identifier, "team": "TESTTEAM01",
                                     "flags": "0x10000", "timestamp": "fixture secure timestamp",
                                     "authority": "Developer ID Application: Fixture"}
                           for path, identifier in (
                               (self.app, identity["INSTALLER_APP_IDENTIFIER"]),
                               (self.helper, identity["INSTALLER_HELPER_IDENTIFIER"]),
                               (self.decoder, identity["INSTALLER_RESTORE_IMAGE_IDENTIFIER"]),
                               (self.recovery, "invalid.example.recovery"))}
        self.manifest = self.root / "signatures.json"
        self.calls = self.root / "notary-calls.jsonl"
        self.calls.write_text("")
        tools = self.root / "tools"
        tools.mkdir()
        mock = tools / "fixture-tool"
        mock.write_text(f"#!{sys.executable}\n" + r'''
import json, os
from pathlib import Path
import re, sys
tool = Path(sys.argv[0]).name
arguments = sys.argv[1:]
signatures = json.loads(Path(os.environ["FIXTURE_SIGNATURES"]).read_text())
if tool == "codesign":
    value = signatures[arguments[-1]]
    if "--display" in arguments or "-d" in arguments:
        print("Identifier=" + value["identifier"])
        print("Authority=" + value["authority"])
        print("TeamIdentifier=" + value["team"])
        print("CodeDirectory v=20500 size=100 flags=" + value["flags"] + "(fixture)")
        if value.get("timestamp") is not None:
            print("Timestamp=" + value["timestamp"])
    else:
        for argument in arguments:
            if argument.startswith("-R="):
                identifier = re.search(r'identifier "([^"]+)"', argument)[1]
                team = re.search(r'subject.OU\] = "([^"]+)"', argument)[1]
                if value["identifier"] != identifier or value["team"] != team:
                    raise SystemExit(1)
elif tool == "plutil":
    print("invalid.example.recovery")
elif tool == "ditto":
    Path(arguments[-1]).write_bytes(b"synthetic archive")
elif tool == "xcrun":
    with Path(os.environ["FIXTURE_NOTARY_CALLS"]).open("a") as stream:
        stream.write(json.dumps(arguments) + "\n")
elif tool != "spctl":
    raise SystemExit(2)
''')
        mock.chmod(0o755)
        for name in ("codesign", "plutil", "ditto", "xcrun", "spctl"):
            (tools / name).symlink_to(mock.name)
        self.environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                                TMPDIR=str(self.root), FIXTURE_SIGNATURES=str(self.manifest),
                                FIXTURE_NOTARY_CALLS=str(self.calls), AURORA_NOTARY_PROFILE="fixture")

    def run_preflight(self, verify_only=True):
        self.manifest.write_text(json.dumps(self.signatures))
        return subprocess.run(["bash", str(ROOT / "Packaging/notarize-app.sh"),
                               *(["--verify-only"] if verify_only else []), str(self.app)],
                              env=self.environment, text=True, capture_output=True)

    def test_on_demand_bundle_needs_no_engine_archive(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), "")
        self.assertEqual(list(self.root.glob("aurora-notary.*")), [])

    def test_every_nested_executable_requires_hardened_runtime(self):
        for path in (self.app, self.helper, self.decoder, self.recovery):
            with self.subTest(path=path):
                self.signatures[str(path)]["flags"] = "0x0"
                result = self.run_preflight()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls.read_text(), "")
                self.signatures[str(path)]["flags"] = "0x10000"

    def test_missing_timestamp_and_foreign_team_never_reach_submission(self):
        for field, invalid in (("timestamp", None), ("team", "OTHERTEAM1"),
                               ("authority", "Apple Development: Fixture")):
            with self.subTest(field=field):
                previous = self.signatures[str(self.recovery)][field]
                self.signatures[str(self.recovery)][field] = invalid
                result = self.run_preflight(verify_only=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls.read_text(), "")
                self.signatures[str(self.recovery)][field] = previous

    def test_unsafe_engine_directory_is_rejected_before_submission(self):
        directory = self.app / "Contents/Resources/Engine"
        directory.mkdir()
        (directory / "artifacts").symlink_to(self.root, target_is_directory=True)
        result = self.run_preflight(verify_only=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text(), "")

    def test_submission_and_stapling_remain_explicit_after_preflight(self):
        self.environment["AURORA_NOTARY_KEYCHAIN"] = str(self.root / "private.keychain-db")
        result = self.run_preflight(verify_only=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual([call[:2] for call in calls],
                         [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])
        self.assertIn("--keychain", calls[0])
        self.assertEqual(calls[0][calls[0].index("--keychain") + 1], self.environment["AURORA_NOTARY_KEYCHAIN"])
        self.assertEqual(list(self.root.glob("aurora-notary.*")), [])


if __name__ == "__main__":
    unittest.main()
