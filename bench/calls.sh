#!/bin/sh
set -eu
tuna=${1:?usage: calls.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
limit_ns=10
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-calls.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"

cat > "$lib/callee.sls" <<'SCHEME'
#!tuna
(define (add1 x) (fx+ x 1))
SCHEME
cat > "$lib/plain.sls" <<'SCHEME'
(library (plain)
  (export increment)
  (import (chezscheme))
  (define (increment x) (fx+ x 1)))
SCHEME
cat > "$lib/caller.sls" <<'SCHEME'
#!tuna
(import (callee) (prefix (plain) plain:))
(define calls 100000000)

(define (time-calls loop)
  (collect)
  (let ([start (current-time 'time-monotonic)])
    (loop calls)
    (let ([elapsed (time-difference (current-time 'time-monotonic) start)])
      (/ (+ (* (time-second elapsed) 1e9) (time-nanosecond elapsed)) calls))))

(define (changeable-loop n)
  (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (callee:add1 acc)))))

(define (plain-loop n)
  (let loop ([i 0] [acc 0]) (if (fx= i n) acc (loop (fx+ i 1) (plain:increment acc)))))

(define (best-of runs loop)
  (apply min (map (lambda (run) (time-calls loop)) (iota runs))))

(define (report-calls)
  (time-calls changeable-loop)
  (printf "changeable ~,2f ns\nplain ~,2f ns\n" (best-of 5 changeable-loop) (best-of 5 plain-loop)))
SCHEME
printf '(import (tuna) (caller))\n(caller:report-calls)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < /dev/null 2>&1)
echo "$output"
changeable=$(echo "$output" | awk '$1 == "changeable" { print $2 }')
[ -n "$changeable" ] || exit 1
awk -v ns="$changeable" -v limit="$limit_ns" 'BEGIN {
  if (ns > limit) { printf "calls: %s ns is over %s ns\n", ns, limit; exit 1 }
}'
