#!tuna
(import (layout) (layout-split) (layout-sides) (layout-scroll) (layout-float) (views) (buffers) (document) (commands) (web) (haml))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op batch thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (atom b . attributes)
  (views:view (cons* (cons 'view (views:id (views:make b))) (cons 'buffer (buffers:name b)) attributes)))

(define (column-of b . attributes)
  (layout-split:container (cons '(direction . column) attributes) (atom b) (atom b) (atom b)))

;; A float desktop over a row of a five-column strip and a column of
;; splits, with two floats: about as many parts as the layout
;; benchmark's splits.
(define (build! notes)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1)
      (document:from-datum
        (layout-float:container '()
          (layout-split:container '((direction . row))
            (apply layout-scroll:container '((weight . 3)) (map (lambda (i) (column-of notes '(size . 1/3))) (iota 5)))
            (layout-split:container '((direction . column)) (column-of notes) (column-of notes) (column-of notes)))
          (column-of notes '(place box 1/4 1/4))
          (column-of notes '(place box 3/4 3/4))))))
  (layout:select! (car (layout:views)))
  ((layout-sides:display-at-side (layout:direction down) 90 (quote content) (quote ((locked . #t)))) (buffers:make "*Echo*" "")))

(define (parts)
  (let count ([d (car (document:datums (buffers:document layout:buffer)))])
    (if (vector? d) 1 (+ 1 (apply + (map count (cddr d)))))))

(define (strip-items client)
  (let* ([html (html->string (layout:screen client))] [needle "data-scroller=\""])
    (let loop ([i 0])
      (if (string=? (substring html i (+ i (string-length needle))) needle)
          (let digits ([j (+ i (string-length needle))] [k 0])
            (let ([c (string-ref html j)])
              (if (char-numeric? c) (digits (+ j 1) (+ (* k 10) (- (char->integer c) 48))) k)))
          (loop (+ i 1))))))

(define (run)
  (let* ([notes (buffers:make "notes" "one\ntwo\nthree\n")]
         [client (web:add-client! 1)]
         [report (table-ref web:input-handlers "scroller")])
    (build! notes)
    (batch-ended)
    (show "parts" (parts))
    (let ([scroller (strip-items client)] [shown (map views:id (layout:views))] [k 0])
      (show "strip-report"
        (ns-per-op 2000
          (lambda ()
            (set! k (fx+ k 1))
            (report client `(("type" . "scroller") ("scroller" . ,scroller) ("placement" . 0) ("report" . ,k)
                             ("items" . ,(vector (list-ref shown (fxmod k 5)) (list-ref shown (fxmod (fx+ k 1) 5))))
                             ("whole" . ,(vector (list-ref shown (fxmod k 5)) (list-ref shown (fxmod (fx+ k 1) 5))))
                             ("settled" . #f)))))))
    (show "strip-select"
      (/ (ns-per-op 200
           (lambda ()
             (commands:run layout:select-right)
             (batch-ended)
             (commands:run layout:select-left)
             (batch-ended)))
         2))
    (let* ([v (layout:selected-view)] [completions (buffers:make "*completions*" "one\ntwo\n")]
           [popup (layout-float:show-at! v 1 completions 1/2 '(lines 4))])
      (batch-ended)
      (let ([anchor (views:find-anchor (caddr (assq 'place (vector-ref (caddr (caddr (car (document:datums (buffers:document layout:popups-buffer))))) 1))))]
            [k 0])
        (show "anchor-move" (ns-per-op 20000 (lambda () (set! k (fxlogxor k 1)) (views:move-anchor! anchor (fx+ 1 k))))))
      (layout-float:close! popup)
      (batch-ended)
      (show "popup-show-close"
        (/ (ns-per-op 200
             (lambda ()
               (layout-float:show-at! v 1 completions 1/2 '(lines 4))
               (batch-ended)
               (layout-float:close! (car (filter (lambda (p) (not (layout:view-node p))) (views:showing completions))))
               (batch-ended)))
           2)))
    (advice-add! views:draw (lambda (draw view client) (haml (:div))))
    (show "strip-screen-parts" (ns-per-op 200 (lambda () (html->bytevector (layout:screen client)))))))
