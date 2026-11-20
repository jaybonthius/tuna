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
echo "$output" | awk '
  BEGIN {
    split("1 10 100", sizes, " ")
    for (i in sizes) {
      s = "-" sizes[i] "mb"
      unit["insert" s] = "ns"
      unit["snapshot" s] = "ns"
      unit["stop" s] = "ns"
      unit["next-stop" s] = "ns"
      unit["anchor-read" s] = "ns"
      unit["layer-move" s] = "ns"
      unit["travelling" s] = "ns"
      unit["keystroke" s] = "ns"
    }
    split("1 10", structured, " ")
    for (i in structured) {
      s = "-" structured[i] "mb"
      unit["stop-structured" s] = "ns"
      unit["next-stop-structured" s] = "ns"
      unit["keystroke-structured" s] = "ns"
    }
    unit["reconcile-0mb"] = "ms"
    unit["trim-anchors-1mb"] = "ms"
    split("delete-reinsert-start-blocks delete-reinsert-start-text insert-delete-start-blocks delete-reinsert-inside-blocks delete-reinsert-inside-text delete-across-blocks delete-whole-block delete-into-table yank-heading-mid-paragraph", blocks, " ")
    for (i in blocks) unit[blocks[i]] = "ns"
    unit["replace-rows-0mb"] = "ms"
    unit["replace-same-rows-0mb"] = "ms"
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
