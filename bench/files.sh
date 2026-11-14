#!/bin/sh
# Pinned to one CPU, so that each sample compares like with like.
set -eu
tuna=${1:?usage: files.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-files.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/files.sls "$lib/files-bench.sls"
cp tests/files/home/.config/tuna/lib/web.sls "$lib/"
printf '(import (tuna) (files-bench))\n(files-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["read-1mb-job-ms"] = "ms"
    unit["save-1mb-job-ms"] = "ms"
    unit["visit-1mb-main-us"] = "us"
    unit["visit-open-us"] = "us"
    unit["save-1mb-main-us"] = "us"
    unit["revert-1mb-main-us"] = "us"
    unit["modified?-ns"] = "ns"
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
