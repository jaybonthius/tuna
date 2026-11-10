#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
# Each limit sits a fifth or more above the highest of repeated runs, so
# that noise alone fails no run.
set -eu
tuna=${1:?usage: reload.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-6}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-reload.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"
cp bench/reload.sls "$lib/reload.sls"
printf '(import (tuna) (reload))\n(reload:run)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    limit["reload-unchanged-small"] = 0.3
    limit["reload-edited-small"] = 3.5
    limit["reload-edited-big"] = 28
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-24s %10.2f ms  limit %7.2f ms  %s\n", $1, $2, limit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-24s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
