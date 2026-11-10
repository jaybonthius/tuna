#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: hot-paths.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-6}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-hot-paths.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"
cp bench/hot-paths.sls "$lib/hot-paths.sls"
printf '#!tuna\n(define (add1 x) (fx+ x 1))\n' > "$lib/bench-callee.sls"
printf '(import (tuna) (hot-paths))\n(hot-paths:run)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# Each limit sits a tenth or more above the highest of repeated runs, so
# that noise alone fails no run. Four results are at the floor
# documented Chez allows: an option read calls the record's thread
# parameter across a library, and a critical dynamic-wind, which
# with-options and an owner switch need so that a quit cannot leave them
# half done, costs about 19 ns while the timer is set.
echo "$output" | awk '
  BEGIN {
    limit["changeable-call"] = 1.2
    limit["option-read"] = 3.6
    limit["option-read-bound"] = 5.8
    limit["option-read-local"] = 25
    limit["with-options"] = 38
    limit["hook-entry-other"] = 37
    limit["hook-entry-same"] = 12
    limit["hook-one-entry-other"] = 76
    limit["table-ref-symbol"] = 8.5
    limit["table-ref-string"] = 26
    limit["table-set!"] = 100
    limit["set-option!"] = 150
    limit["add-hook!-remove-hook!"] = 400
    limit["spawn-task-20000"] = 1000
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-24s %10.2f ns  limit %7.1f ns  %s\n", $1, $2, limit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-24s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
