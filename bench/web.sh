#!/bin/sh
# The client, the server's threads and the main thread share four CPUs,
# so that each median compares like with like.
set -eu
tuna=${1:?usage: web.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
last=$(($(nproc) - 1))
cpus=${BENCH_CPUS:-$((last - 3))-$last}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-web.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/web.sls "$lib/web-bench.sls"
cat > "$dir/home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin web (config (set-option! web:port 19399)))
(import (web-bench))
(web-bench:run)
(exit)
END

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpus" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["item-json"] = "ns"
    unit["post-to-204"] = "us"
    unit["key-to-screen"] = "us"
    unit["key-to-screen-p99"] = "us"
    unit["screen-bytes"] = "B"
    unit["screen-bytes-max"] = "B"
    unit["quit"] = "us"
    unit["reopen"] = "us"
    unit["send-screen"] = "ns"
    unit["send-screen-equal"] = "ns"
    unit["client-memory"] = "KB"
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
