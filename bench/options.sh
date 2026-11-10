#!/bin/sh
set -eu
tuna=${1:?usage: options.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-options.XXXXXX")
trap 'rm -rf "$dir"' EXIT
lib=$dir/home/.config/tuna/lib
mkdir -p "$lib" "$dir/library"

# Each scope holds twenty other options' local values, as in a buffer
# whose modes set many options.
cat > "$lib/opts.sls" <<'SCHEME'
#!tuna
(define-option column 70 fixnum?)
(define-option o0 0 fixnum?) (define-option o1 0 fixnum?) (define-option o2 0 fixnum?)
(define-option o3 0 fixnum?) (define-option o4 0 fixnum?) (define-option o5 0 fixnum?)
(define-option o6 0 fixnum?) (define-option o7 0 fixnum?) (define-option o8 0 fixnum?)
(define-option o9 0 fixnum?) (define-option o10 0 fixnum?) (define-option o11 0 fixnum?)
(define-option o12 0 fixnum?) (define-option o13 0 fixnum?) (define-option o14 0 fixnum?)
(define-option o15 0 fixnum?) (define-option o16 0 fixnum?) (define-option o17 0 fixnum?)
(define-option o18 0 fixnum?) (define-option o19 0 fixnum?)
(define others (list o0 o1 o2 o3 o4 o5 o6 o7 o8 o9 o10 o11 o12 o13 o14 o15 o16 o17 o18 o19))

(define (ns-per thunk n)
  (collect)
  (let ([start (current-time 'time-monotonic)])
    (thunk)
    (let ([elapsed (time-difference (current-time 'time-monotonic) start)])
      (/ (+ (* (time-second elapsed) 1e9) (time-nanosecond elapsed)) n))))

(define (best-of runs thunk n)
  (apply min (map (lambda (run) (ns-per thunk n)) (iota runs))))

;; Counts are written in place: a module's top-level definition is
;; changeable, and reading one in the loop would be measured too.
(define (read-loop)
  (let loop ([i 0] [acc 0]) (if (fx= i 50000000) acc (loop (fx+ i 1) (fx+ acc (column))))))

(define (bind-loop)
  (let loop ([i 0] [acc 0])
    (if (fx= i 5000000) acc (loop (fx+ i 1) (with-options ([column i]) (fx+ acc 1))))))

(define (scope-with-others local?)
  (let ([s (make-scope)])
    (parameterize ([current-scope s])
      (for-each (lambda (o) (set-option-local! o 1)) others)
      (when local? (set-option-local! column 100)))
    s))

(define (report-options)
  (printf "outside ~,2f ns\n" (best-of 5 read-loop 50000000))
  (let ([s (scope-with-others #t)])
    (printf "local ~,2f ns\n"
      (best-of 5 (lambda () (parameterize ([current-scope s]) (read-loop))) 50000000)))
  (let ([s (scope-with-others #f)])
    (printf "inside ~,2f ns\n"
      (best-of 5 (lambda () (parameterize ([current-scope s]) (read-loop))) 50000000)))
  (printf "bound ~,2f ns\n"
    (best-of 5 (lambda () (with-options ([column 1]) (read-loop))) 50000000))
  (printf "with-options ~,2f ns\n" (best-of 5 bind-loop 5000000)))
SCHEME
printf '(import (tuna) (opts))\n(opts:report-options)\n' > "$dir/home/.config/tuna/init.ss"

output=$(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < /dev/null 2>&1)
echo "$output"
echo "$output" | awk '
  $1 == "outside" { outside = $2 }
  $1 == "local" { local = $2 }
  $1 == "inside" { inside = $2 }
  $1 == "with-options" { binding = $2 }
  END {
    failed = 0
    if (outside == "" || local == "" || inside == "" || binding == "") { print "options: no result"; exit 1 }
    if (outside > 4) { printf "options: a read outside a scope, %s ns, is over 4 ns\n", outside; failed = 1 }
    if (local > 25) { printf "options: a read in a scope, %s ns, is over 25 ns\n", local; failed = 1 }
    if (inside > 25) { printf "options: a read in a scope, %s ns, is over 25 ns\n", inside; failed = 1 }
    if (binding > 150) { printf "options: with-options, %s ns, is over 150 ns\n", binding; failed = 1 }
    exit failed
  }'
