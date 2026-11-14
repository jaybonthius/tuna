#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: modes.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-modes.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/modes.sls "$lib/modes-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/modes/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (modes-bench))\n(modes-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["active-keymaps"] = "ns"
    unit["active-keymaps-bytes"] = "B"
    unit["active-minor-modes"] = "ns"
    unit["press-key-with-modes"] = "ns"
    unit["press-key-without-modes"] = "ns"
    unit["set-major-mode"] = "ns"
    unit["run-mode-hooks"] = "ns"
    unit["run-mode-hooks-setting"] = "ns"
    unit["set-option-local-unchanged"] = "ns"
    unit["choose"] = "ns"
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
