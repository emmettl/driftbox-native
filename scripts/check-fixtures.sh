#!/bin/sh
# Fails if the checked-in fixtures no longer match the pinned submodule. After bumping `driftbox`,
# run `node conformance/emit/emit.mjs` and commit the result: the diff is the list of what changed
# on the web side, and the Swift tests say what it broke.
set -eu
cd "$(dirname "$0")/.."
node --no-warnings conformance/emit/emit.mjs --check
