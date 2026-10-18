import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('prepare_engine', ROOT / 'prepare-engine.py')
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class EnginePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = b'authenticated runtime base'
        self.base_identity = {'base_sha256': digest(self.base), 'base_size_bytes': len(self.base),
                              'base_url': 'https://example.invalid/runtime.tar.gz'}
        self.fetches = 0

    def fetch(self, url, destination, size):
        self.assertEqual(url, self.base_identity['base_url'])
        self.assertEqual(size, len(self.base))
        self.fetches += 1
        destination.write_bytes(self.base)

    def test_missing_base_is_downloaded_and_verified_cache_is_reused(self):
        cache = self.root / 'cache'
        first = PREPARE.cached_base(cache, self.base_identity, self.fetch)
        self.assertEqual(first.read_bytes(), self.base)
        self.assertEqual(PREPARE.cached_base(cache, self.base_identity, self.fetch), first)
        self.assertEqual(self.fetches, 1)

    def test_corrupt_cache_is_replaced_only_by_authenticated_bytes(self):
        cache = self.root / 'cache'
        cache.mkdir()
        (cache / digest(self.base)).write_bytes(b'bad cached bytes')
        result = PREPARE.cached_base(cache, self.base_identity, self.fetch)
        self.assertEqual(result.read_bytes(), self.base)
        self.assertEqual(self.fetches, 1)

    def test_bad_download_is_never_published_to_cache(self):
        def bad_fetch(url, destination, size):
            destination.write_bytes(b'bad download')
        with self.assertRaisesRegex(ValueError, 'size or digest mismatch'):
            PREPARE.cached_base(self.root / 'cache', self.base_identity, bad_fetch)
        self.assertFalse((self.root / 'cache' / digest(self.base)).exists())

    def test_missing_primary_uses_identically_pinned_mirror(self):
        identity = dict(self.base_identity, base_mirror_urls=['https://mirror.invalid/base.tar.gz'])
        calls = []
        def fetch(url, destination, size):
            calls.append(url)
            if len(calls) == 1:
                destination.write_bytes(b'interrupted download')
                raise OSError('primary unavailable')
            destination.write_bytes(self.base)
        output = PREPARE.cached_base(self.root / 'cache', identity, fetch)
        self.assertEqual(output.read_bytes(), self.base)
        self.assertEqual(calls, [identity['base_url'], *identity['base_mirror_urls']])

    def test_mirror_cannot_replace_the_authenticated_runtime(self):
        identity = dict(self.base_identity, base_mirror_urls=['https://mirror.invalid/base.tar.gz'])
        def fetch(url, destination, size):
            destination.write_bytes(b'wrong runtime')
        with self.assertRaisesRegex(ValueError, 'size or digest mismatch'):
            PREPARE.cached_base(self.root / 'cache', identity, fetch)
        self.assertFalse((self.root / 'cache' / digest(self.base)).exists())

    def test_cached_symlink_does_not_admit_an_unverified_target(self):
        cache = self.root / 'cache'
        cache.mkdir()
        unrelated = self.root / 'unrelated'
        unrelated.write_bytes(b'keep this')
        (cache / digest(self.base)).symlink_to(unrelated)
        PREPARE.cached_base(cache, self.base_identity, self.fetch)
        self.assertEqual(unrelated.read_bytes(), b'keep this')
        self.assertFalse((cache / digest(self.base)).is_symlink())

    def archive(self, mode=0o644):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            member = tarfile.TarInfo('./main.py')
            member.mode = mode
            member.size = 5
            archive.addfile(member, io.BytesIO(b'hello'))
        return output.getvalue()

    def reproduce(self, data, second=None, existing=None):
        calls = []
        def build(checkout, base, output):
            calls.append(output)
            output.write_bytes(second if second is not None and len(calls) == 2 else data)
        identity = {'sha256': digest(data), 'size_bytes': len(data)}
        output = self.root / 'engine.tar.gz'
        if existing is not None:
            output.write_bytes(existing)
        return PREPARE.reproduce(None, None, output, identity, build), calls

    def test_two_matching_repacks_are_required_before_publication(self):
        data = self.archive()
        output, calls = self.reproduce(data)
        self.assertEqual(len(calls), 2)
        self.assertEqual(output.read_bytes(), data)

    def test_different_repacks_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'size or digest mismatch'):
            self.reproduce(self.archive(), second=b'different')
        self.assertFalse((self.root / 'engine.tar.gz').exists())

    def test_unsafe_modes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'archive modes'):
            self.reproduce(self.archive(0o666))
        self.assertFalse((self.root / 'engine.tar.gz').exists())

    def test_wrong_existing_archive_is_preserved_and_rejected(self):
        with self.assertRaisesRegex(ValueError, 'size or digest mismatch'):
            self.reproduce(self.archive(), existing=b'preserve existing artifact')
        self.assertEqual((self.root / 'engine.tar.gz').read_bytes(), b'preserve existing artifact')


if __name__ == '__main__':
    unittest.main()
