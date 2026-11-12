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
# A kill happens once per command, so the save's limit is a share of a
# command's time, not of a keystroke's. A ring of 120 entries of 4,096
# characters, the most it saves, takes the core over 2 ms to print.
echo "$output" | awk '
  BEGIN {
    limit["push"] = 2000
    limit["push-large"] = 2000
    limit["append"] = 2000
    limit["prepend"] = 2000
    limit["piece"] = 2000
    limit["insert-overhead"] = 1000
    limit["save-20"] = 1500000
    limit["save-200"] = 1500000
    limit["save-1000"] = 1500000
    limit["save-4096"] = 4000000
    split("rotate insert replace", r, " ")
    for (i in r) recorded[r[i]] = 1
    failed = 0
  }
  $1 in recorded { printf "%-28s %10.2f ns   recorded\n", $1, $2; next }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-28s %10.2f ns   limit %10.2f ns   %s\n", $1, $2, limit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
