#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: views.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
library=$(dirname "$tuna")/plugins
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-views.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/views.sls "$lib/views-bench.sls"
# Until Tuna's own library has the web plugin and the HTML library, the
# test configuration's stand-ins take their place.
for module in web haml; do
  [ -f "$library/$module.sls" ] || cp "tests/views/home/.config/tuna/lib/$module.sls" "$lib/"
done
printf '(import (tuna) (views-bench))\n(views-bench:run)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$library" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
# The server's share of a keystroke is a millisecond: a view of two view
# heights draws in 200 microseconds, and saving the views after a batch
# that moved a cursor takes 50. A view of a node per line reads each
# node's children from its document, about 2 microseconds a node, so it
# draws in more. An edit costs the views of other buffers nothing; a
# walk over a thousand of them would take microseconds.
echo "$output" | awk '
  BEGIN {
    limit["draw-typical"] = 200000
    limit["draw-nodes"] = 550000
    limit["save"] = 50000
    limit["edit-other-views"] = 500
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
