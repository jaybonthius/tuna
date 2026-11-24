#!/bin/sh
set -eu
tuna=${1:?usage: eval-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-eval-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home" "$dir/library" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$home"
cp -RL tests/eval/home/. "$home/"

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# M-:'s history is saved data, so it outlives Tuna.
output=$(run '(eval! "(+ 1 2)")
(message)')
expect "first start" "$output" '#t
"3"'

output=$(run '(define t (start! "M-:"))
(press! "M-p")
(input)
(press! "C-g")')
expect "restart" "$output" '"(+ 1 2)"
! &quit'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
