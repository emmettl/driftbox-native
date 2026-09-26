#!/bin/sh
# Native Linux release build, followed by an independent Ubuntu runtime-only test.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
: "${SOURCE_REVISION:=$(git rev-parse HEAD)}"
: "${SOURCE_DATE_EPOCH:=$(git show -s --format=%ct HEAD)}"
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
deb_context=
cleanup() {
    [ -z "$container" ] || docker rm "$container" >/dev/null
    [ -z "$deb_context" ] || rm -rf "$deb_context"
    docker image rm "$tag" "$tag-runtime" "$tag-deb-runtime" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker build --network "${BUILD_NETWORK:-default}" -f linux/packaging/Build.Dockerfile -t "$tag" \
    --build-arg "JOBS=${JOBS:-4}" --build-arg "SOURCE_REVISION=$SOURCE_REVISION" \
    --build-arg "SOURCE_DIRTY=$SOURCE_DIRTY" --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" .
container=$(docker create "$tag")
docker cp "$container:/out/." "$out/"
docker build --network "${BUILD_NETWORK:-default}" -f linux/packaging/Runtime.Dockerfile -t "$tag-runtime" .
# The package directory is the ONLY mount. No Swift install, source tree, desktop session,
# host libraries or audio devices can make the clean-runtime check pass accidentally.
docker run --rm --network none --mount "type=bind,src=$out,dst=/packages,readonly" "$tag-runtime"
# A separate minimal image downloads (but does not install) Depends. All installation,
# upgrade/removal and GUI checks then run offline, with only the artifact mount.
deb_context=$(mktemp -d)
cp linux/packaging/DebRuntime.Dockerfile "$deb_context/Dockerfile"
cp scripts/test-linux-deb-runtime.py "$deb_context/"
cp "$out"/*.deb "$deb_context/"
docker build --network "${BUILD_NETWORK:-default}" -t "$tag-deb-runtime" "$deb_context"
docker run --rm --network none --mount "type=bind,src=$out,dst=/packages,readonly" "$tag-deb-runtime"
echo "Validated $arch archive and deb: $out"
