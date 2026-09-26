#!/bin/sh
# Native Linux release build, followed by an independent Ubuntu runtime-only test.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
: "${SOURCE_REVISION:=$(git rev-parse HEAD)}"
if [ -z "${SOURCE_DIRTY:-}" ]; then
    if [ -z "$(git status --porcelain)" ]; then SOURCE_DIRTY=false; else SOURCE_DIRTY=true; fi
fi
out=${1:-dist/linux-ci}
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "Output must be empty: $out" >&2; exit 1; }
out=$(CDPATH='' cd -- "$out" && pwd)
case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64) arch=x86_64 ;;
    *) echo 'Only native ARM64 and x86-64 builds are supported.' >&2; exit 1 ;;
esac
# Unique names also allow simultaneous local runs on the same Docker daemon.
tag="driftbox-linux-package-$arch-$$"
container=
cleanup() {
    [ -z "$container" ] || docker rm "$container" >/dev/null
    docker image rm "$tag" "$tag-runtime" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker build --network "${BUILD_NETWORK:-default}" -f linux/packaging/Build.Dockerfile -t "$tag" \
    --build-arg "JOBS=${JOBS:-4}" --build-arg "SOURCE_REVISION=$SOURCE_REVISION" \
    --build-arg "SOURCE_DIRTY=$SOURCE_DIRTY" .
container=$(docker create "$tag")
docker cp "$container:/out/." "$out/"
docker build --network "${BUILD_NETWORK:-default}" -f linux/packaging/Runtime.Dockerfile -t "$tag-runtime" .
# The package directory is the ONLY mount. No Swift install, source tree, desktop session,
# host libraries or audio devices can make the clean-runtime check pass accidentally.
docker run --rm --network none --mount "type=bind,src=$out,dst=/packages,readonly" "$tag-runtime"
echo "Validated $arch package: $out"
