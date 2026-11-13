#!/bin/sh
set -eu
tuna=${1:?usage: modes-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-modes-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp -R tests/modes/library/. "$dir/library/"
cp -R tests/modes/home/. "$home/"
printf 'print(1)\n' > "$dir/work/a.py"
printf 'Buy milk.\n' > "$dir/work/b.txt"

run() {
  input=$1
  shift
  (cd "$dir/work" && printf '%s\n' "$input" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" "$@" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

wait='(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(wait-until (lambda () (= (length (files:buffers)) 2)))'

# Files on the command line get their modes as they are visited.
output=$(run "$wait
(map modes:major-mode (files:buffers))
(modes:set-major-mode text:mode (car (files:buffers)))
(map modes:major-mode (files:buffers))" a.py b.txt)
expect "first start" "$output" '(python:mode text:mode)
(text:mode text:mode)'

# A restart visits the files again and chooses their modes again: a
# mode set by hand lasts only for the process.
output=$(run "$wait
(map modes:major-mode (files:buffers))")
expect "restart" "$output" '(python:mode text:mode)'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
