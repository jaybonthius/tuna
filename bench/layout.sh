#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: layout.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-layout.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/layout.sls "$lib/layout-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/layout/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (layout-bench))\n(layout-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# A keystroke's share of the main thread's millisecond: the focus path's
# keymaps 6 microseconds, entering the frame 1; drawing the layout's own
# parts, its views left out, 50; a window command with the batch end
# that saves the layout 100; showing a buffer past twenty rules 20.
echo "$output" | awk '
  BEGIN {
    limit["focus-keymaps"] = 6000
    limit["call-with-frame"] = 1000
    limit["display-buffer"] = 20000
    limit["window-command"] = 100000
    limit["screen-parts"] = 50000
    failed = 0
  }
  $1 == "parts" { if ($2 != 49) { print "parts: expected 49, got " $2; failed = 1 }; next }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-28s %10.2f ns   limit %10.2f ns   %s\n", $1, $2, limit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
