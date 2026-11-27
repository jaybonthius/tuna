#!tuna
(import (replace) (search) (search-bench) (buffers) (document) (views) (layout) (keys) (web) (timers))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs) (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (press! client key)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))

;; An answer is timed until a second posted item runs, so the batch's end,
;; where an edited buffer's scans start again, is included.
(define (answer-ms client key)
  (let ([done #f] [start (now-ns)])
    (spawn-task (lambda (restore) (press! client key)))
    (spawn-task (lambda (restore) (set! done (now-ns))))
    (let wait () (unless done (timers:sleep 0.001) (wait)))
    (/ (- done start) 1e6)))

(define (run)
  (let* ([client (web:add-client! 1)]
         [b (search-bench:buffer-of (search-bench:sample 'code 100000000))]
         [view (layout:selected-view)])
    (layout:switch-to-buffer b)
    (views:set-point! view 1)
    (spawn-task
      (lambda (restore)
        (replace:query-replace! view client (search:make-query "lambda") "LAMBDA" 0
                                (document:length (buffers:document b)) (search:direction forward))))
    (timers:sleep 0.1)
    (let wait () (unless (search:scan-done? (replace:session-scan (replace:current client))) (timers:sleep 0.01) (wait)))
    (timers:sleep 1)
    (printf "matches in the session: ~a\n" (search:scan-count (replace:session-scan (replace:current client))))
    (let* ([ys (map (lambda (k) (answer-ms client "y")) (iota 6))]
           [ns (map (lambda (k) (answer-ms client "n")) (iota 4))])
      (printf "replace-y-100mb ~,3f\n" (median ys))
      (printf "replace-n-100mb ~,3f\n" (median ns))
      (for-each (lambda (k x) (printf "replace-y~a-100mb ~,3f\n" k x)) (iota 6) ys)
      (for-each (lambda (k x) (printf "replace-n~a-100mb ~,3f\n" k x)) (iota 4) ns)
      (printf "replacements made: ~a\n" (replace:session-count (replace:current client))))
    (press! client "q")))
