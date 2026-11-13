#!/bin/sh
set -eu
tuna=${1:?usage: echo-area-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-echo-area-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp -R tests/echo-area/home/. "$home/"

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

bars='(map (lambda (d) (cdr (assq (quote buffer) (vector-ref d 1)))) (cdddr (tree)))'

# The plugin removes its bar when it unloads at exit, so the layout is
# saved without it, and a restart shows one echo area, not two.
output=$(run "$bars
(echo-area:message! \"Bye\")")
expect "first start" "$output" '(" *Echo Area*")'
saved=$home/.local/share/tuna/saved/tuna/layout/saved-layout.ss
[ -f "$saved" ] || fail "no saved layout at $saved"
! grep -q 'Echo Area' "$saved" || fail "the saved layout holds the echo area's bar"

output=$(run "$bars
(echo-area:current-message)")
expect "restart" "$output" '(" *Echo Area*")
#f'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
