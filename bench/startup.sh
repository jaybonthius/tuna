#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: startup.sh TUNA SCHEME}
scheme=${2:?usage: startup.sh TUNA SCHEME}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
runs=9
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-startup.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/library"

start() {
  t0=$(date +%s%N)
  output=$(cd "$dir" && HOME="$dir/$1" TUNA_LIBRARY="$dir/library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
  t1=$(date +%s%N)
  case $output in
    configured-ms*) ;;
    *) echo "startup: $output"; exit 1 ;;
  esac
  echo "$output" | awk -v process=$(( (t1 - t0) / 1000000 )) '{ print $2, process }'
}

median() {
  sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

for shape in few all; do
  "$scheme" -q --script bench/generate.ss "$dir/$shape" "$shape"
  cold=$(start "$shape")
  : > "$dir/warm"
  i=0
  while [ $i -lt $runs ]; do
    start "$shape" >> "$dir/warm"
    i=$((i + 1))
  done
  warm=$(cut -d' ' -f2 "$dir/warm" | median)
  echo "$shape: cold $(echo "$cold" | awk '{ print $1 " ms (process " $2 " ms)" }');" \
    "warm median $(cut -d' ' -f1 "$dir/warm" | median) ms (process $warm ms) of $runs"
done
