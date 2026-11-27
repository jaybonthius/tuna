#!/bin/sh
# A quit that lands in work after a batch is reported, as the core reports
# one, so the reports of quits are left out of what is compared.
set -eu
tuna=${1:?usage: part-mode-races-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-part-mode-races-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/home" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$dir/home"
cp -RL tests/part-mode/home/. "$dir/home/"
mkdir -p "$dir/home/.config/tuna/lib"
cp -R tests/modules/. "$dir/home/.config/tuna/lib/"
cat > "$dir/input" <<'END'
(import (testing))
(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))
(define notes (buffers:make "notes" "one\ntwo\n"))
(define client (web:add-client! 1))
(define (fresh) (views:make notes))
(define side (buffers:make "side" ""))
(set-parts! (layout-split:container '((direction . row)) (atom (fresh)) (layout-scroll:container '() (atom (fresh)) (layout-split:container '((direction . column)) (atom (fresh)) (atom (fresh)))) (layout-float:container '() (atom (fresh)))))
(layout:part-mode)
(define quitting #t)
(define stopped #f)
(define quits 0)
(define (quitter)
    (let loop ()
      (if quitting
          (begin
            (testing:request-quit!)
            (chez:sleep (make-time 'time-duration 1000000 0))
            (loop))
          (set! stopped #t))))
(define (atom-ids d)
    (if (vector? d) (list (cdr (assq 'view (vector-ref d 1)))) (apply append (map atom-ids (cddr d)))))
(define (attempt thunk) (guard (c [(not (cancelled? c)) #f]) (thunk)))
(define forked #f)
; A quit lands up to a thousand calls after its request, and the
; quitter's last request may come after the stress ends. One guard
; holds from before the quitter starts until long after it stops,
; since a quit landing between two guards would end the form. Quits
; land at least a thousand calls apart, so none lands in the handler
; before it enters the guard again.
(define (stress until)
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
        (unless forked
          (set! forked #t)
          (fork-task (lambda (restore) (quitter))))
        (let loop ([k 0])
          (when (< (real-time) until)
            (attempt
              (lambda ()
                (case (mod k 20)
                  [(0) (layout:select-parent)]
                  [(1) (layout:select-child)]
                  [(2) (layout:select-previous)]
                  [(3) (layout:select-next)]
                  [(4) (layout:shift-backward)]
                  [(5) (layout:shift-forward)]
                  [(6) (layout:lift)]
                  [(7) (layout:lower)]
                  [(8) (if (> (length (atom-ids (main))) 3) (layout:raise) (layout-split:split-right))]
                  [(9) (layout:splice)]
                  [(10) (if (> (length (atom-ids (main))) 3) (layout:delete-view) (layout-scroll:display-in-new-column notes))]
                  [(11) (case (mod k 4)
                          [(0) (layout-split:wrap-in-row)]
                          [(1) (layout-tabs:wrap-in-tabs)]
                          [(2) (layout-scroll:wrap-in-strip)]
                          [else (layout-float:wrap-in-float)])]
                  [(12) (layout:wrap-in-level)]
                  [(13) (case (mod k 4)
                          [(0) (layout:zoom (if (even? (div k 4)) #f '(4)))]
                          [(1) (layout:other-view)]
                          [(2) ((layout-split:display-at-side (layout:direction left) 50 '(columns 20)) side)]
                          [else (let ([v (layout:find-view side)]) (when v (layout:delete-part! (layout:view-node v))))])]
                  [(14) (layout:screen client)]
                  [(15) (layout:part-mode-leave) (layout:part-mode)]
                  [(16) (layout-split:split-below)]
                  [(17) (layout:select-first)]
                  [(18) (layout:select-last)]
                  [else (batch-ended)])))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless stopped (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1)))))))
(begin
    (stress (+ (real-time) 2000))
    (batch-ended)
    (> quits 100))
(define (parts-only? d)
    (or (and (vector? d) (eq? (vector-ref d 0) 'views:view) (fixnum? (cdr (assq 'view (vector-ref d 1)))))
        (and (pair? d) (pair? (cddr d)) (for-all parts-only? (cddr d))
             (or (not (eq? (car d) 'layout:level))
                 (and (null? (cdddr d)) (not (and (pair? (caddr d)) (eq? (car (caddr d)) 'layout:level))))))))
(define (ids-once? ids) (or (null? ids) (and (not (memv (car ids) (cdr ids))) (ids-once? (cdr ids)))))
(and (parts-only? (tree)) (ids-once? (atom-ids (tree))))
(for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (atom-ids (tree)))
(let ([n (layout:selected-part)] [doc (buffers:document layout:buffer)])
    (and (layout:part-mode?) (document:node? n) (< 0 (document:node-start n) (document:node-end n) (document:length doc))))
(and (layout:view-node (layout:selected-view)) #t)
(string? (html->string (layout:screen client)))
(define before (list (tree) (views:id (layout:selected-view))))
(import (plugins))
(reload-modules! '((layout)))
(equal? before (list (tree) (views:id (layout:selected-view))))
(not (layout:part-mode?))
END
output=$(cd "$dir/work" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" 2>&1 |
  grep -v -E '^! (\([a-z-]+\) )?&cancelled$' || true)
expected='#t
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
