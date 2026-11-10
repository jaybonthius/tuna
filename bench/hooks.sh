#!/bin/sh
set -eu
tuna=${1:?usage: hooks.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-hooks.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"

cat > "$lib/hooked.sls" <<'SCHEME'
#!tuna
(define-hook after-change)

(define (ns-per-entry thunk)
  (collect)
  (let ([start (current-time 'time-monotonic)])
    (thunk)
    (let ([elapsed (time-difference (current-time 'time-monotonic) start)])
      (/ (+ (* (time-second elapsed) 1e9) (time-nanosecond elapsed)) 10000000))))

;; Counts are written in place: a module's top-level definition is
;; changeable, and reading one in the loop would be measured too.
(define (call-loop)
  (let loop ([i 0]) (unless (fx= i 1000000) (after-change i) (loop (fx+ i 1)))))

(define (best-of runs thunk)
  (apply min (map (lambda (run) (ns-per-entry thunk)) (iota runs))))

(define (report-hooks)
  (printf "entry ~,2f ns\n" (best-of 5 call-loop)))

;; The entries are the module's, and the configuration calls the hook, so
;; each entry runs on behalf of another owner than the caller. Each closes
;; over i, so that they are ten procedures and not one added ten times.
(for-each (lambda (i) (add-hook! after-change (lambda (n) (fx+ n i)) i))
          (iota 10))
SCHEME
printf '(import (tuna) (hooked))\n(hooked:report-hooks)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < /dev/null 2>&1)
echo "$output"
entry=$(echo "$output" | awk '$1 == "entry" { print $2 }')
[ -n "$entry" ] || exit 1
awk -v ns="$entry" 'BEGIN {
  if (ns > 200) { printf "hooks: %s ns per entry is over 200 ns\n", ns; exit 1 }
}'
