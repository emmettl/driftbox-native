#!/usr/bin/env python3
"""Exercise Linux registration ownership and launcher argument/environment handling."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('linux_install', ROOT / 'linux/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.make_bundle('App with spaces')
        self.data = self.root / 'xdg'
        self.mime = self.data / 'mime/packages' / (installer.APP_ID + '.xml')
        self.desktop = self.data / 'applications' / (installer.APP_ID + '.desktop')

    def make_bundle(self, name):
        bundle = self.root / name
        bundle.mkdir()
        for filename in ('Driftbox', 'driftbox-linux', 'Driftbox.png', 'manifest.json'):
            (bundle / filename).touch()
        return bundle

    def test_install_upgrade_and_old_uninstaller(self):
        installer.register(self.bundle, self.data, x11=True)
        self.assertIn(' --x11 %f', self.desktop.read_text())
        self.assertEqual(self.mime.read_text(), installer.MIME)
        replacement = self.make_bundle('New preview')
        installer.register(replacement, self.data)
        upgraded = self.desktop.read_bytes()
        with self.assertRaisesRegex(ValueError, 'different preview'):
            installer.register(self.bundle, self.data, uninstall=True)
        self.assertEqual(self.desktop.read_bytes(), upgraded)
        installer.register(replacement, self.data, uninstall=True)
        self.assertFalse(self.desktop.exists())
        self.assertFalse(self.mime.exists())
        self.assertTrue((replacement / 'Driftbox').exists())
        installer.register(replacement, self.data, uninstall=True)

    def test_foreign_registration_is_preserved(self):
        self.desktop.parent.mkdir(parents=True)
        self.desktop.write_text('[Desktop Entry]\nName=Someone else\n')
        with self.assertRaisesRegex(ValueError, 'not created'):
            installer.register(self.bundle, self.data)
        self.assertIn('Someone else', self.desktop.read_text())
        self.assertFalse(self.mime.exists())

    def test_modified_mime_is_preserved(self):
        installer.register(self.bundle, self.data)
        self.mime.write_text('foreign data')
        with self.assertRaisesRegex(ValueError, 'modified'):
            installer.register(self.bundle, self.data, uninstall=True)
        self.assertEqual(self.mime.read_text(), 'foreign data')
        self.assertTrue(self.desktop.exists())

    def test_symlink_target_is_preserved(self):
        victim = self.root / 'keep.txt'
        victim.write_text('keep')
        self.desktop.parent.mkdir(parents=True)
        self.desktop.symlink_to(victim)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            installer.register(self.bundle, self.data)
        self.assertEqual(victim.read_text(), 'keep')

    def test_incomplete_bundle_does_not_register(self):
        (self.bundle / 'manifest.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            installer.register(self.bundle, self.data)
        self.assertFalse(self.desktop.exists())
        self.assertFalse(self.mime.exists())

    def test_unsafe_desktop_paths_rejected(self):
        for character in '\n\r\t%=:':
            with self.subTest(character=character), self.assertRaises(ValueError):
                installer.entry(Path('/tmp/App' + character + 'name'), False)

    def test_desktop_spec_validation(self):
        if not shutil.which('desktop-file-validate'):
            self.skipTest('desktop-file-utils is not installed on this host')
        installer.register(self.bundle, self.data, x11=True)
        subprocess.run(['desktop-file-validate', str(self.desktop)], check=True)

    def test_desktop_launch_quotes_path_and_passes_file(self):
        try:
            from gi.repository import Gio
        except ImportError:
            self.skipTest('Python GObject bindings are not installed on this host')
        bundle = self.make_bundle('App "quoted" $dollar `tick` \\slash')
        result = self.root / 'launched.json'
        probe = bundle / 'Driftbox'
        probe.write_text('#!/usr/bin/env python3\nimport json, sys\nfrom pathlib import Path\nresult = Path(' + repr(str(result)) + ')\ntemporary = result.with_suffix(".tmp")\ntemporary.write_text(json.dumps(sys.argv[1:]))\ntemporary.replace(result)\n')
        probe.chmod(0o755)
        song = self.root / 'song with spaces $literal.driftbox'
        song.touch()
        installer.register(bundle, self.data, x11=True)
        subprocess.run(['desktop-file-validate', str(self.desktop)], check=True)
        app = Gio.DesktopAppInfo.new_from_filename(str(self.desktop))
        self.assertIsNotNone(app)
        self.assertTrue(app.launch([Gio.File.new_for_path(str(song))], None))
        deadline = time.monotonic() + 3
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(json.loads(result.read_text()), ['--x11', str(song)])

    def test_launcher_preserves_file_arguments_and_cwd(self):
        shutil.copy2(ROOT / 'linux/Driftbox', self.bundle / 'Driftbox')
        probe = self.bundle / 'driftbox-linux'
        probe.write_text('#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps(dict(args=sys.argv[1:], cwd=os.getcwd(), env=dict(os.environ))))\n')
        probe.chmod(0o755)
        env = dict(os.environ, LD_LIBRARY_PATH='/existing', GDK_BACKEND='wayland', EGL_PLATFORM='wayland')
        result = subprocess.check_output([str(self.bundle / 'Driftbox'), '--x11', 'song with spaces.driftbox', '$literal'], cwd=self.root, env=env, text=True)
        actual = json.loads(result)
        self.assertEqual(actual['args'], ['song with spaces.driftbox', '$literal'])
        self.assertEqual(actual['cwd'], str(self.root.resolve()))
        self.assertEqual(actual['env']['GDK_BACKEND'], 'x11')
        self.assertEqual(actual['env']['EGL_PLATFORM'], 'x11')
        library, inherited = actual['env']['LD_LIBRARY_PATH'].split(':')
        self.assertEqual(Path(library).resolve(), self.bundle.resolve() / 'lib')
        self.assertEqual(inherited, '/existing')
        self.assertEqual(actual['env']['SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE'], 'swift6')
        normal = json.loads(subprocess.check_output([str(self.bundle / 'Driftbox'), 'song.driftbox'], cwd=self.root, env=env, text=True))
        self.assertEqual(normal['env']['GDK_BACKEND'], 'wayland')
        self.assertEqual(normal['args'], ['song.driftbox'])


if __name__ == '__main__':
    unittest.main()
