"""Prepare a Developer ID release of Driftbox, notarised and stapled, on this Mac.

Never tags, uploads or publishes anything: what it makes is left in dist/ for review. Adapted
from Hello Mini's, for an app with an Audio Unit extension inside it, which is signed first, with
its own sandbox, and the app around it after.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EXTENSION = "Contents/PlugIns/DriftboxAudioUnits.appex"
MINIMUM_MACOS = "26.0"


def built():
    """The app scripts/bundle-app.sh makes, registered on this Mac to develop with."""
    return ROOT / ".build-release/Driftbox.app"


def signed():
    """The copy of it a release signs."""
    return ROOT / "dist/Driftbox.app"


def run(*arguments, capture=False, env=None):
    return subprocess.run(arguments, cwd=ROOT, check=True, text=True, env=env,
                          stdout=subprocess.PIPE if capture else None).stdout


def read_version(text):
    """The version and build scripts/version.env gives, checked."""
    values = dict(re.findall(r"^(DRIFTBOX_\w+)=(\S+)$", text, re.MULTILINE))
    version, build = values.get("DRIFTBOX_VERSION", ""), values.get("DRIFTBOX_BUILD", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Use a numeric major.minor.patch DRIFTBOX_VERSION in scripts/version.env.")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Use a positive whole DRIFTBOX_BUILD in scripts/version.env.")
    return version, build


def metadata(plist):
    """What a bundle's Info.plist says it is, checked."""
    version = plist.get("CFBundleShortVersionString", "")
    build = plist.get("CFBundleVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("The bundle needs a numeric major.minor.patch version.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("The bundle needs a positive whole build number.")
    if plist.get("LSMinimumSystemVersion") != MINIMUM_MACOS:
        raise ValueError("Update the release requirements before changing the macOS baseline.")
    if not plist.get("CFBundleIdentifier"):
        raise ValueError("The bundle needs a stable identifier.")
    return {"version": version, "build": build, "bundleIdentifier": plist["CFBundleIdentifier"],
            "minimumMacOS": MINIMUM_MACOS, "architecture": "arm64"}


def choose_identity(output, requested):
    identities = re.findall(r'([A-Fa-f0-9]{40}) "(Developer ID Application: [^"]+)"', output)
    matches = [(fingerprint, name) for fingerprint, name in identities
               if not requested or requested in (fingerprint, name)]
    if len(matches) != 1:
        raise ValueError("Select one valid Developer ID Application identity with --identity. "
                         "An Apple Development identity cannot be used for this release.")
    return matches[0][0]


def signing_order(app, identity):
    """The codesign runs a release is signed by, inside out: the extension, sandboxed, before
    the app around it, each under the hardened runtime and with a secure timestamp."""
    common = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
    return [
        [*common, "--entitlements", str(ROOT / "scripts/extension.entitlements"), str(app / EXTENSION)],
        [*common, "--entitlements", str(ROOT / "scripts/app.entitlements"), str(app)],
    ]


def write_checksums(archive, manifest):
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    archive.with_suffix(archive.suffix + ".sha256").write_text(f"{checksum}  {archive.name}\n")
    archive.with_suffix(".json").write_text(json.dumps({**manifest, "sha256": checksum}, indent=2) + "\n")


def preflight(args):
    identity = choose_identity(run("security", "find-identity", "-v", "-p", "codesigning", capture=True),
                               args.identity)
    if not args.notary_profile:
        raise ValueError("Supply a previously configured Keychain profile with --notary-profile.")
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("Commit or set aside working-tree changes before preparing a release.")
    version, build = read_version((ROOT / "scripts/version.env").read_text())
    info = {"version": version, "build": build,
            "commit": run("git", "rev-parse", "HEAD", capture=True).strip()}
    return identity, info


def checks(args):
    run("swift", "format", "lint", "--strict", "-r", "Sources", "Tests", "Package.swift")
    run("sh", "scripts/check-constrained.sh")
    if not args.skip_tests:
        # Strictly, as CI runs them: a closure the main actor made, called from another thread,
        # traps in the app, and only this makes it trap in a test.
        run("swift", "test", env={**os.environ, "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": "swift6"})


def release(args):
    identity, info = preflight(args)
    if args.command == "check":
        print(f"Release {info['version']} ({info['build']}): local signing prerequisites present. "
              "Notary credentials are checked when submitting.")
        return
    archive = ROOT / "dist" / f"Driftbox-{info['version']}-macos-arm64.zip"
    if archive.exists():
        raise ValueError(f"Archive already exists: {archive.name}. Move it aside before retrying.")
    checks(args)
    run("sh", "scripts/bundle-app.sh")
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("The build changed the source checkout; review and commit the changes before releasing.")

    # A copy to sign, so the build this Mac has registered to develop with is left as it was.
    app = signed()
    app.parent.mkdir(exist_ok=True)
    if app.exists():
        shutil.rmtree(app)
    run("ditto", str(built()), str(app))
    for bundle in (app, app / EXTENSION):
        carried = metadata(plistlib.loads((bundle / "Contents/Info.plist").read_bytes()))
        if (carried["version"], carried["build"]) != (info["version"], info["build"]):
            raise ValueError(f"{bundle.name} does not carry the release's version and build.")
        info.setdefault("bundleIdentifier", carried["bundleIdentifier"])
    for executable in (app / "Contents/MacOS/Driftbox", app / EXTENSION / "Contents/MacOS/DriftboxAudioUnits"):
        if run("lipo", "-archs", str(executable), capture=True).strip() != "arm64":
            raise ValueError("This release channel expects an arm64 build.")

    for command in signing_order(app, identity):
        run(*command)
    run("codesign", "--verify", "--deep", "--strict", str(app))
    with tempfile.TemporaryDirectory(prefix="driftbox-notary-", dir=ROOT / "dist") as temporary:
        submission = Path(temporary) / "submission.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(submission))
        response = json.loads(run("xcrun", "notarytool", "submit", str(submission),
                                  "--keychain-profile", args.notary_profile, "--wait",
                                  "--timeout", "30m", "--output-format", "json", capture=True))
        (ROOT / "dist/notarization.json").write_text(json.dumps(response, indent=2) + "\n")
        if response.get("status") != "Accepted":
            raise ValueError("Notarization was not accepted. Inspect dist/notarization.json and "
                             "retrieve the submission log with notarytool before retrying.")
    run("xcrun", "stapler", "staple", str(app))
    run("xcrun", "stapler", "validate", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    run("spctl", "--assess", "--type", "execute", "--verbose=4", str(app))
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    write_checksums(archive, {**info, "minimumMacOS": MINIMUM_MACOS, "architecture": "arm64",
                              "signing": "Developer ID Application", "notarized": True,
                              "tested": not args.skip_tests})
    print(f"Ready for review: {archive}. Nothing has been tagged, uploaded or published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "prepare"])
    parser.add_argument("--identity", default=os.environ.get("DRIFTBOX_SIGNING_IDENTITY"))
    parser.add_argument("--notary-profile", default=os.environ.get("DRIFTBOX_NOTARY_PROFILE"))
    parser.add_argument("--skip-tests", action="store_true",
                        help="lint and check the constrained targets, but do not run the tests; "
                             "recorded in the manifest")
    args = parser.parse_args()
    try:
        release(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
