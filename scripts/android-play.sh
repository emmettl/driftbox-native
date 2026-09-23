#!/bin/sh
# Plays a song through an Android phone's speaker, through AAudio: step 2 of milestone 5. Builds
# and pushes with `android-build.sh`, which says what it needs. Anything after the song goes to
# `driftbox-play`.
#
#     scripts/android-play.sh                           # acid, for twenty seconds
#     scripts/android-play.sh conformance/fixtures/documents/orrery.song.json --seconds 60
. "$(dirname "$0")/android-build.sh"

song="${1:-conformance/fixtures/documents/acid.song.json}"
[ $# -gt 0 ] && shift
[ $# -gt 0 ] || set -- --seconds 20
"$adb" push -q "$song" "$phone/"
"$adb" shell "cd $phone && LD_LIBRARY_PATH=. ./driftbox-play $(basename "$song") $*"
