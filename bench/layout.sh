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
echo "$output" | awk '
  BEGIN {
    unit["focus-keymaps"] = "ns"
    unit["call-with-frame"] = "ns"
    unit["display-buffer"] = "ns"
    unit["window-command"] = "ns"
    unit["place-side-part"] = "ns"
    unit["zoom"] = "ns"
    unit["other-view"] = "ns"
    unit["screen-parts"] = "ns"
    missing = 0
  }
  $1 == "parts" { printf "%-28s %10d\n", $1, $2; next }
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
