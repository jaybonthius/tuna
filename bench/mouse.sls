#!tuna
(import (document) (buffers) (views) (keys) (layout) (editing) (undo) (web))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define batch 2000)

(define (ns-per-op thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define client (web:add-client! 1))

(define handle (table-ref web:input-handlers "mouse"))

(define (item view version . fields)
  (append fields
          `(("type" . "mouse") ("button" . 1) ("clicks" . 1) ("modifiers" . #()) ("report" . 1)
            ("view" . ,(views:id view)) ("version" . ,version) ("showing" . ,(views:shown-count view)))))

(define (handled it)
  (lambda () (parameterize ([web:current-client client]) (handle client it))))

;; A line place is what a click in text sends.
(define (run)
  (let ([b (buffers:make "bench"
             (apply string-append (map (lambda (i) (format "line ~a of the text a benchmark clicks in\n" i)) (iota 336))))]
        [v (layout:selected-view)])
    (views:set-buffer! v b)
    (buffers:with-buffer b (set-option-local! undo:limit 0))
    (let ([now (buffers:version b)])
      (show "mouse-click" (ns-per-op (handled (item v now '("action" . "click") '("line" . 100) '("count" . 5)))))
      ((handled (item v now '("action" . "down") '("line" . 100) '("count" . 5))))
      (let ([here (item v now '("action" . "move") '("line" . 100) '("count" . 9))]
            [there (item v now '("action" . "move") '("line" . 101) '("count" . 3))])
        (show "mouse-move" (/ (ns-per-op (lambda () ((handled here)) ((handled there)))) 2))))
    (let ([then (buffers:version b)])
      (do ([i 0 (fx+ i 1)]) ((fx= i 50)) (buffers:replace! b 1 1 "x"))
      (show "mouse-click-stale"
        (ns-per-op (handled (item v then '("action" . "click") '("line" . 100) '("count" . 5))))))))
