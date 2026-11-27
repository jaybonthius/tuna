#!/bin/sh
# Pinned to one CPU, so that each sample compares like with like.
set -eu
tuna=${1:?usage: jsonrpc.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-jsonrpc.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/jsonrpc.sls "$lib/jsonrpc-bench.sls"
cp tests/jsonrpc/home/fake-server.ss "$dir/home/"
printf '(import (tuna) (plugins))\n(use-plugin jsonrpc)\n(import (jsonrpc-bench))\n(spawn-task (lambda (restore) (jsonrpc-bench:run) (exit)))\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["jsonrpc-2mb-answer-log-default-ms"] = "ms"
    unit["jsonrpc-2mb-key-delay-log-default-ms"] = "ms"
    unit["jsonrpc-2mb-answer-log-off-ms"] = "ms"
    unit["jsonrpc-2mb-key-delay-log-off-ms"] = "ms"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-32s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-32s no result\n", name; missing = 1 }
    exit missing
  }'
