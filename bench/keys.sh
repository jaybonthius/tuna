#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: keys.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-keys.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/keys.sls "$lib/keys-bench.sls"
# The web stand-in offers every web name keys uses, so the benchmark
# needs no server.
cp tests/keys/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (keys-bench))\n(keys-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# The commands plugin's run allocates more than the 2 KB a keystroke may,
# so keys' own share is the gate.
echo "$output" | awk '
  BEGIN {
    limit["item-key"] = 1000
    limit["lookup-key"] = 1000
    limit["lookup-three-keys"] = 3000
    limit["lookup-global"] = 3000
    limit["press-printing-char"] = 10000
    limit["press-two-keys"] = 10000
    limit["batch-ended-one-client"] = 250
    limit["press-bytes-beyond-run"] = 2048; unit["press-bytes-beyond-run"] = "B"
    failed = 0
  }
  $1 == "press-printing-char-bytes" || $1 == "commands-run-bytes" { printf "%-28s %10.2f B\n", $1, $2; next }
  $1 == "bindings" { if ($2 != 1270) { print "bindings: expected 1270, got " $2; failed = 1 }; next }
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
