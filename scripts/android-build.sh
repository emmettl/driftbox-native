#!/bin/sh
# Builds `driftbox-play` for an arm64 Android phone and pushes it there over adb, to $phone. Sourced
# by `android-bench.sh` and `android-play.sh`, which say what to run once it is there. No app and
# no install: Android runs a plain executable from /data/local/tmp. `android-env.sh` says what it
# needs.
. "$(dirname "$0")/android-env.sh"

# shellcheck disable=SC2086
compile $core
rm -f "$out/driftbox-play.o"
# shellcheck disable=SC2086
"$swiftc" $common -wmo -O -parse-as-library -swift-version 6 -module-name driftbox_play -I "$out" \
  -c -o "$out/driftbox-play.o" Sources/driftbox-play/*.swift
link "$out/driftbox-play" "$out/driftbox-play.o"

# Built only, when that is all that is asked, as CI asks: a script that sources this one goes on to
# run it on the phone.
if [ "${1:-}" = build ]; then
  echo "built $out/driftbox-play"
  exit 0
fi

need_adb
phone=/data/local/tmp/driftbox
"$adb" shell mkdir -p "$phone"
"$adb" push -q "$out/driftbox-play" "$libcxx" "$phone/"
"$adb" shell chmod 755 "$phone/driftbox-play"
echo "on $("$adb" shell getprop ro.product.model | tr -d '\r'), $("$adb" shell getprop ro.soc.model | tr -d '\r')"
