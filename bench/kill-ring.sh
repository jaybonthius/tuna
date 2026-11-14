#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: kill-ring.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-kill-ring.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/kill-ring.sls "$lib/kill-ring-bench.sls"
printf '(import (tuna) (kill-ring-bench))\n(kill-ring-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["push"] = "ns"
    unit["push-large"] = "ns"
    unit["append"] = "ns"
    unit["prepend"] = "ns"
    unit["piece"] = "ns"
    unit["insert-overhead"] = "ns"
    unit["save-20"] = "ns"
    unit["save-200"] = "ns"
    unit["save-1000"] = "ns"
    unit["save-4096"] = "ns"
    unit["rotate"] = "ns"
    unit["insert"] = "ns"
    unit["replace"] = "ns"
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
