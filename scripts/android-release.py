"""Prepare an Android release of Driftbox on this machine: an APK and an App Bundle, signed.

The Android counterpart of scripts/release.py, and like it never tags, uploads or publishes: what it
makes is left in dist/ for review. Both are signed with the upload key, which is yours, kept out of
the repository: a keystore at DRIFTBOX_ANDROID_KEYSTORE holding it under DRIFTBOX_ANDROID_KEY_ALIAS,
its password in DRIFTBOX_ANDROID_KEYSTORE_PASS or asked for, and handed to the signers through their
environment, never their command lines. The APK is for installing directly and for stores that take
one; the bundle is what Google Play takes, and signs again with the key Play keeps.
"""

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MINIMUM_SDK = 29
# The oldest Android a release may be built for: Google Play's floor for new apps and updates, which
# rises every August. scripts/android-app.sh names what it is built for.
MINIMUM_TARGET_SDK = 36
PASSWORD = "DRIFTBOX_ANDROID_KEYSTORE_PASS"


def run(*arguments, capture=False, env=None):
    return subprocess.run(arguments, cwd=ROOT, check=True, text=True, env=env,
                          stdout=subprocess.PIPE if capture else None).stdout


def read_version(text):
    """The version and build scripts/version.env gives, checked: the build is the version code."""
    values = dict(re.findall(r"^(DRIFTBOX_\w+)=(\S+)$", text, re.MULTILINE))
    version, build = values.get("DRIFTBOX_VERSION", ""), values.get("DRIFTBOX_BUILD", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Use a numeric major.minor.patch DRIFTBOX_VERSION in scripts/version.env.")
    if not re.fullmatch(r"[1-9]\d*", build) or int(build) > 2100000000:
        raise ValueError("Use a positive whole DRIFTBOX_BUILD, under Google Play's limit, in scripts/version.env.")
    return version, build


def built_version(badging):
    """What `aapt2 dump badging` says the APK is."""
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    sdk = re.search(r"minSdkVersion:'(\d+)'", badging)
    target = re.search(r"targetSdkVersion:'(\d+)'", badging)
    if not package or not sdk or not target:
        raise ValueError("The APK does not say what it is.")
    return {"applicationId": package[1], "build": package[2], "version": package[3], "minimumSdk": int(sdk[1]),
            "targetSdk": int(target[1])}


def signing(keystore, alias):
    """How both are signed with the upload key: the APK by apksigner, the bundle by jarsigner, as
    Google Play asks, each reading the password from the environment."""
    # No v4 signature: its .idsig file is for streaming an install over adb, not for a release.
    apk = ["--ks", str(keystore), "--ks-key-alias", alias, "--ks-pass", f"env:{PASSWORD}", "--v4-signing-enabled",
           "false"]
    bundle = ["-keystore", str(keystore), "-storepass:env", PASSWORD, "-sigalg", "SHA256withRSA",
              "-digestalg", "SHA-256"]
    return apk, bundle


def write_checksums(files, manifest, into):
    """A .sha256 for each, and one manifest for both, named for the first."""
    sums = {}
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n")
        sums[path.name] = digest
    into.write_text(json.dumps({**manifest, "sha256": sums}, indent=2) + "\n")


def tool(folder, name):
    """One of the build-tools, by the name it has on this machine: a script on Windows is a .bat."""
    if os.name == "nt":
        name += ".bat" if name in ("apksigner", "d8") else ".exe"
    return str(folder / name)


def tools():
    """The SDK's build-tools, found as android-env.sh finds the SDK."""
    home = os.environ.get("ANDROID_HOME") or str(Path.home() / "Library/Android/sdk")
    found = sorted(Path(home, "build-tools").glob("*"), key=lambda p: [int(x) for x in re.findall(r"\d+", p.name)])
    if not found:
        raise ValueError("No Android SDK build-tools found: set ANDROID_HOME.")
    return found[-1]


def bundletool():
    """Google's bundletool, found as android-app.sh finds it."""
    if os.environ.get("DRIFTBOX_BUNDLETOOL"):
        return os.environ["DRIFTBOX_BUNDLETOOL"]
    found = sorted(tools().parent.parent.parent.glob("bundletool/bundletool-all-*.jar"))
    if not found:
        raise ValueError("No bundletool found: set DRIFTBOX_BUNDLETOOL.")
    return str(found[-1])


def preflight(args):
    keystore = Path(args.keystore or "")
    if not args.keystore or not keystore.is_file():
        raise ValueError("Give the upload keystore with --keystore or DRIFTBOX_ANDROID_KEYSTORE.")
    if not args.alias:
        raise ValueError("Give the key's alias with --alias or DRIFTBOX_ANDROID_KEY_ALIAS.")
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("Commit or set aside working-tree changes before preparing a release.")
    version, build = read_version((ROOT / "scripts/version.env").read_text())
    return keystore, {"version": version, "build": build,
                      "commit": run("git", "rev-parse", "HEAD", capture=True).strip()}


def release(args):
    keystore, info = preflight(args)
    if args.command == "check":
        print(f"Android release {info['version']} ({info['build']}): keystore and version in order. "
              "The password is tried when signing.")
        return
    stem = f"Driftbox-{info['version']}-android"
    dist = ROOT / "dist"
    apk, aab = dist / f"{stem}.apk", dist / f"{stem}.aab"
    for made in (apk, aab):
        if made.exists():
            raise ValueError(f"{made.name} already exists. Move it aside before retrying.")
    env = dict(os.environ)
    if PASSWORD not in env:
        env[PASSWORD] = getpass.getpass(f"Password for {keystore.name}: ")
    if not args.skip_tests:
        run("swift", "format", "lint", "--strict", "-r", "Sources", "Tests", "Package.swift")
        run("sh", "scripts/check-constrained.sh")
        run("swift", "test", env={**os.environ, "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": "swift6"})
    output = run("sh", "scripts/android-app.sh", "bundle", capture=True)
    print(output, end="")
    built = Path(re.search(r"^built (.+)/driftbox\.apk$", output, re.MULTILINE)[1])
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("The build changed the source checkout; review and commit the changes before releasing.")

    build_tools = tools()
    badging = run(tool(build_tools, "aapt2"), "dump", "badging", str(built / "aligned.apk"), capture=True)
    carried = built_version(badging)
    if (carried["version"], carried["build"]) != (info["version"], info["build"]):
        raise ValueError("The APK does not carry the release's version and build.")
    if carried["minimumSdk"] != MINIMUM_SDK:
        raise ValueError("Update the release requirements before changing the minimum Android version.")
    if carried["targetSdk"] < MINIMUM_TARGET_SDK:
        raise ValueError(f"The APK targets Android {carried['targetSdk']}, older than Google Play takes.")
    # A release is built without the checks, whose MIDI device every other app would list.
    manifest = run(tool(build_tools, "aapt2"), "dump", "xmltree", "--file", "AndroidManifest.xml",
                   str(built / "aligned.apk"), capture=True)
    if "LoopbackService" in manifest:
        raise ValueError("The APK has the checks in it: build it with android-app.sh bundle.")

    dist.mkdir(exist_ok=True)
    apk_signing, bundle_signing = signing(keystore, args.alias)
    run(tool(build_tools, "apksigner"), "sign", *apk_signing, "--out", str(apk), str(built / "aligned.apk"), env=env)
    run(tool(build_tools, "apksigner"), "verify", "--print-certs", str(apk), capture=True)
    shutil.copyfile(built / "driftbox.aab", aab)
    run("jarsigner", *bundle_signing, str(aab), args.alias, env=env, capture=True)
    # Not -strict, which fails what every upload key is: signed by itself, and not timestamped.
    if "jar verified." not in run("jarsigner", "-verify", str(aab), capture=True):
        raise ValueError(f"{aab.name} did not verify after signing.")
    run("java", "-jar", bundletool(), "validate", f"--bundle={aab}", capture=True)
    write_checksums([apk, aab], {**info, **carried, "signing": "upload key", "tested": not args.skip_tests},
                    dist / f"{stem}.json")
    print(f"Ready for review: {apk.name} and {aab.name} in dist/. Nothing has been uploaded or published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "prepare"])
    parser.add_argument("--keystore", default=os.environ.get("DRIFTBOX_ANDROID_KEYSTORE"))
    parser.add_argument("--alias", default=os.environ.get("DRIFTBOX_ANDROID_KEY_ALIAS"))
    parser.add_argument("--skip-tests", action="store_true",
                        help="build and sign without the lint, the constrained targets and the suite; "
                             "recorded in the manifest")
    args = parser.parse_args()
    try:
        release(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Android release preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
