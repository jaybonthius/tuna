#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: modes.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-modes.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/modes.sls "$lib/modes-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/modes/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (modes-bench))\n(modes-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
