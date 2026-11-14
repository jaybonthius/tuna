#!/bin/sh
set -eu
tuna=${1:?usage: tick.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-tick.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"

# Each turn of the loop is one timer tick, so the loop ticks a million times
# per thousand million turns. Turning the timer off, which Tuna withholds
# from modules, leaves Chez's own event checks, so the difference is what
# tick and the quit check cost.
cat > "$lib/ticker.sls" <<'SCHEME'
#!tuna
(import (rename (only (chezscheme) set-timer) (set-timer chez:set-timer)))
(define turns 1000000000)

(define (spin n)
  (let loop ([i 0]) (if (fx= i n) i (loop (fx+ i 1)))))

(define (seconds thunk)
  (collect)
  (let ([start (current-time 'time-monotonic)])
    (thunk)
    (let ([elapsed (time-difference (current-time 'time-monotonic) start)])
      (+ (time-second elapsed) (/ (time-nanosecond elapsed) 1e9)))))

(define (best-of runs thunk)
  (apply min (map (lambda (run) (seconds thunk)) (iota runs))))

(define (report-ticks)
  (let* ([on (best-of 9 (lambda () (spin turns)))]
         [off (best-of 9 (lambda ()
                           (let ([ticks (chez:set-timer 0)])
                             (spin turns)
                             (chez:set-timer ticks))))]
         [per-tick (* 1e9 (/ (- on off) (/ turns 1000)))])
    (printf "tick ~,1f ns per tick (~,3f s with the timer, ~,3f s without, ~a turns)\n"
      per-tick on off turns)))
SCHEME
printf '(import (tuna) (ticker))\n(ticker:report-ticks)\n(exit)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < /dev/null 2>&1)
echo "$output" | awk '
  { print }
  $1 == "tick" { seen = 1 }
  END { if (!seen) { print "tick no result"; exit 1 } }'
