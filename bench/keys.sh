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
echo "$output" | awk '
  BEGIN {
    unit["item-key"] = "ns"
    unit["lookup-key"] = "ns"
    unit["lookup-three-keys"] = "ns"
    unit["lookup-global"] = "ns"
    unit["press-printing-char"] = "ns"
    unit["press-two-keys"] = "ns"
    unit["batch-ended-one-client"] = "ns"
    unit["press-printing-char-bytes"] = "B"
    unit["commands-run-bytes"] = "B"
    unit["press-bytes-beyond-run"] = "B"
    missing = 0
  }
  $1 == "bindings" { printf "%-28s %10d\n", $1, $2; next }
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
