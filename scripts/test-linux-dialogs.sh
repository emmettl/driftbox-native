#!/bin/sh
# Native GTK callback/lifetime tests, isolated from the live desktop and preferences.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror scripts/test-linux-dialogs.c \
  -I Sources/CLinuxUI/include $(pkg-config --cflags --libs gtk4) -ldl \
  -o "$test_dir/dialogs"
mkdir "$test_dir/home"
xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 GTK_A11Y=none GSETTINGS_BACKEND=memory GIO_USE_VFS=local \
  LIBGL_ALWAYS_SOFTWARE=1 TMPDIR="$test_dir" HOME="$test_dir/home" \
  XDG_CONFIG_HOME="$test_dir/home/config" XDG_DATA_HOME="$test_dir/home/data" \
  XDG_CACHE_HOME="$test_dir/home/cache" "$test_dir/dialogs"
