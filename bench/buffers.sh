#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: buffers.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-buffers.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/buffers.sls "$lib/buffers-bench.sls"
printf '(import (tuna) (buffers-bench))\n(buffers-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# A keystroke's share of the server's millisecond. A stop in a buffer of
# nodes looks up the node around it and that node's parent, which
# together cost more than the two microseconds that a file buffer's stop
# takes.
echo "$output" | awk '
  BEGIN {
    split("1 10 100", sizes, " ")
    for (i in sizes) {
      s = "-" sizes[i] "mb"
      limit["insert" s] = 5000
      limit["snapshot" s] = 6000
      limit["stop" s] = 2000
      limit["next-stop" s] = 2000
      limit["anchor-read" s] = 100
      limit["layer-move" s] = 1500
      limit["travelling" s] = 2500
      limit["keystroke" s] = 12000
    }
    split("1 10", structured, " ")
    for (i in structured) {
      s = "-" structured[i] "mb"
      limit["stop-structured" s] = 4000
      limit["next-stop-structured" s] = 4000
      limit["keystroke-structured" s] = 12000
    }
    limit["reconcile-0mb"] = 1; unit["reconcile-0mb"] = "ms"
    limit["trim-anchors-1mb"] = 5; unit["trim-anchors-1mb"] = "ms"
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
