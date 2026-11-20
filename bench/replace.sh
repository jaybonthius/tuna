#!/bin/sh
# Pinned to two CPUs, so that each median compares like with like and a
# key's scan job runs beside the main thread, as it does in use.
set -eu
tuna=${1:?usage: replace.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 2))-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-replace.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/search.sls "$lib/search-bench.sls"
cp bench/replace.sls "$lib/replace-bench.sls"
cp tests/isearch/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (tuna plugins))\n(use-plugin layout)\n(use-plugin editing)\n(use-plugin echo-area)\n(use-plugin minibuffer)\n(use-plugin isearch)\n(use-plugin replace)\n(import (replace-bench))\n(replace-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  $1 ~ /^replace-/ { printf "%-46s %12.3f ms\n", $1, $2; seen[$1] = 1; next }
  { print }
  END { if (length(seen) < 12) { print "missing results"; exit 1 } }'
