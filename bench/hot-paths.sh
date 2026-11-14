#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: hot-paths.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-hot-paths.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"
cp bench/hot-paths.sls "$lib/hot-paths.sls"
cp bench/main-thread-paths.sls "$lib/main-thread-paths.sls"
printf '#!tuna\n(define (add1 x) (fx+ x 1))\n' > "$lib/bench-callee.sls"
printf '(import (tuna) (hot-paths) (main-thread-paths))\n(hot-paths:run)\n(main-thread-paths:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["changeable-call"] = "ns"
    unit["option-read"] = "ns"
    unit["option-read-bound"] = "ns"
    unit["option-read-local"] = "ns"
    unit["with-options"] = "ns"
    unit["hook-entry-other"] = "ns"
    unit["hook-entry-same"] = "ns"
    unit["hook-one-entry-other"] = "ns"
    unit["table-ref-symbol"] = "ns"
    unit["table-ref-string"] = "ns"
    unit["table-ref-procedure"] = "ns"
    unit["table-set!"] = "ns"
    unit["set-option!"] = "ns"
    unit["add-hook!-remove-hook!"] = "ns"
    unit["spawn-task-20000"] = "ns"
    unit["posted-item-bytes"] = "B"
    unit["dynamic-wind"] = "ns"
    unit["with-mutex"] = "ns"
    unit["batch-ended"] = "ns"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-24s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-24s no result\n", name; missing = 1 }
    exit missing
  }'
