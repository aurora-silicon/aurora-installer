# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verify_engine_macho', ENGINE / 'verify-engine-macho.py')
MACHO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MACHO)


def archive(path, members):
    with tarfile.open(path, mode='w:gz') as output:
        for name, data in members.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            output.addfile(member, io.BytesIO(data))


class EngineNativeCodeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = b'\xcf\xfa\xed\xfe signed runtime'
        self.pinned = {'Frameworks/Python': hashlib.sha256(self.runtime).hexdigest()}

    def test_every_mach_o_header_is_recognised(self):
        for magic in MACHO.MACHO_MAGIC:
            self.assertTrue(MACHO.is_macho(magic + b'rest'))
        for data in (b'#!/bin/sh', b'PK\x03\x04', b'\x7fELF', b''):
            self.assertFalse(MACHO.is_macho(data))

    def test_only_the_pinned_runtime_may_be_native_code(self):
        path = self.root / 'engine.tar.gz'
        archive(path, {'./main.py': b'print()', './Frameworks/Python': self.runtime})
        self.assertEqual(MACHO.verify(path, self.pinned), [])
        archive(path, {'./Frameworks/Python': self.runtime,
                       './bin/omarchy-restore-image': b'\xcf\xfa\xed\xfe ad hoc'})
        self.assertEqual(MACHO.verify(path, self.pinned),
                         ['bin/omarchy-restore-image: a Mach-O that is not part of the authenticated runtime'])
        archive(path, {'./main.py': b'print()'})
        self.assertEqual(MACHO.verify(path, self.pinned),
                         ['Frameworks/Python: the authenticated runtime file is missing'])
        self.assertEqual(MACHO.verify(path, self.pinned, complete=False), [])

    def test_the_command_fails_for_foreign_native_code(self):
        path = self.root / 'engine.tar.gz'
        archive(path, {'./tool': b'\xca\xfe\xba\xbe universal'})
        self.assertEqual(MACHO.main([str(path)]), 1)
        self.assertEqual(MACHO.main([]), 64)

    def test_the_lock_and_overlay_carry_no_engine_tools(self):
        lock = json.loads((ENGINE / 'source-lock.json').read_text())
        self.assertFalse([item for item in lock['downstream_overlay']['files']
                          if item['destination'].startswith('bin/')])
        self.assertFalse((ENGINE / 'overlay/bin').exists())
        runtime = json.loads((ENGINE / 'runtime-macho.json').read_text())
        self.assertEqual(runtime['base_sha256'], lock['incremental_build']['base_sha256'])

    @unittest.skipUnless(shutil.which('codesign') and shutil.which('lipo') and shutil.which('cc'),
                         'needs codesign, lipo and cc (macOS)')
    def test_signatures_refuse_pinned_code_that_notarization_would_refuse(self):
        # An ad hoc signature (the .50 decoder's) has no Developer ID, no
        # timestamp and no hardened runtime, whatever the byte pin says.
        (self.root / 'tool.c').write_text('int main(void) { return 0; }\n')
        tool = self.root / 'tool'
        subprocess.run(['cc', '-arch', 'arm64', '-o', str(tool), str(self.root / 'tool.c')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(tool)], check=True, capture_output=True)
        data = tool.read_bytes()
        path = self.root / 'engine.tar.gz'
        archive(path, {'./bin/tool': data})
        findings = MACHO.verify(path, {'bin/tool': hashlib.sha256(data).hexdigest()}, signatures=True)
        self.assertIn('bin/tool (arm64): not signed with a Developer ID Application certificate', findings)
        self.assertIn('bin/tool (arm64): signature has no secure timestamp', findings)
        self.assertIn('bin/tool (arm64): hardened runtime is not enabled', findings)

    def test_the_pinned_engine_carries_only_its_runtime(self):
        lock = json.loads((ENGINE / 'source-lock.json').read_text())['validation_artifact']
        engine = ENGINE / 'artifacts' / lock['filename']
        if not engine.is_file():
            self.skipTest('the pinned engine is not reproduced in Engine/artifacts')
        self.assertEqual(MACHO.verify(engine), [])
        if shutil.which('codesign') and shutil.which('lipo'):
            self.assertEqual(MACHO.verify(engine, signatures=True), [])

    @unittest.skipUnless(shutil.which('codesign'), 'needs codesign (macOS)')
    def test_the_decoder_requirement_grammar_matches_a_real_developer_id_signature(self):
        # The runtime's interpreter is Developer ID signed; the engine's
        # decoder requirement form (TN3127) must accept exactly such code.
        lock = json.loads((ENGINE / 'source-lock.json').read_text())['validation_artifact']
        engine = ENGINE / 'artifacts' / lock['filename']
        if not engine.is_file():
            self.skipTest('the pinned engine is not reproduced in Engine/artifacts')
        sys.path.insert(0, str(ENGINE / 'overlay/src'))
        self.addCleanup(sys.path.remove, str(ENGINE / 'overlay/src'))
        import omarchy_apple_aea
        root = MACHO.extracted(engine, self.root)
        python = root / 'Frameworks/Python.framework/Versions/3.13/bin/python3.13'
        details = subprocess.run(['codesign', '--display', '--verbose=4', str(python)],
                                 capture_output=True, text=True).stderr
        identifier = next(line.split('=', 1)[1] for line in details.splitlines() if line.startswith('Identifier='))
        team = next(line.split('=', 1)[1] for line in details.splitlines() if line.startswith('TeamIdentifier='))
        requirement = (f'anchor apple generic and identifier "{identifier}" '
                       'and certificate 1[field.1.2.840.113635.100.6.2.6] '
                       'and certificate leaf[field.1.2.840.113635.100.6.1.13] '
                       f'and certificate leaf[subject.OU] = "{team}"')
        self.assertTrue(omarchy_apple_aea.REQUIREMENT.fullmatch(requirement))
        self.assertEqual(subprocess.run(['codesign', '--verify', '--strict', '-R=' + requirement, str(python)],
                                        capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
