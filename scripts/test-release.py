"""Exercise release validation and failure handling without signing or uploading anything."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

INFO = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "CFBundleIdentifier": "app.driftbox.native", "LSMinimumSystemVersion": "26.0"}
VERSION = {"version": "0.1.0", "build": "1", "commit": "0" * 40}


def bundle(app, info=INFO):
    """An app with its extension, as far as the release reads them."""
    for plist in (app / "Contents/Info.plist", app / release.EXTENSION / "Contents/Info.plist"):
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(info))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_the_version_file_is_checked(self):
        self.assertEqual(release.read_version("DRIFTBOX_VERSION=0.1.0\nDRIFTBOX_BUILD=1\n"), ("0.1.0", "1"))
        for text in ["DRIFTBOX_VERSION=0.1\nDRIFTBOX_BUILD=1", "DRIFTBOX_VERSION=../0.1.0\nDRIFTBOX_BUILD=1",
                     "DRIFTBOX_VERSION=0.1.0\nDRIFTBOX_BUILD=0", "DRIFTBOX_VERSION=0.1.0"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                release.read_version(text)
        # The one the repository has.
        release.read_version((Path(__file__).parent / "version.env").read_text())

    def test_the_windows_programs_carry_the_version(self):
        """The resources Windows' programs link, which signing holds them to, are the version file's:
        scripts/windows-resources.mjs writes them, and the release workflow checks it again."""
        version, build = release.read_version((release.ROOT / "scripts/version.env").read_text())
        parts = ",".join(version.split(".") + [build])
        for name in ["Driftbox", "DriftboxVST3Scan"]:
            with self.subTest(program=name):
                script = (release.ROOT / "windows" / f"{name}.rc").read_text()
                self.assertIn(f"FILEVERSION {parts}\n", script)
                self.assertIn(f"PRODUCTVERSION {parts}\n", script)
                self.assertIn(f'VALUE "ProductVersion", "{version}"', script)
                self.assertIn('VALUE "ProductName", "Driftbox"', script)
                self.assertIn(f'VALUE "OriginalFilename", "{name}.exe"', script)

    def test_metadata_rejects_unsafe_names_and_wrong_baseline(self):
        self.assertEqual(release.metadata(INFO)["version"], "0.1.0")
        for key, value in [("CFBundleShortVersionString", "../0.1"), ("CFBundleVersion", "0"),
                           ("LSMinimumSystemVersion", "15.0"), ("CFBundleIdentifier", "")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.metadata({**INFO, key: value})

    def test_only_an_unambiguous_developer_id_is_accepted(self):
        fingerprint = "A" * 40
        with self.assertRaises(ValueError):
            release.choose_identity(f'1) {fingerprint} "Apple Development: Example"', None)
        identity = f'1) {fingerprint} "Developer ID Application: Example (TEAM)"'
        self.assertEqual(release.choose_identity(identity, None), fingerprint)
        duplicate = identity + '\n2) ' + "B" * 40 + ' "Developer ID Application: Other (OTHER)"'
        with self.assertRaises(ValueError):
            release.choose_identity(duplicate, None)
        self.assertEqual(release.choose_identity(duplicate, fingerprint), fingerprint)

    def test_the_extension_is_signed_before_the_app_around_it(self):
        app = Path("/tmp/Driftbox.app")
        first, second = release.signing_order(app, "A" * 40)
        self.assertEqual(first[-1], str(app / release.EXTENSION))
        self.assertTrue(first[first.index("--entitlements") + 1].endswith("extension.entitlements"))
        self.assertEqual(second[-1], str(app))
        self.assertTrue(second[second.index("--entitlements") + 1].endswith("app.entitlements"))
        for command in (first, second):
            self.assertIn("runtime", command)
            self.assertIn("--timestamp", command)

    def test_the_entitlements_are_the_ones_described(self):
        scripts = Path(__file__).parent
        extension = plistlib.loads((scripts / "extension.entitlements").read_bytes())
        self.assertTrue(extension["com.apple.security.app-sandbox"])
        app = plistlib.loads((scripts / "app.entitlements").read_bytes())
        self.assertEqual(app, {"com.apple.security.cs.disable-library-validation": True,
                               "com.apple.security.device.audio-input": True})

    def test_checksum_can_be_verified_in_the_download_directory(self):
        archive = self.root / "Driftbox-0.1.0-macos-arm64.zip"
        archive.write_bytes(b"fixture")
        release.write_checksums(archive, {"version": "0.1.0", "notarized": True})
        manifest = json.loads(archive.with_suffix(".json").read_text())
        self.assertEqual(archive.with_suffix(".zip.sha256").read_text(),
                         manifest["sha256"] + "  " + archive.name + "\n")
        self.assertTrue(manifest["notarized"])

    def pipeline(self, notary="Accepted", gatekeeper_accepts=True, info=INFO):
        calls = []

        def command(*arguments, capture=False, env=None):
            calls.append(arguments)
            if arguments[0] == "lipo":
                return "arm64"
            if arguments[:2] == ("git", "status"):
                return ""
            if arguments[:3] == ("xcrun", "notarytool", "submit"):
                return json.dumps({"id": "test-submission", "status": notary})
            if arguments[0] == "spctl" and not gatekeeper_accepts:
                raise subprocess.CalledProcessError(1, arguments)
            if arguments[0] == "ditto" and arguments[1] != "-c":
                bundle(Path(arguments[2]), info)
            elif arguments[0] == "ditto":
                Path(arguments[-1]).write_bytes(b"test archive")
            return ""

        args = argparse.Namespace(command="prepare", identity="A" * 40, notary_profile="test", skip_tests=False)
        with patch.object(release, "ROOT", self.root), patch.object(release, "run", command), \
                patch.object(release, "preflight", return_value=(args.identity, dict(VERSION))):
            release.release(args)
        return calls

    def test_rejected_notarization_never_produces_a_release_archive(self):
        calls = []
        with self.assertRaisesRegex(ValueError, "Notarization was not accepted"):
            calls = self.pipeline(notary="Invalid")
        self.assertFalse(list((self.root / "dist").glob("Driftbox-*.zip")))
        self.assertEqual(json.loads((self.root / "dist/notarization.json").read_text())["status"], "Invalid")

    def test_a_bundle_off_the_release_version_is_never_signed(self):
        with self.assertRaisesRegex(ValueError, "version and build"):
            self.pipeline(info={**INFO, "CFBundleVersion": "2"})
        self.assertFalse((self.root / "dist/notarization.json").exists())

    def test_gatekeeper_failure_never_creates_the_release_archive(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.pipeline(gatekeeper_accepts=False)
        self.assertFalse((self.root / "dist/Driftbox-0.1.0-macos-arm64.zip").exists())

    def test_release_archive_is_created_only_after_stapling_and_gatekeeper_acceptance(self):
        calls = self.pipeline()
        archive = self.root / "dist/Driftbox-0.1.0-macos-arm64.zip"
        self.assertTrue(archive.exists())
        names = [" ".join(call[:3]) for call in calls]
        # Tested strictly, built, signed inside out, notarised, stapled, then archived.
        self.assertIn("swift test", names)
        signs = [call for call in calls if call[:2] == ("codesign", "--force")]
        self.assertEqual([call[-1] for call in signs],
                         [str(self.root / "dist/Driftbox.app" / release.EXTENSION), str(self.root / "dist/Driftbox.app")])
        self.assertLess(names.index("xcrun notarytool submit"), names.index("xcrun stapler staple"))
        self.assertLess(names.index("xcrun stapler validate"), len(names) - 1)
        self.assertEqual(calls[-1][0], "ditto")
        manifest = json.loads(archive.with_suffix(".json").read_text())
        self.assertTrue(manifest["notarized"] and manifest["tested"])
        self.assertEqual(manifest["bundleIdentifier"], "app.driftbox.native")
        subprocess.run(["shasum", "-a", "256", "-c", archive.name + ".sha256"],
                       cwd=archive.parent, check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
