#!/usr/bin/env python3
"""Check preview version ordering and rejection of damaged bundle inputs."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('linux_deb', Path(__file__).with_name('linux-deb.py'))
deb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deb)


class DebTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name)
        (self.bundle / 'driftbox-linux').write_bytes(b'trusted fixture')
        self.manifest = {
            'format': 1, 'version': '0.1.0', 'build': '1', 'architecture': 'arm64',
            'buildOS': {'ID': 'ubuntu', 'VERSION_ID': '24.04'},
            'source': {'revision': 'a' * 40, 'dirty': False},
            'files': {'driftbox-linux': deb.digest(self.bundle / 'driftbox-linux')},
        }
        self.save()

    def save(self):
        (self.bundle / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_verified_bundle_and_tampering(self):
        self.assertEqual(deb.verify_bundle(self.bundle), self.manifest)
        (self.bundle / 'driftbox-linux').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum failed'):
            deb.verify_bundle(self.bundle)

    def test_unlisted_files_and_symlinks_rejected(self):
        extra = self.bundle / 'unlisted'
        extra.touch()
        with self.assertRaisesRegex(ValueError, 'inventory'):
            deb.verify_bundle(self.bundle)
        extra.unlink()
        extra.symlink_to(self.bundle / 'driftbox-linux')
        with self.assertRaisesRegex(ValueError, 'regular files'):
            deb.verify_bundle(self.bundle)

    def test_wrong_runtime_baseline_rejected(self):
        self.manifest['buildOS']['VERSION_ID'] = '22.04'
        self.save()
        with self.assertRaisesRegex(ValueError, '24.04'):
            deb.verify_bundle(self.bundle)

    def test_preview_requires_provenance(self):
        for epoch in (None, '', '-1', '12\nDepends: injected'):
            with self.subTest(epoch=epoch), self.assertRaises(ValueError):
                deb.preview_version(self.manifest, epoch)
        for field, value in [('revision', None), ('revision', 'not a commit'), ('dirty', None)]:
            manifest = copy.deepcopy(self.manifest)
            manifest['source'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                deb.preview_version(manifest, '1780000000')

    def test_version_is_safe_for_control_and_artifact_name(self):
        for field, value in [('version', '../0.1'), ('build', '1\nDepends: injected')]:
            manifest = copy.deepcopy(self.manifest)
            manifest[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                deb.preview_version(manifest, '1780000000')
        self.manifest['source']['dirty'] = True
        self.assertTrue(deb.preview_version(self.manifest, '1780000000').endswith('.dirty'))

    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg version comparisons run on Linux CI')
    def test_newer_previews_upgrade_and_release_supersedes_preview(self):
        old = deb.preview_version(self.manifest, '1780000000')
        newer = deb.preview_version(self.manifest, '1780000001')
        subprocess.run(['dpkg', '--compare-versions', old, 'lt', newer], check=True)
        subprocess.run(['dpkg', '--compare-versions', newer, 'lt', '0.1.0'], check=True)
        self.manifest['build'] = '2'
        subprocess.run(['dpkg', '--compare-versions', newer, 'lt',
                        deb.preview_version(self.manifest, '1780000001')], check=True)


if __name__ == '__main__':
    unittest.main()
