#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: layout-scroll-float.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-layout-scroll-float.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/layout-scroll-float.sls "$lib/layout-scroll-float-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/scroll-float/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (layout-scroll-float-bench))\n(layout-scroll-float-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# A report of what a client has in view, as a view's scroll report, 20
# microseconds; a move between columns with its batch end is a window
# command, 100; a popup shown and closed, each with its batch end, 100;
# drawing the layout's own parts, its views left out, 70; moving an
# anchor, 5.
echo "$output" | awk '
  BEGIN {
    limit["strip-report"] = 20000
    limit["strip-select"] = 100000
    limit["popup-show-close"] = 100000
    limit["strip-screen-parts"] = 70000
    limit["anchor-move"] = 5000
    failed = 0
  }
  $1 == "parts" { if ($2 != 46) { print "parts: expected 46, got " $2; failed = 1 }; next }
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
