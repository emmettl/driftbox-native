#!/bin/sh
# A private compositor and bus: no live desktop, UTM input, user preferences or unlock needed.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "$(id -u)" = 0 ]; then
    echo 'Run as an unprivileged user (CI: runuser -u nobody -- scripts/test-linux-wayland.sh).' >&2
    exit 1
fi
if [ "${1:-}" != --session ]; then exec dbus-run-session -- "$0" --session; fi
work=$(mktemp -d)
compositor=
probe=
cleanup() {
    [ -z "$probe" ] || kill "$probe" 2>/dev/null || true
    [ -z "$compositor" ] || kill "$compositor" 2>/dev/null || true
    [ -z "$compositor" ] || wait "$compositor" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$work/home" XDG_RUNTIME_DIR="$work/runtime"
export XDG_CONFIG_HOME="$HOME/config" XDG_DATA_HOME="$HOME/data" XDG_CACHE_HOME="$HOME/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export GDK_BACKEND=wayland GTK_A11Y=none GSK_RENDERER=cairo GSETTINGS_BACKEND=memory GIO_USE_VFS=local
export G_DEBUG=fatal-criticals
# Keep any D-Bus activated helper inside this test's home as well.
dbus-update-activation-environment HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
${CC:-cc} -std=c11 -Wall -Wextra -Werror scripts/test-linux-dialogs.c \
    -I Sources/CLinuxUI/include $(pkg-config --cflags --libs gtk4) -ldl -o "$work/dialogs"
${CC:-cc} -std=c11 -Wall -Wextra -Werror scripts/linux-menu-probe.c \
    $(pkg-config --cflags --libs gtk4) -o "$work/menus"
cat > "$work/sway.conf" <<'CONFIG'
output * mode 1280x800
seat seat0 fallback true
xwayland disable
CONFIG
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    sway --unsupported-gpu -c "$work/sway.conf" > "$work/sway.log" 2>&1 &
compositor=$!
socket=
for attempt in $(seq 1 100); do
    socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' | head -1)
    [ -z "$socket" ] || break
    sleep .1
done
if [ -z "$socket" ]; then cat "$work/sway.log"; exit 1; fi
export WAYLAND_DISPLAY=${socket##*/}
"$work/dialogs"
echo 'PASS: native Wayland dialog lifetime checks'
# GTK 4.14 menu switching remains an opt-in diagnostic until toolkit/compositor qualification.
[ "${DRIFTBOX_TEST_MENUS:-0}" = 1 ] || exit 0
for direction in Left Right; do
    DRIFTBOX_MENU_PROBE_SELF_TEST=1 "$work/menus" > "$work/menu.log" 2>&1 &
    probe=$!
    for attempt in $(seq 1 100); do
        grep -q '^READY$' "$work/menu.log" && break
        kill -0 "$probe" 2>/dev/null || { cat "$work/menu.log"; exit 1; }
        sleep .1
    done
    grep -q '^READY$' "$work/menu.log" || { cat "$work/menu.log"; exit 1; }
    wtype -s 500 -k F10 -s 150 -k "$direction" -s 150 -k Down -k Return -s 500
    if ! wait "$probe"; then cat "$work/menu.log"; exit 1; fi
    probe=
    grep -q '^ACTIVATED$' "$work/menu.log"
    echo "PASS: native Wayland menu F10/$direction/Down/Return"
done
