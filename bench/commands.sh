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
    limit["run-outermost-unhooked"] = 2000
    limit["run-outermost"] = 2000
    limit["run-outermost-bytes"] = 2048; unit["run-outermost-bytes"] = "B"
    limit["run-nested"] = 2000
    limit["command?"] = 100
    limit["command-named"] = 100
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    u = ($1 in unit) ? unit[$1] : "ns"
    printf "%-28s %10.2f %-3s  limit %8.2f %-3s  %s\n", $1, $2, u, limit[$1], u, verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
