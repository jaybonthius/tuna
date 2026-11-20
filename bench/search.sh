#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: search.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-search.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/search.sls "$lib/search-bench.sls"
cp tests/echo-area/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (search-bench))\n(search-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  $1 ~ /^(step|scan)-/ { printf "%-46s %12.3f ms\n", $1, $2; seen[$1] = 1; next }
  { print }
  END { if (length(seen) < 21) { print "missing results"; exit 1 } }'
