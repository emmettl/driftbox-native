#!/bin/sh
# Run inside Linux. The Mac-side checkout is synced separately; builds stay on the guest disk.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ "$(uname -s)" = Linux ] || { echo 'Run this script inside the Linux development VM.' >&2; exit 1; }
jobs=${DRIFTBOX_BUILD_JOBS:-4}
case "$jobs" in ''|*[!0-9]*|0) echo 'DRIFTBOX_BUILD_JOBS must be a positive integer.' >&2; exit 64;; esac
# Prefer the isolated toolchain installed by linux-bootstrap.sh when present.
toolchain="$HOME/.local/share/driftbox-toolchains/swift-6.4.0-RELEASE"
if [ -x "$toolchain/usr/bin/swift" ]; then PATH="$toolchain/usr/bin:$PATH"; export PATH; fi
mode=${1:-doctor}
shift "$(( $# > 0 ? 1 : 0 ))"
case "$mode" in
  doctor)
    uname -sm
    swift --version
    pkg-config --modversion egl glesv2 libpipewire-0.3 alsa gtk4 pangocairo
    df -h .
    ;;
  build)
    swift build --scratch-path .build-linux -j "$jobs" --product driftbox-render
    swift build --scratch-path .build-linux -j "$jobs" --product driftbox-play
    ;;
  test)
    EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1 \
      SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6 \
      swift test --scratch-path .build-linux -j "$jobs" "$@"
    ;;
  gpu)
    EGL_PLATFORM=${EGL_PLATFORM:-surfaceless} \
      swift run --scratch-path .build-linux -j "$jobs" driftbox-play --gpu-info
    ;;
  desktop)
    swift run --scratch-path .build-linux -c release -j "$jobs" driftbox-linux "$@"
    ;;
  window)
    swift run --scratch-path .build-linux -c release -j "$jobs" driftbox-linux-window "$@"
    ;;
  play)
    swift run --scratch-path .build-linux -c release -j "$jobs" driftbox-play "$@"
    ;;
  bench)
    swift run --scratch-path .build-linux -c release -j "$jobs" driftbox-play \
      "${1:-conformance/fixtures/documents/acid.song.json}" --bench
    ;;
  render)
    swift run --scratch-path .build-linux -c release -j "$jobs" driftbox-render "$@"
    ;;
  *)
    echo 'usage: scripts/linux-build.sh {doctor|build|gpu|test [swift-test-options]|desktop [desktop-options]|window [--seconds n | --self-test]|play [player-options]|bench [song]|render [render-options]}' >&2
    exit 64
    ;;
esac
