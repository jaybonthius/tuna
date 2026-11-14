#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: editing.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-editing.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/editing.sls "$lib/editing-bench.sls"
# Editing looks nothing up in the web plugin, so its stand-in spares the
# benchmark a server.
cp tests/editing/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (editing-bench))\n(editing-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["self-insert-overhead"] = "ns"
    unit["self-insert-further-cursor"] = "ns"
    unit["forward-char"] = "ns"
    unit["next-line"] = "ns"
    unit["forward-word"] = "ns"
    unit["kill-region-line"] = "ns"
    unit["upcase-word"] = "ns"
    unit["transpose-words"] = "ns"
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
