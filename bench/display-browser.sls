#!tuna
(import (document) (buffers) (views) (layout) (keys) (commands) (web) (haml) (display-bench))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(commands:define-command (self-insert)
  "Inserts the character typed at point."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)])
    (buffers:replace! b p p (string (keys:typed-char)))
    (views:set-point! v (+ p 1))))

(commands:define-command (delete-backward)
  "Deletes the character before point."
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)])
    (buffers:replace! b (- p 1) p "")))

(define buffers-made '())

(define (setup! content views)
  (let ([b (or (let ([e (assq content buffers-made)]) (and e (cdr e)))
               (let ([b (if (eq? content 'nodes)
                            (display-bench:node-buffer "nodes" 22000)
                            (display-bench:text-buffer "text" 22000))])
                 (set! buffers-made (cons (cons content b) buffers-made))
                 b))])
    (display-bench:show-layout! b views)))

(define samples '())
(define last-draw-ns 0)
(define kept '())

(define (timed-screen screen client)
  (let* ([start (now-ns)] [s (screen client)])
    (set! last-draw-ns (- (now-ns) start))
    s))

(define (counted-send send client screen title)
  (let* ([start (now-ns)] [bytes (html->bytevector screen)])
    (send client bytes title)
    (let ([k (let loop ([cs (web:clients)] [k 0]) (cond [(null? cs) -1] [(eq? (car cs) client) k] [else (loop (cdr cs) (+ k 1))]))])
      (set! samples (cons (list k last-draw-ns (- (now-ns) start) (bytevector-length bytes)) samples))
      (when (= k 0) (set! kept (cons bytes kept))))))

(define (reset!) (set! samples '()) (set! kept '()))

(define (quantile xs q)
  (if (null? xs) 0 (list-ref (list-sort < xs) (min (- (length xs) 1) (exact (floor (* q (length xs))))))))

(define (stats)
  (for-each
    (lambda (k)
      (let ([ss (filter (lambda (s) (= (car s) k)) samples)])
        (unless (null? ss)
          (printf "client ~a: ~a screens; draw us p50 ~,1f p90 ~,1f; write+give us p50 ~,1f; bytes p50 ~a max ~a\n"
            k (length ss)
            (/ (quantile (map cadr ss) 0.5) 1000.0) (/ (quantile (map cadr ss) 0.9) 1000.0)
            (/ (quantile (map caddr ss) 0.5) 1000.0)
            (quantile (map cadddr ss) 0.5) (apply max (map cadddr ss))))))
    '(0 1 2 3)))

(define (dump! folder)
  (let loop ([bs (reverse kept)] [i 0])
    (unless (null? bs)
      (let ([p (open-file-output-port (format "~a/~5,'0d.html" folder i) (file-options no-fail))])
        (put-bytevector p (car bs))
        (close-port p))
      (loop (cdr bs) (+ i 1)))))

(advice-add! layout:screen timed-screen)
(advice-add! web:send-screen! counted-send)
(table-set! web:scripts 'display-browser "display-browser.js")
(keys:bind! keys:global "<printing-char>" self-insert)
(keys:bind! keys:global "DEL" delete-backward)
