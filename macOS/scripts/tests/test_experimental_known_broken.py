"""The experimental hardware path keeps refusing what is known to fail: its
Swift table must name exactly the boards supported-models.json keeps out of
Stage 1 qualification, with the same reasons."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / 'Sources/AuroraAppleInstaller/NativeExperimentalHardware.swift'
MANIFEST = ROOT / 'scripts/supported-models.json'


class KnownBrokenTests(unittest.TestCase):
    def test_swift_table_matches_the_manifest(self):
        source = SWIFT.read_text()
        table = source[source.index('static let knownBrokenBoards'):source.index('static let knownBrokenChips')]
        swift = {key: json.loads('"%s"' % value) for key, value in
                 re.findall(r'"(apple,j[0-9]+[a-z]*)":\s*"((?:[^"\\]|\\.)*)"', table)}
        manifest = json.loads(MANIFEST.read_text()).get('stage1_unqualified', {})
        self.assertEqual(swift, manifest)


if __name__ == '__main__':
    unittest.main()
