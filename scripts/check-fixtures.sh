#!/bin/sh
# Regenerates the fixtures from the pinned submodule and fails if they differ from what is checked
# in. After bumping `driftbox`, run `node conformance/emit/emit.mjs` and commit the result: the
# diff is the list of what changed on the web side, and the Swift tests say what it broke.
set -eu
cd "$(dirname "$0")/.."
node --no-warnings conformance/emit/emit.mjs
if ! git diff --quiet -- conformance/fixtures || [ -n "$(git ls-files --others --exclude-standard conformance/fixtures)" ]; then
  git status --short -- conformance/fixtures
  echo "conformance/fixtures is out of date with the driftbox submodule" >&2
  exit 1
fi
echo "fixtures are current"
