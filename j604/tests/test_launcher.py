"""Exercise authentication and fresh/cached private-kit preparation locally."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import os

spec = importlib.util.spec_from_file_location('launcher', Path(__file__).resolve().parents[1] / 'launcher.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LauncherTest(unittest.TestCase):
    def test_missing_login_uses_github_device_flow_and_checks_private_access(self):
        with patch.object(launcher.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(launcher, 'run') as run:
            launcher.authenticate(Path('/tools/gh'))
        self.assertEqual(run.call_args_list[0].args,
                         (Path('/tools/gh'), 'auth', 'login', '--hostname', 'github.com',
                          '--git-protocol', 'https', '--web'))
        self.assertEqual(run.call_args_list[1].args,
                         (Path('/tools/gh'), 'api', 'repos/shirty445/j604-remix', '--silent'))

    def test_existing_login_does_not_request_login_again(self):
        with patch.object(launcher.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(launcher, 'run') as run:
            launcher.authenticate(Path('/tools/gh'))
        run.assert_called_once_with(Path('/tools/gh'), 'api', 'repos/shirty445/j604-remix', '--silent')

    def make_kit(self, root):
        seed = root / 'seed'
        launcher.run('git', 'init', '-q', seed)
        (seed / 'file').write_text('base\n')
        launcher.run('git', '-C', seed, 'add', 'file')
        launcher.run('git', '-C', seed, '-c', 'user.name=Fixture', '-c', 'user.email=test@example.invalid',
                     '-c', 'commit.gpgsign=false', 'commit', '-qm', 'baseline')
        (seed / 'file').write_text('integrated\n')
        launcher.run('git', '-C', seed, 'add', 'file')
        launcher.run('git', '-C', seed, '-c', 'user.name=Fixture', '-c', 'user.email=test@example.invalid',
                     '-c', 'commit.gpgsign=false', 'commit', '-qm', 'integrated kit')
        revision = launcher.output('git', '-C', seed, 'rev-parse', 'HEAD')
        lock = {'kit': {'revision': revision, 'tree': launcher.output('git', '-C', seed, 'write-tree'),
                        'repository': 'shirty445/j604-remix'}}
        destination = launcher.kit_path(lock, root)
        destination.parent.mkdir()
        launcher.run('git', 'clone', '-q', '--shared', seed, destination)
        return lock, destination

    def test_pinned_kit_reuses_clean_cache_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, destination = self.make_kit(root)
            self.assertEqual(launcher.prepare_kit(lock, Path('/no-network-gh'), root), destination)
            self.assertEqual((destination / 'file').read_text(), 'integrated\n')
            self.assertEqual(launcher.prepare_kit(lock, Path('/no-network-gh'), root), destination)

    def test_user_edits_in_cache_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, destination = self.make_kit(root)
            (destination / 'file').write_text('local edits\n')
            with self.assertRaisesRegex(ValueError, 'local edits'):
                launcher.prepare_kit(lock, Path('/no-network-gh'), root)
            self.assertEqual((destination / 'file').read_text(), 'local edits\n')

    def test_fresh_clears_only_the_owned_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, destination = self.make_kit(root)
            with patch.object(launcher.shutil, 'which', return_value=None), \
                    patch.dict(os.environ, {'LIMA_HOME': str(root / 'lima')}):
                launcher.reset_build_state(lock, root)
            self.assertFalse(destination.exists())
            self.assertTrue((root / 'seed/file').exists())

    def test_fresh_preserves_source_edits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock, destination = self.make_kit(root)
            (destination / 'file').write_text('keep my edits\n')
            with self.assertRaisesRegex(ValueError, 'local edits'):
                launcher.reset_build_state(lock, root)
            self.assertEqual((destination / 'file').read_text(), 'keep my edits\n')

    def test_vm_ownership_requires_exact_mount_and_instance(self):
        kit = Path('/this/kit')
        instance = {'name': launcher.builder_name(kit), 'config': {'mounts': [{'location': str(kit)}]}}
        self.assertTrue(launcher.owns_builder(instance, kit))
        instance['config']['mounts'].append({'location': '/personal/files'})
        self.assertFalse(launcher.owns_builder(instance, kit))
