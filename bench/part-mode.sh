#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: part-mode.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-part-mode.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/part-mode.sls "$lib/part-mode-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/part-mode/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (part-mode-bench))\n(part-mode-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# A key in the part mode, with the batch end that saves the frame: a
# move to a sibling 20 microseconds; a verb that moves a view, one edit
# with its undo record and the save of the layout, 120. A verb that moves
# half the layout is recorded: its edit's cost grows with the parts it
# inserts.
echo "$output" | awk '
  BEGIN {
    limit["part-move"] = 20000
    limit["part-verb"] = 120000
    failed = 0
  }
  $1 == "parts" { if ($2 != 49) { print "parts: expected 49, got " $2; failed = 1 }; next }
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
