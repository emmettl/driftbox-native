"""Exercise the Android release's validation and failure handling without signing anything real."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("android_release", Path(__file__).with_name("android-release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

INFO = {"version": "0.1.0", "build": "1", "commit": "0" * 40}
BADGING = ("package: name='app.driftbox' versionCode='1' versionName='0.1.0' platformBuildVersionName='16'\n"
           "minSdkVersion:'29'\ntargetSdkVersion:'37'\n")


class AndroidReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_the_version_file_is_checked(self):
        self.assertEqual(release.read_version("DRIFTBOX_VERSION=0.1.0\nDRIFTBOX_BUILD=1\n"), ("0.1.0", "1"))
        for text in ["DRIFTBOX_VERSION=0.1\nDRIFTBOX_BUILD=1", "DRIFTBOX_VERSION=0.1.0\nDRIFTBOX_BUILD=0",
                     "DRIFTBOX_VERSION=0.1.0\nDRIFTBOX_BUILD=2100000001"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                release.read_version(text)
        release.read_version((Path(__file__).parent / "version.env").read_text())

    def test_the_apk_says_what_it_is(self):
        self.assertEqual(release.built_version(BADGING),
                         {"applicationId": "app.driftbox", "build": "1", "version": "0.1.0", "minimumSdk": 29,
                          "targetSdk": 37})
        with self.assertRaises(ValueError):
            release.built_version("nothing useful")

    def test_the_password_never_goes_on_a_command_line(self):
        apk, bundle = release.signing(Path("/keys/upload.jks"), "upload")
        self.assertIn(f"env:{release.PASSWORD}", apk)
        self.assertEqual(apk[apk.index("--v4-signing-enabled") + 1], "false")
        self.assertEqual(bundle[bundle.index("-storepass:env") + 1], release.PASSWORD)
        self.assertIn("SHA256withRSA", bundle)

    def test_a_tool_has_its_platforms_name(self):
        folder = Path("/sdk/build-tools/37.0.0")
        with patch.object(release.os, "name", "posix"):
            self.assertEqual(release.tool(folder, "apksigner"), str(folder / "apksigner"))
        with patch.object(release.os, "name", "nt"):
            self.assertEqual(release.tool(folder, "apksigner"), str(folder / "apksigner.bat"))
            self.assertEqual(release.tool(folder, "aapt2"), str(folder / "aapt2.exe"))

    def pipeline(self, badging=BADGING, verify_fails=False, manifest="E: application"):
        built = self.root / "out/app"
        built.mkdir(parents=True)
        (built / "aligned.apk").write_bytes(b"apk")
        (built / "driftbox.aab").write_bytes(b"aab")
        calls = []

        def command(*arguments, capture=False, env=None):
            calls.append((arguments, env))
            if arguments[:2] == ("git", "status"):
                return ""
            if arguments[1:3] == ("scripts/android-app.sh", "bundle"):
                return f"  driftbox.apk: ok (1 KB)\nbuilt {built}/driftbox.apk\n"
            if arguments[1:3] == ("dump", "badging"):
                return badging
            if arguments[1:3] == ("dump", "xmltree"):
                return manifest
            if arguments[1] == "sign":
                Path(arguments[arguments.index("--out") + 1]).write_bytes(b"signed apk")
            if arguments[0] == "jarsigner" and arguments[1] == "-verify":
                return "jar is unsigned." if verify_fails else "jar verified.\n\nWarning: self-signed"
            return ""

        args = argparse.Namespace(command="prepare", keystore="k", alias="upload", skip_tests=False)
        with patch.object(release, "ROOT", self.root), patch.object(release, "run", command), \
                patch.object(release, "tools", return_value=Path("/sdk/build-tools/37.0.0")), \
                patch.object(release, "bundletool", return_value="/sdk/bundletool.jar"), \
                patch.object(release, "preflight", return_value=(Path("/keys/upload.jks"), dict(INFO))), \
                patch.dict(release.os.environ, {release.PASSWORD: "secret"}):
            release.release(args)
        return calls

    def test_a_release_is_tested_signed_and_verified(self):
        calls = self.pipeline()
        names = [" ".join(call[0][:3]) for call in calls]
        self.assertIn("swift test", names)
        self.assertIn("java -jar /sdk/bundletool.jar", names, "the bundle validated")
        self.assertLess(names.index("sh scripts/android-app.sh bundle"), names.index("/sdk/build-tools/37.0.0/apksigner sign --ks"))
        for arguments, env in calls:
            self.assertNotIn("secret", " ".join(arguments), "the password is only ever in the environment")
            if arguments[0] == "jarsigner" and arguments[1] != "-verify":
                self.assertEqual(env[release.PASSWORD], "secret")
        manifest = json.loads((self.root / "dist/Driftbox-0.1.0-android.json").read_text())
        self.assertEqual(set(manifest["sha256"]), {"Driftbox-0.1.0-android.apk", "Driftbox-0.1.0-android.aab"})
        self.assertEqual(manifest["applicationId"], "app.driftbox")
        self.assertTrue(manifest["tested"])
        subprocess.run(["shasum", "-a", "256", "-c", "Driftbox-0.1.0-android.apk.sha256"],
                       cwd=self.root / "dist", check=True, capture_output=True)

    def test_an_apk_off_the_release_version_is_never_signed(self):
        with self.assertRaisesRegex(ValueError, "version and build"):
            self.pipeline(badging=BADGING.replace("versionCode='1'", "versionCode='2'"))
        self.assertFalse((self.root / "dist/Driftbox-0.1.0-android.apk").exists())

    def test_an_apk_for_an_old_android_is_never_signed(self):
        with self.assertRaisesRegex(ValueError, "older than Google Play takes"):
            self.pipeline(badging=BADGING.replace("targetSdkVersion:'37'", "targetSdkVersion:'35'"))
        self.assertFalse((self.root / "dist/Driftbox-0.1.0-android.apk").exists())

    def test_an_apk_with_the_checks_is_never_signed(self):
        with self.assertRaisesRegex(ValueError, "has the checks in it"):
            self.pipeline(manifest='E: service\n  A: android:name="app.driftbox.LoopbackService"')
        self.assertFalse((self.root / "dist/Driftbox-0.1.0-android.apk").exists())

    def test_a_bundle_that_does_not_verify_leaves_no_manifest(self):
        with self.assertRaisesRegex(ValueError, "did not verify"):
            self.pipeline(verify_fails=True)
        self.assertFalse((self.root / "dist/Driftbox-0.1.0-android.json").exists())


if __name__ == "__main__":
    unittest.main()
