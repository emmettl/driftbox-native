#!/bin/bash
set -euo pipefail
cd "$HOME/driftbox-native"
export PATH="$HOME/.local/share/node/bin:$HOME/.local/share/driftbox-toolchains/swift-6.4.0-RELEASE/usr/bin:$PATH"
export DRIFTBOX_BUILD_JOBS=2 CI=1 EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1
export SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6
if [ -d pilot-results ]; then
  mv pilot-results "pilot-results-previous-$(date +%Y%m%d-%H%M%S)"
fi
mkdir pilot-results
exec > >(tee pilot-results/checks.log) 2>&1
(
  while true; do
    printf '%s ' "$(date -Is)"
    awk '/MemTotal:|MemAvailable:|SwapTotal:|SwapFree:/ {printf "%s=%s ", $1, $2} END {print ""}' /proc/meminfo
    sleep 2
  done
) > pilot-results/guest-memory.log &
memory_monitor=$!
trap 'kill "$memory_monitor" 2>/dev/null || true' EXIT
date -Is
git rev-parse HEAD
git -C driftbox rev-parse HEAD
test "$(git ls-tree HEAD driftbox | awk '{print $3}')" = "$(git -C driftbox rev-parse HEAD)"
scripts/linux-build.sh doctor
node --no-warnings conformance/emit/emit.mjs --check
node --no-warnings conformance/emit/emit.mjs --full
node --no-warnings conformance/emit/emit-audio.mjs
export DRIFTBOX_REQUIRE_GENERATED=1
failed=0
run() {
  local name=$1
  shift
  if "$@"; then
    printf '%s\t0\n' "$name" >> pilot-results/stages.tsv
  else
    local code=$?
    printf '%s\t%s\n' "$name" "$code" >> pilot-results/stages.tsv
    failed=$((failed + 1))
  fi
}
run swift-tests /usr/bin/time -v -o pilot-results/swift-test-time.txt scripts/linux-build.sh test --no-parallel --xunit-output pilot-results/tests.xml
run test-summary python3 scripts/summarise-tests.py --title 'Mini Linux ARM64 pilot' pilot-results/tests.xml
run gpu scripts/linux-build.sh gpu
run dialogs scripts/test-linux-dialogs.sh
run window xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 swift run --scratch-path .build-linux -j 2 driftbox-linux-window --self-test
run desktop xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 swift run --scratch-path .build-linux -j 2 driftbox-linux --silent --smoke-test
run pipewire-routes python3 scripts/test-linux-route.py
run release-scripts python3 scripts/test-release.py
run android-release-scripts python3 scripts/test-android-release.py
run linux-package-scripts python3 scripts/test-linux-package.py
run linux-deb-scripts python3 scripts/test-linux-deb.py
run constrained-audio scripts/check-constrained.sh
date -Is
free -m
if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed Linux CI pilot stages; see stages.tsv"
  exit 1
fi
echo 'PASS: Linux CI pilot checks'
