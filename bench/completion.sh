#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: completion.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-completion.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/completion.sls "$lib/completion-bench.sls"
# The web plugin's stand-in spares the benchmark a server.
cp tests/echo-area/home/.config/tuna/lib/web.sls "$lib/web.sls"
printf '(import (tuna) (completion-bench))\n(completion-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# Each prompt the benchmark ends with C-g reports a quit, and is meant
# to; a quit that cut a measurement short still shows, as a missing
# result.
echo "$output" | awk '
  BEGIN {
    unit["read-key-900-names"] = "ns"
    unit["session-start-100000-paths-main-thread"] = "µs"
    unit["read-key-100000-paths-main-thread"] = "ns"
    unit["read-key-100000-paths-to-matches"] = "µs"
    unit["job-16000-emissions-main-thread"] = "µs"
    unit["match-100000-paths-substring"] = "µs"
    unit["match-100000-paths-flex"] = "µs"
    unit["match-100000-names-substring"] = "µs"
    unit["store-100000-paths"] = "µs"
    unit["match-inline-limit-flex"] = "µs"
    unit["draw-prompt-with-15-rows"] = "µs"
    unit["echo-area-hidden-during-prompt"] = "ns"
    unit["draw-prompt-with-message"] = "µs"
    unit["draw-m-x-annotated"] = "µs"
    unit["m-x-key"] = "µs"
    unit["line-start-1mb-main-thread"] = "µs"
    unit["line-matches-1mb"] = "µs"
    unit["point-key-popup-open"] = "µs"
    missing = 0
  }
  $0 == "! &cancelled" { next }
  $1 in unit {
    seen[$1] = 1
    printf "%-40s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-40s no result\n", name; missing = 1 }
    exit missing
  }'
