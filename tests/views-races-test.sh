#!/bin/sh
# Quits requested every millisecond land in cursor moves, folds, edits,
# two clients' scroll reports, draws and removals on the main thread, and leave every view
# whole: found by its number, showing a live buffer, with each cursor at
# a stop inside its bounds, and drawing; the view drawn from an atom
# comes back from saved data as it is. A quit that lands in a hook entry
# or in work after a batch is reported, as the core reports one, so the
# reports of quits are left out of what is compared.
set -eu
tuna=${1:?usage: views-races-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-views-races-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/home" "$dir/library" "$dir/work"
cp -R tests/views/home/. "$dir/home/"
cp -R plugins/. "$dir/library/"
cat > "$dir/input" <<'END'
(import (md) (rename (only (chezscheme) sleep) (sleep chez:sleep)))
(define text (buffers:make "text" (lines 400)))
(define layout (buffers:make "*layout*" (md:doc '() (views:view '((view . 50) (buffer . "text"))))))
(define atom (views:atom-view (document:token (buffers:document layout) 1)))
(define plain (views:make text))
(define all (list atom plain))
(define quitting #t)
(define stopped #f)
(define quits 0)
(define (quitter)
    (let loop ()
      (if quitting
          (begin
            (request-quit!)
            (chez:sleep (make-time 'time-duration 1000000 0))
            (loop))
          (set! stopped #t))))
(define forked #f)
; A quit lands up to a thousand calls after its request, and the
; quitter's last request may come after the stress ends. One guard
; holds from before the quitter starts until long after it stops,
; since a quit landing between two guards would end the form. Quits
; land at least a thousand calls apart, so none lands in the handler
; before it enters the guard again.
(define (stress until)
    (let again ()
      (guard (c [(quit-condition? c) (set! quits (+ quits 1)) (again)])
        (unless forked
          (set! forked #t)
          (fork-thread quitter))
        (let loop ([k 0])
          (when (< (real-time) until)
            (let* ([v (list-ref all (mod k 2))]
                   [size (document:length (buffers:document text))]
                   [p (+ 1 (mod (* k 7919) (- size 2)))])
              (case (mod k 9)
                [(0) (views:set-point! v p)]
                [(1) (buffers:replace! text p p "abcdef\n")]
                [(2) (views:fold! v p (min (- size 1) (+ p 30)))]
                [(3) (views:unfold! v p)]
                [(4) (report! (if (even? k) desktop phone) v (+ 1 (mod k 300)) (mod k 7) (odd? (quotient k 9)))]
                [(5) (if (null? (cdr (views:cursors v))) (views:add-cursor! v p) (views:remove-cursor! v (cadr (views:cursors v))))]
                [(6) (buffers:replace! text p (min (- size 1) (+ p 5)) "")]
                [(7) (views:scroll-to! v p (views:align center)) (when (zero? (mod k 63)) (web:client-removed phone))]
                [else (views:draw v (if (even? k) desktop phone))])
              (loop (+ k 1)))))
        (set! quitting #f)
        (let spin () (unless stopped (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1)))))))
(begin
    (stress (+ (real-time) 2000))
    (> quits 100))
(for-all (lambda (v) (and (eq? (views:find (views:id v)) v) (eq? (views:buffer v) text))) all)
(for-all
    (lambda (v)
      (let-values ([(lo hi) (views:bounds v)])
        (for-all (lambda (c) (let ([p (views:cursor-point c)]) (and (<= lo p hi) (eqv? (buffers:stop text p) p))))
                 (views:cursors v))))
    all)
(for-all (lambda (v) (string? (html->string (views:draw v desktop)))) all)
(define before (list (views:point atom) (map views:cursor-point (views:cursors atom))))
(import (tuna eval))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/views.sls"))
(equal? before (let ([v (views:find 50)]) (list (views:point v) (map views:cursor-point (views:cursors v)))))
END
output=$(cd "$dir/work" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" 2>&1 |
  grep -v -E '^! (\(views\) )?&quit$' || true)
expected='#t
#t
#t
#t
#t'
if [ "$output" != "$expected" ]; then
  echo "$0: FAIL: expected $(printf '%s' "$expected" | tr '\n' '|'), got $(printf '%s' "$output" | tr '\n' '|')"
  exit 1
fi
echo "$0: 0 failures"
