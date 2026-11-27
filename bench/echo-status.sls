#!tuna
(import (echo-area) (status-line) (layout) (layout-split) (views) (buffers) (keys) (commands) (web) (haml) (options))

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

(define (bytes-per-op batch thunk)
  (let ([before (sstats-bytes (statistics))])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
    (/ (- (sstats-bytes (statistics)) before) (exact->inexact batch))))

(define (show name value unit)
  (printf "~a ~,2f ~a\n" name value unit))

(commands:define-command (nothing) "Does nothing." #f)

(commands:define-command (say) "Shows a message." (echo-area:message! "Saved"))

(define (run)
  (let* ([notes (buffers:make "notes" "one\ntwo\nthree\n")]
         [client (web:add-client! 1)]
         [clients (cons client (map web:add-client! '(2 3 4)))])
    (layout:switch-to-buffer notes)
    (layout-split:split-view! (layout:selected-view) (layout-split:direction row))
    (batch-ended)
    (keys:bind! keys:global "a" nothing)
    (keys:bind! keys:global "b" say)
    (parameterize ([web:current-client client])
      (let ([press (lambda (key) (lambda () (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))])
        (echo-area:message! "")
        (show "press-key" (ns-per-op 2000 (press "a")) "ns")
        (show "press-key-bytes" (bytes-per-op 2000 (press "a")) "B")
        (show "press-key-clearing" (ns-per-op 2000 (lambda () (echo-area:message! "Saved") ((press "a")))) "ns")
        (show "press-key-showing" (ns-per-op 2000 (press "b")) "ns")))
    (show "message-new" (ns-per-op 2000 (let ([k 0]) (lambda () (set! k (fx+ k 1)) (echo-area:message! (if (even? k) "Wrote a" "Wrote b"))))) "ns")
    (show "message-repeated" (ns-per-op 2000 (lambda () (echo-area:message! "Wrote a"))) "ns")
    (show "message-bytes" (bytes-per-op 2000 (let ([k 0]) (lambda () (set! k (fx+ k 1)) (echo-area:message! (if (even? k) "Wrote a" "Wrote b"))))) "B")
    (echo-area:message! "")
    (show "batch-end" (ns-per-op 2000 batch-ended) "ns")
    (let ([v (layout:selected-view)])
      (show "status-line-draw" (ns-per-op 2000 (lambda () (html->bytevector (status-line:draw v client)))) "ns")
      (show "status-line-draw-bytes" (bytes-per-op 2000 (lambda () (html->bytevector (status-line:draw v client)))) "B")
      (show "screen-one-client" (ns-per-op 200 (lambda () (html->bytevector (layout:screen client)))) "ns")
      (show "screen-four-clients"
        (ns-per-op 200 (lambda () (for-each (lambda (c) (html->bytevector (layout:screen c))) clients))) "ns")
      (show "window-command"
        (/ (ns-per-op 200
             (lambda ()
               (let ([new (layout-split:split-view! (layout:selected-view) (layout-split:direction row))])
                 (batch-ended)
                 (layout:delete-part! (layout:view-node new))
                 (batch-ended))))
           2)
        "ns")
      (options:set! status-line:visible #f)
      (show "screen-one-client-without-status-lines" (ns-per-op 200 (lambda () (html->bytevector (layout:screen client)))) "ns")
      (show "screen-four-clients-without-status-lines"
        (ns-per-op 200 (lambda () (for-each (lambda (c) (html->bytevector (layout:screen c))) clients))) "ns"))))
