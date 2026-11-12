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
cp tests/web/home/.config/tuna/lib/http.sls "$lib/http.sls"
cat > "$dir/home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin web (config (set-option! web:port 19398)))
(use-plugin layout)
(use-plugin split)
(use-plugin display)
(import (display-bench))
(display-bench:run)
(exit)
END

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpus" "$tuna" < /dev/null 2>&1)
# The server's share of a keystroke is a millisecond with one client and
# two with four. A view keeps two view heights drawn beyond each edge,
# about 340 lines for a view 45 lines high, so three views draw about
# 650 lines, not the 270 that a client's 0.7 ms was meant for, and their
# limit allows for that. Node-per-line drawing is views' cost and is
# shown, not gated.
echo "$output" | awk '
  BEGIN {
    limit["batch-one-client"] = 1000000
    limit["batch-unchanged"] = 1000000
    limit["batch-two-clients"] = 2000000
    limit["batch-four-clients"] = 2000000
    limit["draw-text-one-view"] = 700000
    limit["draw-text-three-views"] = 1500000
    failed = 0
  }
  $1 in limit {
    seen[$1] = 1
    verdict = ($2 <= limit[$1]) ? "pass" : "FAIL"
    if (verdict == "FAIL") failed = 1
    printf "%-28s %12.2f ns  limit %10.2f ns  %s\n", $1, $2, limit[$1], verdict
    next
  }
  { print }
  END {
    for (name in limit) if (!(name in seen)) { printf "%-28s no result  FAIL\n", name; failed = 1 }
    exit failed
  }'
