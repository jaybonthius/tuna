#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: document.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-document.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/document.sls "$lib/document-bench.sls"
printf '(import (tuna) (document-bench))\n(document-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    split("1 10 100", sizes, " ")
    for (i in sizes) {
      s = "-" sizes[i] "mb"
      limit["insert" s] = 3000
      limit["snapshot" s] = 6000
      limit["line" s] = 2000
      limit["line-start" s] = 2000
      limit["char-offset" s] = 1000
      limit["char-position" s] = 1000
      limit["token" s] = 1000
      limit["from-utf8" s] = 3.2; unit["from-utf8" s] = "ms/MB"
      limit["from-datum" s] = 6; unit["from-datum" s] = "ms/MB"
      limit["utf8-chunks" s] = 0.64; unit["utf8-chunks" s] = "ms/MB"
    }
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    u = ($1 in unit) ? unit[$1] : "ns"
    printf "%-24s %10.2f %-5s  limit %7.2f %-5s  %s\n", $1, $2, u, limit[$1], u, verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-24s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
