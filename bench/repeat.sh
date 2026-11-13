#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: repeat.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-repeat.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/repeat.sls "$lib/repeat-bench.sls"
# The web stand-in offers every web name keys and repeat use, so the
# benchmark needs no server.
cp tests/keys/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (repeat-bench))\n(repeat-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    limit["press-one-key"] = 10000
    limit["press-two-keys"] = 10000
    limit["repeat-search-one-keymap"] = 500
    limit["repeat-search-24-keymaps"] = 2000
    limit["enter-repeat"] = 10000
    limit["repeated-key"] = 10000
    limit["repeated-key-bytes-beyond-press"] = 1024; unit["repeated-key-bytes-beyond-press"] = "B"
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
