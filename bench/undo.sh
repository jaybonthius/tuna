#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: undo.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-undo.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/undo.sls "$lib/undo-bench.sls"
cp tests/undo/home/.config/tuna/lib/web.sls "$lib/"
printf '(import (tuna) (undo-bench))\n(undo-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    limit["record-ns"] = 1000; unit["record-ns"] = "ns"
    limit["batch-end-ns"] = 2000; unit["batch-end-ns"] = "ns"
    limit["undo-step-us"] = 10; unit["undo-step-us"] = "us"
    limit["read-log-ms-per-mb"] = 26; unit["read-log-ms-per-mb"] = "ms"
    limit["replay-ns-per-record"] = 1000; unit["replay-ns-per-record"] = "ns"
    limit["writer-round-ms"] = 25; unit["writer-round-ms"] = "ms"
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-28s %10.2f %-3s  limit %8.2f %-3s  %s\n", $1, $2, unit[$1], limit[$1], unit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
