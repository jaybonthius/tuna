#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
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
    limit["read-1mb-job-ms"] = 8; unit["read-1mb-job-ms"] = "ms"
    limit["save-1mb-job-ms"] = 25; unit["save-1mb-job-ms"] = "ms"
    limit["visit-1mb-main-us"] = 100; unit["visit-1mb-main-us"] = "us"
    limit["visit-open-us"] = 100; unit["visit-open-us"] = "us"
    limit["save-1mb-main-us"] = 100; unit["save-1mb-main-us"] = "us"
    limit["revert-1mb-main-us"] = 1000; unit["revert-1mb-main-us"] = "us"
    limit["modified?-ns"] = 100; unit["modified?-ns"] = "ns"
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-28s %10.2f %-3s  limit %8.2f %-3s  %s\n", $1, $2, unit[$1], limit[$1], unit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
