#!tuna
(import (layout) (layout-split) (undo) (views) (buffers) (document) (keys) (web) (tables))

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

(define (build!)
  (let loop ([n 23] [v (layout:selected-view)] [d 'row] [last #f])
    (if (= n 0)
        (begin ((layout-split:display-at-side (layout:direction down) 90 (quote content) (quote ((locked . #t)))) (buffers:make "*Echo*" "")) last)
        (let ([new (layout-split:split-view! v d)])
          (loop (- n 1) (if (even? n) new v) (if (eq? d 'row) 'column 'row) new)))))

(define (parts)
  (let count ([d (car (document:datums (buffers:document layout:buffer)))])
    (if (vector? d) 1 (+ 1 (apply + (map count (cddr d)))))))

(define (press! client key)
  ((tables:ref web:input-handlers "key") client
   (list (cons "type" "key") (cons "key" (car key)) (cons "code" "") (cons "modifiers" (list->vector (cdr key))))))

(define (swap-time client)
  (/ (ns-per-op 200
       (lambda ()
         (press! client '("L"))
         (batch-ended)
         (press! client '("J"))
         (batch-ended)))
     2))

;; The deepest split holds two views, and every other split a view and a
;; split, so a verb there moves one view, and at the top half the layout.
(define (run)
  (let ([notes (buffers:make "notes" "one\ntwo\nthree\n")] [client (web:add-client! 1)])
    (layout:switch-to-buffer notes)
    (let* ([first (layout:selected-view)] [deepest (build!)])
      (batch-ended)
      (show "parts" (parts))
      (layout:select! deepest)
      (press! client '("'" "super"))
      (batch-ended)
      (show "part-verb" (swap-time client))
      (press! client '("Enter"))
      (layout:select! first)
      (press! client '("'" "super"))
      (press! client '("i"))
      (batch-ended)
      (show "part-verb-half-layout" (swap-time client))
      (show "part-move"
        (/ (ns-per-op 500
             (lambda ()
               (press! client '("j"))
               (batch-ended)
               (press! client '("l"))
               (batch-ended)))
           2)))))
