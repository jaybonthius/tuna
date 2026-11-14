#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: ui.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-ui.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/ui.sls "$lib/ui-bench.sls"
# Clicks reach views' handler as web would hand them over, so the web
# plugin's stand-in spares the benchmark a server.
cp tests/editing/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (tuna plugins))\n(use-plugin editing)\n(import (ui-bench))\n(ui-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["ui-draw-list"] = "ns"
    unit["ui-next-row"] = "ns"
    unit["ui-select-row-slide"] = "ns"
    unit["ui-set-rows"] = "ns"
    unit["ui-click-row"] = "ns"
    unit["ui-click-button"] = "ns"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-28s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-28s no result\n", name; missing = 1 }
    exit missing
  }'
