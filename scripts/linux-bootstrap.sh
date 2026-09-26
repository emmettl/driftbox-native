#!/bin/sh
# Explicitly provision a disposable Ubuntu 24.04 development guest, not the Mac host.
set -eu
[ "$(uname -s)" = Linux ] || { echo 'Run inside the Ubuntu development VM.' >&2; exit 1; }
. /etc/os-release
[ "$ID:$VERSION_ID" = ubuntu:24.04 ] || { echo 'This bootstrap supports Ubuntu 24.04 only.' >&2; exit 1; }
case "$(uname -m)" in
  aarch64) platform=ubuntu2404-aarch64; suffix=ubuntu24.04-aarch64 ;;
  x86_64) platform=ubuntu2404; suffix=ubuntu24.04 ;;
  *) echo 'Supported architectures: aarch64 and x86_64.' >&2; exit 1 ;;
esac
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg binutils build-essential git pkg-config python3 rsync \
  libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libstdc++-13-dev \
  libncurses-dev libpython3-dev libsqlite3-0 libxml2-dev libz3-dev uuid-dev \
  tzdata zip unzip zlib1g-dev \
  libegl-dev libgles-dev libegl-mesa0 libgl1-mesa-dri mesa-utils \
  libpipewire-0.3-dev pipewire pipewire-pulse wireplumber libasound2-dev \
  libgtk-4-dev libpango1.0-dev qemu-guest-agent
release=swift-6.4.0-RELEASE
archive="$release-$suffix.tar.gz"
base="https://download.swift.org/swift-6.4.0-release/$platform/$release"
cache="$HOME/.cache/driftbox-toolchain"
toolchain="$HOME/.local/share/driftbox-toolchains/$release"
mkdir -p "$cache" "$(dirname "$toolchain")"
if [ ! -x "$toolchain/usr/bin/swift" ]; then
  curl -fL --retry 3 "$base/$archive" -o "$cache/$archive"
  curl -fL --retry 3 "$base/$archive.sig" -o "$cache/$archive.sig"
  curl -fL --retry 3 https://www.swift.org/keys/all-keys.asc -o "$cache/swift-keys.asc"
  keyring=$(mktemp -d)
  trap 'rm -rf "$keyring"' EXIT HUP INT TERM
  gpg --homedir "$keyring" --batch --import "$cache/swift-keys.asc"
  gpg --homedir "$keyring" --batch --verify "$cache/$archive.sig" "$cache/$archive"
  staging=$(mktemp -d "$(dirname "$toolchain")/.install.XXXXXX")
  tar xzf "$cache/$archive" -C "$staging" --strip-components=1
  "$staging/usr/bin/swift" --version
  mv "$staging" "$toolchain"
fi
mkdir -p "$HOME/.local/bin"
# A wrapper leaves the rest of an existing Swift installation untouched.
cat > "$HOME/.local/bin/driftbox-swift" <<WRAPPER
#!/bin/sh
exec "$toolchain/usr/bin/swift" "\$@"
WRAPPER
chmod +x "$HOME/.local/bin/driftbox-swift"
"$toolchain/usr/bin/swift" --version
printf '\nUse: export PATH="%s/usr/bin:$PATH"\n' "$toolchain"
printf 'Then run scripts/linux-build.sh doctor, build, and test.\n'
