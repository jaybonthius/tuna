#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: diagnostics.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-diagnostics.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/diagnostics.sls "$lib/diagnostics-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/diagnostics-list/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (diagnostics-bench))\n(diagnostics-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["document-at-1-us"] = "us"
    unit["document-at-10-us"] = "us"
    unit["document-at-1000-us"] = "us"
    unit["report-2000-ms"] = "ms"
    unit["keystroke-0-us"] = "us"
    unit["keystroke-2000-us"] = "us"
    unit["status-line-0-us"] = "us"
    unit["status-line-2000-us"] = "us"
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
