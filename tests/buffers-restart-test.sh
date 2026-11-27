#!/bin/sh
# The order of use outlasts a restart: buffers made again take their
# saved places among those not used since, a buffer the saved order does
# not name goes after them, and a saved name no buffer takes by the first
# idle goes.
set -eu
tuna=${1:?usage: buffers-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-buffers-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna" "$dir/library" "$dir/work"
cp -R plugins/. "$dir/library/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna))
(use-plugin buffers)
(define (names) (map buffers:name (buffers:all)))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

output=$(run '(define made (fold-left (lambda (acc n) (cons (buffers:make n "") acc)) (quote ()) (list "a" "b" "c" " internal")))
(buffers:move-to-front! (buffers:find "b"))
(names)')
expect "first run" "$output" '("b" "a" "c" " internal")'

output=$(run '(define made (fold-left (lambda (acc n) (cons (buffers:make n "") acc)) (quote ()) (list "c" "d" "a" "b")))
(names)')
expect "after a restart" "$output" '("b" "a" "c" "d")'

# A start makes its buffers again before it first idles; the names no
# buffer took back by then go, so the saved order holds no buffer that is
# gone after two restarts.
saved=$home/.local/share/tuna/saved/tuna/buffers/saved-order.ss
output=$(run '(define made (fold-left (lambda (acc n) (cons (buffers:make n "") acc)) (quote ()) (list "a" "b")))
(timers:set-idle! #t)
(timers:sleep 1.5)
(timers:set-idle! #f)
(names)')
expect "a restart that makes only a and b" "$output" '("b" "a")'
expect "the saved order after it" "$(cat "$saved")" '("b" "a")'

output=$(run '(define made (fold-left (lambda (acc n) (cons (buffers:make n "") acc)) (quote ()) (list "a")))
(timers:set-idle! #t)
(timers:sleep 1.5)
(timers:set-idle! #f)
(names)')
expect "a restart that makes only a" "$output" '("a")'
expect "the saved order after two restarts" "$(cat "$saved")" '("a")'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
