import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NotaryCredentialTests(unittest.TestCase):
    def test_temporary_key_is_private_retired_and_not_inherited_on_success_or_failure(self):
        for status in (0, 27):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                tools = root / "tools"
                tools.mkdir()
                keychain = root / "signing.keychain-db"
                keychain.touch()
                (tools / "uname").write_text("#!/bin/bash\nprintf 'Darwin\\n'\n")
                (tools / "uname").chmod(0o755)
                tool = tools / "xcrun"
                tool.write_text(f"#!{sys.executable}\n" + '''
from pathlib import Path
import os, stat, sys
args=sys.argv[1:]
assert args[:2]==['notarytool','store-credentials']
key=Path(args[args.index('--key')+1])
assert stat.S_IMODE(key.stat().st_mode)==0o600
assert key.read_bytes()==b'synthetic-notary-key'
assert args[args.index('--keychain')+1]==os.environ['AURORA_SIGNING_KEYCHAIN']
''')
                tool.chmod(0o755)
                output = root / "result.json"
                command = root / "command.py"
                command.write_text('''
import json, os, sys
from pathlib import Path
assert all(name not in os.environ for name in ('APPLE_NOTARY_KEY_BASE64','APPLE_NOTARY_KEY_ID','APPLE_NOTARY_ISSUER_ID'))
assert not list(Path(os.environ['RUNNER_TEMP']).glob('aurora-notary.*/key.p8'))
Path(sys.argv[1]).write_text(json.dumps({'profile':os.environ['AURORA_NOTARY_PROFILE'],'keychain':os.environ['AURORA_NOTARY_KEYCHAIN']}))
raise SystemExit(int(sys.argv[2]))
''')
                environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                                   RUNNER_TEMP=str(root), GITHUB_ACTIONS="true", AURORA_SIGNING_KEYCHAIN=str(keychain),
                                   APPLE_NOTARY_KEY_BASE64=base64.b64encode(b"synthetic-notary-key").decode(),
                                   APPLE_NOTARY_KEY_ID="TESTKEY001", APPLE_NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000001")
                result = subprocess.run(["bash", str(ROOT / "Packaging/with-apple-notary.sh"), sys.executable,
                                         str(command), str(output), str(status)], env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(json.loads(output.read_text()), {"profile": "aurora-release", "keychain": str(keychain)})
                self.assertEqual(list(root.glob("aurora-notary.*")), [])
                self.assertTrue(keychain.exists())


if __name__ == "__main__":
    unittest.main()
