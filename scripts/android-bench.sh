#!/bin/sh
# Times the engine on an Android phone, once on each kind of core it has: step 1 of milestone 5.
# Builds and pushes with `android-build.sh`, which says what it needs.
#
#     scripts/android-bench.sh                          # acid, on every kind of core
#     scripts/android-bench.sh conformance/fixtures/documents/orrery.song.json
. "$(dirname "$0")/android-build.sh"

[ $# -gt 0 ] || set -- conformance/fixtures/documents/acid.song.json
for song in "$@"; do
  "$adb" push -q "$song" "$phone/"
  # The first core of each speed, which is one of each kind: little, big and any prime.
  "$adb" shell "cd $phone && seen= &&
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      n=\${cpu##*cpu}; hz=\$(cat \$cpu/cpufreq/cpuinfo_max_freq)
      case \" \$seen \" in *\" \$hz \"*) continue;; esac; seen=\"\$seen \$hz\"
      echo \"cpu\$n, up to \$((hz / 1000))MHz:\"
      LD_LIBRARY_PATH=. taskset \$(printf %x \$((1 << n))) ./driftbox-play $(basename "$song") --bench | sed 's/^/  /'
    done"
done
