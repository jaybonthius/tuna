#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: views.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
library=$(dirname "$tuna")/plugins
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-views.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/views.sls "$lib/views-bench.sls"
cp bench/scroll-report.sls "$lib/scroll-report.sls"
# The web plugin's stand-in spares the benchmark a server and makes its
# clients.
cp tests/views/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (views-bench))\n(views-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["build-only-typical"] = "ns"
    unit["write-only-typical"] = "ns"
    unit["draw-typical"] = "ns"
    unit["draw-heavy"] = "ns"
    unit["draw-region"] = "ns"
    unit["draw-two-clients"] = "ns"
    unit["build-only-nodes"] = "ns"
    unit["draw-nodes"] = "ns"
    unit["report"] = "ns"
    unit["save"] = "ns"
    unit["save-with-histories"] = "ns"
    unit["switch-buffer"] = "ns"
    unit["edit-ten-views"] = "ns"
    unit["edit-other-views"] = "ns"
    unit["next-stop"] = "ns"
    unit["draw-one-line"] = "ns"
    unit["draw-one-line-source"] = "ns"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-28s %12.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-28s no result\n", name; missing = 1 }
    exit missing
  }'
