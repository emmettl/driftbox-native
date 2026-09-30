#!/bin/bash
set -euo pipefail
cd "$HOME/driftbox-native"
export PATH="$HOME/.local/share/driftbox-toolchains/swift-6.4.0-RELEASE/usr/bin:$PATH"
mkdir -p pilot-results
test ! -d .build-linux-cold
(
  while true; do
    printf '%s ' "$(date -Is)"
    awk '/MemTotal:|MemAvailable:|SwapTotal:|SwapFree:/ {printf "%s=%s ", $1, $2} END {print ""}' /proc/meminfo
    sleep 2
  done
) > pilot-results/cold-guest-memory.log &
monitor=$!
trap 'kill "$monitor" 2>/dev/null || true' EXIT
/usr/bin/time -v -o pilot-results/cold-build-time.txt \
  swift build --scratch-path .build-linux-cold --build-tests -j 2 \
  > pilot-results/cold-build.log 2>&1
tail -4 pilot-results/cold-build.log
cat pilot-results/cold-build-time.txt
