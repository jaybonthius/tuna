#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: echo-status.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-echo-status.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/echo-status.sls "$lib/echo-status-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/echo-area/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (echo-status-bench))\n(echo-status-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["press-key"] = "ns"
    unit["press-key-bytes"] = "B"
    unit["press-key-clearing"] = "ns"
    unit["press-key-showing"] = "ns"
    unit["message-new"] = "ns"
    unit["message-repeated"] = "ns"
    unit["message-bytes"] = "B"
    unit["batch-end"] = "ns"
    unit["status-line-draw"] = "ns"
    unit["status-line-draw-bytes"] = "B"
    unit["screen-one-client"] = "ns"
    unit["screen-four-clients"] = "ns"
    unit["window-command"] = "ns"
    unit["screen-one-client-without-status-lines"] = "ns"
    unit["screen-four-clients-without-status-lines"] = "ns"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-40s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-40s no result\n", name; missing = 1 }
    exit missing
  }'
