#!/bin/sh
# Compiling Tuna again gives each of its libraries a new identity, so a
# user's module that one build compiled into the cache must be compiled
# again by the next: loading the old object would fail.
set -eu
tuna=$PWD/build/bin/tuna
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-check-rebuild.XXXXXX")
trap 'rm -rf "$dir"' EXIT
home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/work"
printf '#!tuna\n(define (text name) (string-append "Hello, " name "!"))\n' > "$home/.config/tuna/lib/greet.sls"
printf '(import (tuna) (greet))\n(import (console))\n' > "$home/.config/tuna/init.ss"

run() {
  (cd "$dir/work" && echo '(greet:text "Harpo")' |
    HOME="$home" env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME timeout 120 "$tuna" 2>&1)
}

output=$(run)
[ "$output" = '"Hello, Harpo!"' ] || { echo "check-rebuild: the first build printed: $output" >&2; exit 1; }
cp "$home/.cache/tuna/lib/greet.so" "$dir/first.so"

rm -rf build/obj build/boot
${MAKE:-make} -s exe > "$dir/build.log" 2>&1 || { cat "$dir/build.log" >&2; exit 1; }

output=$(run)
[ "$output" = '"Hello, Harpo!"' ] || { echo "check-rebuild: the rebuilt Tuna printed: $output" >&2; exit 1; }
if cmp -s "$dir/first.so" "$home/.cache/tuna/lib/greet.so"; then
  echo "check-rebuild: the rebuilt Tuna did not compile greet again" >&2
  exit 1
fi
echo "check-rebuild: ok"
