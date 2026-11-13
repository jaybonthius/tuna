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
# Each limit sits a tenth or more above the highest of repeated runs, so
# that noise alone fails no run. Four results are at the floor
# documented Chez allows: an option read calls the record's thread
# parameter across a library, and a critical dynamic-wind, which
# with-options and an owner switch need so that a quit cannot leave them
# half done, costs about 19 ns while the timer is set. Allocation does
# not vary between runs, so the limit on posted-item-bytes, a fifth above
# its figure, leaves room for small changes rather than for noise.
echo "$output" | awk '
  BEGIN {
    limit["changeable-call"] = 1.2
    limit["option-read"] = 3.6
    limit["option-read-bound"] = 5.8
    limit["option-read-local"] = 25
    limit["with-options"] = 38
    limit["hook-entry-other"] = 37
    limit["hook-entry-same"] = 12
    limit["hook-one-entry-other"] = 84
    limit["table-ref-symbol"] = 8.5
    limit["table-ref-string"] = 26
    limit["table-ref-procedure"] = 13
    limit["table-set!"] = 100
    limit["set-option!"] = 150
    limit["add-hook!-remove-hook!"] = 400
    limit["spawn-task-20000"] = 1000
    limit["posted-item-bytes"] = 326
    limit["dynamic-wind"] = 78
    limit["with-mutex"] = 106
    limit["batch-ended"] = 186
    unit["posted-item-bytes"] = "B"
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    u = ($1 in unit) ? unit[$1] : "ns"
    printf "%-24s %10.2f %-2s  limit %7.1f %-2s  %s\n", $1, $2, u, limit[$1], u, verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-24s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
