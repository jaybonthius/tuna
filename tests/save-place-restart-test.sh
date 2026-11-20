#!/bin/sh
# Places outlast a restart: a killed file's place is save-place's, and a
# file open at exit keeps the last point views saved for it, which an
# older place of save-place's does not replace.
set -eu
tuna=${1:?usage: save-place-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-save-place-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
cp -R plugins/. "$dir/library/"
cp tests/views/home/.config/tuna/lib/web.sls "$home/.config/tuna/lib/"
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$home/a.txt"
printf 'b one\nb two\nb three\n' > "$home/b.txt"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin views)
(use-plugin files)
(use-plugin save-place)
(define (leave! path point)
  (let* ([b (files:visit path)] [v (views:make b)])
    (views:set-point! v point)
    (views:drop! v)
    (buffers:kill! b)))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

output=$(run '(leave! "~/a.txt" 9)
(leave! "~/b.txt" 4)
(define a (files:visit "~/a.txt"))
(define v (views:make a))
(views:set-point! v 20)')
expect "first run" "$output" '#t
#t'

output=$(run '(views:last-point (files:visit "~/b.txt"))
(views:last-point (car (files:buffers)))')
expect "after a restart" "$output" '4
20'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
