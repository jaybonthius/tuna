#!/bin/sh
# A quit that lands in work after a batch is reported, as the core reports
# one, so the reports of quits are left out of what is compared.
set -eu
tuna=${1:?usage: layout-tabs-races-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-tabs-races-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/home" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$dir/home"
cp -RL tests/layout/home/. "$dir/home/"
mkdir -p "$dir/home/.config/tuna/lib"
cp -R tests/modules/. "$dir/home/.config/tuna/lib/"
cat > "$dir/input" <<'END'
(import (testing))
(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))
(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define client (web:add-client! 1))
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
(define (pick ls k) (list-ref ls (mod k (length ls))))
(define (attempt thunk) (guard (c [(not (cancelled? c)) #f]) (thunk)))
(define (click p) (list "<mouse-1>" (vector (views:id layout:screen-view) p)))
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
            (let* ([shown (layout:views)] [selected (layout:selected-view)] [many? (> (length (atom-ids (tree))) 12)]
                   [size (document:length (buffers:document layout:buffer))])
              (attempt
                (lambda ()
                  (case (mod k 14)
                    [(0) (if many? (layout-tabs:close-tab) (layout-tabs:new-tab))]
                    [(1) (if many? (layout:delete-part! (layout:view-node (pick shown k))) (layout-tabs:add-tab! selected notes))]
                    [(2) (layout-split:split-view! selected (layout-split:direction row))]
                    [(3) (layout-tabs:next-tab (- (mod k 7) 3))]
                    [(4) (layout-tabs:previous-tab (mod k 3))]
                    [(5) (layout:zoom #f)]
                    [(6) (layout:screen client)]
                    [(7) (layout-tabs:mouse-select-tab (click (mod (* k 13) size)))]
                    [(8) (layout-tabs:display-in-new-tab notes)]
                    [(9) (layout:other-view)]
                    [(10) (layout-tabs:close-tab)]
                    [(11) (layout-tabs:close-other-tabs)]
                    [(12) (layout-tabs:recent-tab (+ 1 (mod k 2)))]
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
(and (parts-only? (tree)) (ids-once? (atom-ids (tree))))
(and (layout:view-node (layout:selected-view)) (memq (layout:selected-view) (layout:views)) #t)
(for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (atom-ids (tree)))
(string? (html->string (layout:screen client)))
(define before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
(import (plugins))
(reload-modules! '((layout-tabs)))
(equal? before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
(reload-modules! '((layout)))
(equal? before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
END
output=$(cd "$dir/work" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" 2>&1 |
  grep -v -E '^! (\([a-z]+\) )?&cancelled$' || true)
expected='#t
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
