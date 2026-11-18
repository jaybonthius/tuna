#!/bin/sh
set -eu
tuna=${1:?usage: display-browser.sh TUNA [PORT]}
port=${2:-'(http:free-port)'}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-display-browser.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib"
cp bench/display.sls "$lib/display-bench.sls"
cp bench/scroll-report.sls "$lib/scroll-report.sls"
cp bench/display-browser.sls "$lib/display-browser.sls"
cp bench/display-browser.js "$lib/display-browser.js"
cp tests/web/home/.config/tuna/lib/http.sls "$lib/http.sls"
cat > "$dir/home/.config/tuna/init.ss" <<END
(import (tuna) (tuna plugins) (http))
(use-plugin web (config (set-option! web:port $port)))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin display)
(import (display-browser) (console))
(display-browser:setup! 'text 1)
END
mkfifo "$dir/in"
(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$(dirname "$tuna")/plugins" "$tuna" < "$dir/in" > "$dir/out" 2>&1) &
exec 3> "$dir/in"
echo "folder $dir; Tuna's process is the child of $$; forms go to $dir/in, output to $dir/out"
wait
