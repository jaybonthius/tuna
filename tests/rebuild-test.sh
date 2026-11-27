#!/bin/sh
set -eu
tuna=${1:?usage: rebuild-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-rebuild-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

mkdir -p "$dir/home/.config/tuna/lib" "$dir/library" "$dir/work"
printf '#!tuna\n(define (text name) (string-append "Hello, " name "!"))\n' \
  > "$dir/home/.config/tuna/lib/greet.sls"
printf '(import (tuna) (greet))\n(import (console))\n' > "$dir/home/.config/tuna/init.ss"
sh tests/test-home.sh "$tuna" "$dir/library" "$dir/home"

run() {
  (cd "$dir/work" && echo '(greet:text "Harpo")' |
    HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$1" 2>&1)
}

output=$(run "$tuna")
[ "$output" = '"Hello, Harpo!"' ] || fail "first run printed: $output"
[ -f "$dir/home/.cache/tuna/lib/greet.so" ] || fail "no object file was cached"

# Compiling Tuna again gives each of its libraries a new identity, which
# the cached object of greet was not compiled against.
mkdir "$dir/source"
tar cf - Makefile build.ss boot bin src start plugins lib/chez-lang/src |
  tar xf - -C "$dir/source"
ln -s "$PWD/libraries" "$dir/source/libraries"
make -s -C "$dir/source" exe > "$dir/build.log" 2>&1 || fail "the second build failed: $(cat "$dir/build.log")"

cp "$dir/home/.cache/tuna/lib/greet.so" "$dir/first.so"
output=$(run "$dir/source/build/bin/tuna")
[ "$output" = '"Hello, Harpo!"' ] || fail "the rebuilt Tuna printed: $output"
cmp -s "$dir/first.so" "$dir/home/.cache/tuna/lib/greet.so" &&
  fail "the rebuilt Tuna did not compile greet again"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
