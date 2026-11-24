#!/bin/sh
# A quit that lands in work after a batch is reported, as the core reports
# one, so the reports of quits are left out of what is compared.
set -eu
tuna=${1:?usage: layout-scroll-float-races-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-scroll-float-races-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/home" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$dir/home"
cp -RL tests/scroll-float/home/. "$dir/home/"
cat > "$dir/input" <<'END'
(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))
(define notes (buffers:make "notes" (lines "n" 80)))
(define completions (buffers:make "*completions*" "one\ntwo\n"))
(define question (buffers:make "*question*" "?\n"))
(define client (web:add-client! 1))
(define phone (web:add-client! 2))
(set-parts! (layout-scroll:container '() (atom (views:make notes)) (atom (views:make notes)) (layout-float:container '() (atom (views:make notes)))))
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
(define (atom-ids d)
    (if (vector? d) (list (cdr (assq 'view (vector-ref d 1)))) (apply append (map atom-ids (cddr d)))))
(define (popups) (car (document:datums (buffers:document layout:popups-buffer))))
(define (pick ls k) (list-ref ls (mod k (length ls))))
(define (attempt thunk) (guard (c [(not (quit-condition? c)) #f]) (thunk)))
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
            (let* ([shown (layout:views)] [selected (layout:selected-view)] [many? (> (length (atom-ids (tree))) 10)])
              (attempt
                (lambda ()
                  (case (mod k 16)
                    [(0) (if many? (layout:delete-part! (layout:view-node (pick shown k))) (layout-scroll:display-in-new-column notes))]
                    [(1) (layout-scroll:consume)]
                    [(2) (layout-scroll:expel)]
                    [(3) (if (even? k) (layout-scroll:consume-or-expel-left) (layout-scroll:consume-or-expel-right))]
                    [(4) (layout-scroll:cycle-size)]
                    [(5) (layout-scroll:full-size)]
                    [(6) (layout:screen client) (layout:screen phone)]
                    [(7) (strip-report! client (map views:id shown) (views:id (pick shown k)) "start" (views:id (pick shown k)))]
                    [(8) (layout-float:toggle)]
                    [(9) (layout-float:cycle)]
                    [(10) (let ([palettes (views:showing question)])
                            (layout-float:show-at! (if (and (odd? k) (pair? palettes)) (car palettes) (pick shown k))
                                                   1 completions 1/2 '(lines 4)))]
                    [(11) (let ([p (find (lambda (v) (eq? (views:buffer v) completions)) (views:showing completions))])
                            (when p (layout-float:close! p)))]
                    [(12) (layout:select! (layout-float:display-palette question))]
                    [(13) (layout:other-view)]
                    [(14) (if (even? k) (layout-scroll:first) (layout-scroll:last))]
                    [else (layout:select! (pick shown (* k 7)))]))))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless stopped (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1)))))))
(begin
    (stress (+ (real-time) 2000))
    (> quits 100))
(define (parts-only? d)
    (or (and (vector? d) (eq? (vector-ref d 0) 'views:view) (fixnum? (cdr (assq 'view (vector-ref d 1)))))
        (and (pair? d) (pair? (cddr d)) (for-all parts-only? (cddr d)))))
(define (ids-once? ids) (or (null? ids) (and (not (memv (car ids) (cdr ids))) (ids-once? (cdr ids)))))
(and (parts-only? (tree)) (for-all parts-only? (cddr (popups))) (ids-once? (append (atom-ids (tree)) (apply append (map atom-ids (cddr (popups)))))))
(let ([v (layout:selected-view)]) (and (or (layout:view-node v) (memv (views:id v) (apply append (map atom-ids (cddr (popups)))))) #t))
(for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (append (atom-ids (tree)) (apply append (map atom-ids (cddr (popups))))))
(and (string? (html->string (layout:screen client))) (string? (html->string (layout:screen phone))))
(define before (list (tree) (popups) (views:id (layout:selected-view)) (map views:id (layout:views))))
(import (tuna eval))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/layout-scroll.sls"))
(equal? before (list (tree) (popups) (views:id (layout:selected-view)) (map views:id (layout:views))))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/layout-float.sls"))
(and (equal? (car before) (tree)) (equal? (popups) '(layout:popups-root ())))
(set! before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/layout.sls"))
(equal? before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
(string? (html->string (layout:screen client)))
END
output=$(cd "$dir/work" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" 2>&1 |
  grep -v -E '^! (\([a-z-]+\) )?&quit$' || true)
expected='#t
#t
#t
#t
#t
#t
#t
#t
#t'
if [ "$output" != "$expected" ]; then
  echo "$0: FAIL: expected $(printf '%s' "$expected" | tr '\n' '|'), got $(printf '%s' "$output" | tr '\n' '|')"
  exit 1
fi
echo "$0: 0 failures"
