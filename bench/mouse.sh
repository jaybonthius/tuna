#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: mouse.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-mouse.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/mouse.sls "$lib/mouse-bench.sls"
# A mouse item reaches views' handler as web would hand it over, so the
# web plugin's stand-in spares the benchmark a server.
cp tests/editing/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (mouse-bench))\n(mouse-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    limit["mouse-click"] = 30000
    limit["mouse-move"] = 30000
    limit["mouse-click-stale"] = 100000
    failed = 0
  }
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
