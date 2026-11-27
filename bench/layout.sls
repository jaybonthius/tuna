#!tuna
(import (layout) (layout-split) (views) (buffers) (document) (keys) (web) (haml) (tables))

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

(define (declining b) #f)

(define (build! notes)
  (let loop ([n 23] [v (layout:selected-view)] [d 'row])
    (unless (= n 0)
      (let ([new (layout-split:split-view! v d)])
        (loop (- n 1) (if (even? n) new v) (if (eq? d 'row) 'column 'row)))))
  ((layout-split:display-at-side (layout:direction down) 90 (quote content) (quote ((locked . #t)))) (buffers:make "*Echo*" "")))

(define (parts)
  (let count ([d (car (document:datums (buffers:document layout:buffer)))])
    (if (vector? d) 1 (+ 1 (apply + (map count (cddr d)))))))

(define (run)
  (let* ([notes (buffers:make "notes" "one\ntwo\nthree\n")]
         [client (web:add-client! 1)])
    (layout:switch-to-buffer notes)
    (build! notes)
    (show "parts" (parts))
    (do ([i 0 (fx+ i 1)]) ((fx= i 20))
      (tables:set! layout:display-rules (lambda (b) (eq? b 'never)) declining))
    (show "focus-keymaps" (ns-per-op 2000 (lambda () (keys:active-keymaps client))))
    (show "call-with-selected-view" (ns-per-op 2000 (lambda () (views:call-with-view (layout:selected-view) void))))
    (show "display-buffer" (ns-per-op 2000 (lambda () (layout:display-buffer notes))))
    (show "window-command"
      (/ (ns-per-op 200
           (lambda ()
             (let ([v (layout-split:split-view! (layout:selected-view) (layout-split:direction row))])
               (batch-ended)
               (layout:delete-part! (layout:view-node v))
               (batch-ended))))
         2))
    (let ([side (buffers:make "*side*" "")])
      (show "place-side-part"
        (/ (ns-per-op 200
             (lambda ()
               (let ([v ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) side)])
                 (batch-ended)
                 (layout:delete-part! (layout:view-node v))
                 (batch-ended))))
           2)))
    (show "zoom" (/ (ns-per-op 2000 (lambda () (layout:zoom #f) (layout:views) (layout:zoom #f) (layout:views))) 2))
    (show "other-view" (ns-per-op 2000 (lambda () (layout:other-view 1))))
    (advice-add! views:draw (lambda (draw view client) (haml (:div))))
    (show "screen-parts" (ns-per-op 200 (lambda () (html->bytevector (layout:screen client)))))))
