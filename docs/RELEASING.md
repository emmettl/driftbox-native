# Releasing Driftbox

A release is prepared on this Mac, not in CI: CI has no signing identity or notary credentials, and
builds with ad-hoc signing. `scripts/release.py` signs the app with a Developer ID, has Apple
notarise it, staples the ticket, checks that Gatekeeper accepts it, and leaves a ZIP, a checksum and
a manifest in `dist/`. It never creates a tag, uploads a build, or publishes anything. It follows
Hello Mini's release script, adapted for an app that has an Audio Unit extension inside it.

## One-time signing setup

The Mac needs a valid **Developer ID Application** certificate with its private key in the
Keychain. An Apple Development certificate will not do. Notary credentials are kept in a
`notarytool` Keychain profile, set up interactively, so no password is ever in a script or the
repository. A profile belongs to an Apple account, not an app: Hello Mini's works here too.

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials "Driftbox-notary"
```

## What is signed, and with what

Signing goes inside out, each with a secure timestamp and under the hardened runtime that
notarisation requires:

1. `Contents/PlugIns/DriftboxAudioUnits.appex`, the AUv3 extension that holds the rack and the
   groovebox, with `scripts/extension.entitlements`: the App Sandbox, without which no host loads
   it, and read access to files the user chooses.
2. `Driftbox.app` around it, with `scripts/app.entitlements`. That has one exception to the
   hardened runtime, `com.apple.security.cs.disable-library-validation`. The rack loads Audio
   Units and VST 3 plug-ins into its own process, and they are signed by other developers or not
   at all, which library validation would refuse.

The resource bundles in `Contents/Resources` hold no code, and are sealed by the signatures around
them.

## Build a candidate

1. Set `DRIFTBOX_VERSION` (numeric `major.minor.patch`) and `DRIFTBOX_BUILD` (a whole number that
   goes up with every release) in `scripts/version.env`, then commit. `scripts/bundle-app.sh` writes
   both into the app's and the extension's Info.plists. It also writes the Audio Unit components'
   version, packed from the release's as Apple packs one, so that hosts scan the plug-ins again
   after an update.
2. With a clean checkout, give the identity and the Keychain profile:

```sh
export DRIFTBOX_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export DRIFTBOX_NOTARY_PROFILE="Driftbox-notary"
python3 scripts/release.py check
python3 scripts/release.py prepare
```

`check` only looks at what is on this Mac: one Developer ID identity, a profile named, a clean
checkout, and a version file in order. The profile's credentials are first tried when submitting.

`prepare` then:

- lints, checks the constrained targets, and runs the whole suite strictly, as CI does;
- builds the app with `scripts/bundle-app.sh`, and copies it to `dist/Driftbox.app`, so the build
  this Mac has registered to develop with is left as it was;
- checks that both bundles carry the release's version and build, and are arm64;
- signs them inside out, and verifies the signature;
- submits a ZIP to Apple and waits up to half an hour;
- staples the ticket, validates it, verifies the signature again, and asks Gatekeeper;
- only then writes `dist/Driftbox-<version>-macos-arm64.zip`, its `.sha256`, and a `.json` manifest.
  The manifest records the version, build, source commit, bundle identifier, architecture,
  minimum macOS, checksum, and whether the release was signed, notarised and tested.

It stops at the first thing that fails, and never overwrites an archive that is already there.
`--skip-tests` leaves out the test suite only (lint and the constrained targets still run), for a
second try at a candidate already tested at the same commit. The manifest says the tests were
skipped.

If notarisation turns the app down, `dist/notarization.json` has the submission's id. Fetch its
log with `xcrun notarytool log <id> --keychain-profile "$DRIFTBOX_NOTARY_PROFILE"`. If the wait
times out, find the submission with `notarytool history` before submitting again, and do not take a
timed-out submission as accepted.

## Before publishing

Unzip the archive somewhere new, and try that copy on a Mac with Gatekeeper on, as a download from
a browser would be:

- first launch;
- the visuals;
- MIDI in;
- a hosted Audio Unit, and a VST 3;
- the AUv3 instruments in a host such as Logic or GarageBand, which registers them when the app
  first launches;
- a song saved and opened again.

The repository is private until the port reaches parity, so where and how a release is published
is still to be decided. Whatever it is, nothing here does it on its own.

`python3 scripts/test-release.py` checks all of this without signing or uploading anything, and CI
runs it.
