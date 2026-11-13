#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: layout-tabs.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-layout-tabs.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/layout-tabs.sls "$lib/layout-tabs-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/layout/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (layout-tabs-bench))\n(layout-tabs-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# A tab command or a click on a label, with the batch end that saves the
# layout, is a window command: 100 microseconds; drawing the layout's own
# parts, its views left out, 50.
echo "$output" | awk '
  BEGIN {
    limit["tabs-window-command"] = 100000
    limit["tabs-next-tab"] = 100000
    limit["tabs-label-click"] = 100000
    limit["tabs-screen-parts"] = 50000
    failed = 0
  }
  $1 == "parts" { if ($2 != 47) { print "parts: expected 47, got " $2; failed = 1 }; next }
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
