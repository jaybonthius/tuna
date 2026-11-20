#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: occur.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-occur.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/search.sls "$lib/search-bench.sls"
cp bench/occur.sls "$lib/occur-bench.sls"
cp tests/isearch/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (tuna plugins))\n(use-plugin layout)\n(use-plugin editing)\n(use-plugin echo-area)\n(use-plugin minibuffer)\n(use-plugin isearch)\n(use-plugin occur)\n(import (occur-bench))\n(occur-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  $1 ~ /^occur-/ { printf "%-46s %12.3f ms\n", $1, $2; seen[$1] = 1; next }
  { print }
  END { if (length(seen) < 24) { print "missing results"; exit 1 } }'
