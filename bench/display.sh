#!/bin/sh
# The client, the server's threads and the main thread share four CPUs,
# so that each median compares like with like.
set -eu
tuna=${1:?usage: display.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
last=$(($(nproc) - 1))
cpus=${BENCH_CPUS:-$((last - 3))-$last}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-display.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/display.sls "$lib/display-bench.sls"
cp bench/scroll-report.sls "$lib/scroll-report.sls"
cp tests/web/home/.config/tuna/lib/http.sls "$lib/http.sls"
cat > "$dir/home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (http))
(use-plugin web (config (set-option! web:port (http:free-port))))
(use-plugin layout)
(use-plugin layout-split)
(import (display-bench))
(display-bench:run)
(exit)
END

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpus" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["batch-one-client"] = "ns"
    unit["batch-unchanged"] = "ns"
    unit["batch-two-clients"] = "ns"
    unit["batch-four-clients"] = "ns"
    unit["draw-text-one-view"] = "ns"
    unit["draw-text-three-views"] = "ns"
    unit["draw-nodes-one-view"] = "ns"
    unit["draw-nodes-three-views"] = "ns"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-28s %12.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-28s no result\n", name; missing = 1 }
    exit missing
  }'
