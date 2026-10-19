#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('restore_provenance', ENGINE / 'verify-restore-image.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RestoreProvenanceTests(unittest.TestCase):
    def test_producer_rejects_compiler_or_sdk_drift_before_building(self):
        record = json.loads((ENGINE / 'RestoreImage/build-record.json').read_text())
        for swift, sdk in [('wrong compiler', record['sdk']), (record['swift'], 'wrong SDK')]:
            with self.subTest(swift=swift, sdk=sdk), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'build.sh').write_bytes((ENGINE / 'RestoreImage/build.sh').read_bytes())
                (root / 'build-record.json').write_text(json.dumps(record))
                tools = root / 'tools'
                tools.mkdir()
                (tools / 'uname').write_text(
                    '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
                (tools / 'xcrun').write_text(
                    '#!/bin/sh\ncase "$*" in "swift --version") printf "%s\\n" "$TEST_SWIFT";; '
                    '--show-sdk-version) printf "%s\\n" "$TEST_SDK";; *) exit 97;; esac\n')
                for tool in tools.iterdir():
                    tool.chmod(0o755)
                output = root / 'output'
                result = subprocess.run(['bash', str(root / 'build.sh'), str(output)],
                                        env={**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                                             'TEST_SWIFT': swift, 'TEST_SDK': sdk},
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('toolchain differs from build-record.json', result.stderr)
                self.assertFalse(output.exists())

    def test_source_and_binary_are_bound_to_build_record(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory)
            root = engine / 'RestoreImage'
            (root / 'Sources').mkdir(parents=True)
            binary = root / 'bin/omarchy-restore-image'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'synthetic executable')
            paths = [root / 'Package.swift', root / 'build.sh', root / 'Sources/main.swift']
            for path in paths:
                path.write_text('synthetic source')
            record = {
                'schema': 1,
                'reference_repository': 'https://github.com/erykwieliczko/macos-firmware-extract',
                'reference_commit': '71b413af680edec1808a709cb7addfbde5c21cfc',
                'target': 'arm64-apple-macosx14.0',
                'reproducibility': 'two-identical-clean-builds-same-host-pinned-toolchain',
                'swift': 'recorded compiler', 'sdk': 'recorded SDK',
                'sources': [{'path': str(p.relative_to(root)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                            for p in paths],
                'binary_size': binary.stat().st_size,
                'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            }
            (root / 'build-record.json').write_text(json.dumps(record))
            MODULE.verify(engine)
            paths[-1].write_text('changed')
            with self.assertRaisesRegex(ValueError, 'source differs'):
                MODULE.verify(engine)
            paths[-1].write_text('synthetic source')
            binary.write_bytes(b'changed executable')
            with self.assertRaisesRegex(ValueError, 'differs from the Swift restore-image build'):
                MODULE.verify(engine)
            binary.write_bytes(b'synthetic executable')
            # An unsigned app's copy must be the same bytes; a link is not a copy.
            copy = engine / 'Helpers/omarchy-restore-image'
            copy.parent.mkdir()
            copy.write_bytes(b'synthetic executable')
            MODULE.verify_binary(engine, copy)
            copy.write_bytes(b'synthetic executable, signed')
            with self.assertRaisesRegex(ValueError, 'differs from the Swift restore-image build'):
                MODULE.verify_binary(engine, copy)
            copy.unlink()
            copy.symlink_to(binary)
            with self.assertRaisesRegex(ValueError, 'differs from the Swift restore-image build'):
                MODULE.verify_binary(engine, copy)

    def test_production_helper_has_checked_in_source(self):
        # This checks the actual source/build identity independently of the archive lock.
        MODULE.verify(ENGINE)


if __name__ == '__main__':
    unittest.main()
