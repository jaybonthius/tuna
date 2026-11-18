#!/bin/sh
set -eu
tuna=${1:?usage: processes-exit-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-processes-exit-test.XXXXXX")
pids=
trap 'for pid in $pids; do kill "$pid" 2>/dev/null || true; done; rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna" "$dir/library" "$dir/work"
sh "$(dirname "$0")/../boot/copy-library.sh" "$(dirname "$tuna")/plugins" "$dir/library"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (processes))
(define on-terminal
  (processes:start-for-user "sleep" '("30") (processes:options [terminal '(24 . 80)])))
(define on-pipes (processes:start-for-user "sleep" '("30")))
(define own (processes:start "sleep" '("30") (lambda (bytes end) #f)))
(let wait ()
  (unless (for-all processes:pid (list on-terminal on-pipes own))
    (sleep-for 0.01)
    (wait)))
(with-output-to-file (string-append (getenv "HOME") "/pids")
  (lambda () (for-each (lambda (p) (display (processes:pid p)) (newline)) (list on-terminal on-pipes own))))
(exit)
END

output=$(cd "$dir/work" && HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" < /dev/null 2>&1)
[ -z "$output" ] || fail "Tuna wrote: $output"
pids=$(cat "$home/pids")
set -- $pids

alive() {
  kill -0 "$1" 2>/dev/null
}

# A quit signals no user process. The kernel hangs up a terminal's session
# when Tuna's end closes; a program on pipes that neither reads nor
# writes goes on running. An own process stops as its owner unloads.
gone_within_a_second() {
  n=0
  while alive "$1" && [ $n -lt 100 ]; do sleep 0.01; n=$((n + 1)); done
  ! alive "$1"
}
gone_within_a_second "$1" || fail "the user process on a terminal outlived Tuna"
alive "$2" || fail "the user process on pipes ended with Tuna"
gone_within_a_second "$3" || fail "the own process outlived Tuna"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
