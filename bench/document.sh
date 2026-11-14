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
      unit["insert" s] = "ns"
      unit["snapshot" s] = "ns"
      unit["line" s] = "ns"
      unit["line-start" s] = "ns"
      unit["char-offset" s] = "ns"
      unit["char-position" s] = "ns"
      unit["token" s] = "ns"
      unit["from-utf8" s] = "ms/MB"
      unit["from-datum" s] = "ms/MB"
      unit["utf8-chunks" s] = "ms/MB"
    }
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-24s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-24s no result\n", name; missing = 1 }
    exit missing
  }'
