#!/bin/sh
# Pinned to one CPU, so that each sample compares like with like.
set -eu
tuna=${1:?usage: terminal.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-terminal.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/terminal.sls "$lib/terminal-bench.sls"
cp tests/help/home/.config/tuna/lib/web.sls "$lib/"
printf '(import (tuna) (terminal-bench))\n(spawn-task (lambda () (terminal-bench:run) (exit)))\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["terminal-colored-20k-ms"] = "ms"
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
