#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: saved.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-saved.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"
cp bench/saved.sls "$lib/saved-bench.sls"
printf '(import (tuna) (saved-bench))\n(saved-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# Main-thread time per batch that sets one datum: a ring of 120 entries
# of 4,096 characters, and a history of 10,000 short strings.
echo "$output" | awk '
  BEGIN {
    unit["saved-ring-4096"] = "ns"
    unit["saved-history-10000"] = "ns"
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
