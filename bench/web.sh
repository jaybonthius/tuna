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
# Budgets for one keystroke with one client on loopback: the server and
# network share of key to screen, the bytes a screen costs after the
# first, and what each client holds.
echo "$output" | awk '
  BEGIN {
    limit["item-json"] = 5000; unit["item-json"] = "ns"
    limit["post-to-204"] = 50; unit["post-to-204"] = "us"
    limit["key-to-screen"] = 2000; unit["key-to-screen"] = "us"
    limit["screen-bytes"] = 2048; unit["screen-bytes"] = "B"
    limit["quit"] = 2000; unit["quit"] = "us"
    limit["reopen"] = 5000; unit["reopen"] = "us"
    limit["send-screen"] = 10000; unit["send-screen"] = "ns"
    limit["send-screen-equal"] = 10000; unit["send-screen-equal"] = "ns"
    limit["client-memory"] = 100; unit["client-memory"] = "KB"
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
