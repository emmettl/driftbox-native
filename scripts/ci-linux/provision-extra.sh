#!/bin/bash
set -euo pipefail
sudo apt-get install -y --no-install-recommends xvfb xauth dbus-x11 pipewire-bin desktop-file-utils shared-mime-info python3-gi
mkdir -p "$HOME/.local/share/node" "$HOME/.cache/node"
cd "$HOME/.cache/node"
curl -fsSLO https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt
archive=$(awk '$2 ~ /^node-v24\.[0-9]+\.[0-9]+-linux-arm64.tar.xz$/ {print $2}' SHASUMS256.txt)
test -n "$archive"
curl -fSL --retry 3 "https://nodejs.org/dist/latest-v24.x/$archive" -o "$archive"
grep " $archive\$" SHASUMS256.txt | sha256sum -c -
tar -xJf "$archive" -C "$HOME/.local/share/node" --strip-components=1
export PATH="$HOME/.local/share/node/bin:$PATH"
node --version
npm exec --yes --package=playwright@1.63.0 -- playwright install --with-deps chromium
