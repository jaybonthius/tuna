#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: commands.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-commands.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib/bench
mkdir -p "$lib"
cp bench/commands.sls "$lib/commands.sls"
{
  printf '#!tuna\n(import (commands))\n'
  i=0
  while [ $i -lt 2000 ]; do
    printf '(commands:define-command (filler-%d) "Fills the registry." %d)\n' $i $i
    i=$((i + 1))
  done
} > "$lib/filler.sls"
printf '(import (tuna) (bench commands))\n(bench/commands:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["run-outermost-unhooked"] = "ns"
    unit["run-outermost"] = "ns"
    unit["run-outermost-bytes"] = "B"
    unit["run-nested"] = "ns"
    unit["command?"] = "ns"
    unit["command-named"] = "ns"
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
