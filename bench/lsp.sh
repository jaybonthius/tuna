#!/bin/sh
# Not pinned to one CPU: the server is a second process whose answers the
# completion measure waits for.
set -eu
tuna=${1:?usage: lsp.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-lsp.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/lsp.sls "$lib/lsp-bench.sls"
cp tests/lsp/home/fake-server.ss "$dir/home/"
# The web plugin's stand-in spares the benchmark a server.
cp tests/lsp/home/.config/tuna/lib/web.sls "$lib/web.sls"
cat > "$dir/home/.config/tuna/init.ss" <<'END'
(import (tuna) (plugins))
(use-plugin layout)
(use-plugin editing)
(use-plugin files)
(use-plugin completion)
(use-plugin lsp)
(import (lsp-bench))
(lsp-bench:run)
(exit)
END

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  BEGIN {
    unit["keystroke-plain-us"] = "us"
    unit["keystroke-managed-us"] = "us"
    unit["publish-200-ten-behind-ms"] = "ms"
    unit["didopen-1mb-ms"] = "ms"
    unit["keystroke-after-5000-raw-bytes-us"] = "us"
    unit["completion-5000-ms"] = "ms"
    unit["publish-storm-200-files-ms"] = "ms"
    missing = 0
  }
  $1 in unit {
    seen[$1] = 1
    printf "%-34s %10.2f %s\n", $1, $2, unit[$1]
    next
  }
  { print }
  END {
    for (name in unit) if (!(name in seen)) { printf "%-34s no result\n", name; missing = 1 }
    exit missing
  }'
