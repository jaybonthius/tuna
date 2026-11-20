#!tuna
(import (jsonrpc) (processes))

(define (now-ns)
  (let ([t (current-time 'time-utc)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (now-ms) (/ (now-ns) 1e6))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (record-lines path)
  (call-with-input-file path
    (lambda (p)
      (let loop ([lines '()])
        (let ([line (get-line p)])
          (if (eof-object? line) (reverse lines) (loop (cons line lines))))))))

;; The server notes the time it flushed its answer, in the same clock, so
;; the wait counts from the answer's last byte.
(define (sent-ns record)
  (let ([line (find (lambda (line) (and (> (string-length line) 5) (string=? (substring line 0 5) "sent ")))
                    (record-lines record))])
    (string->number (substring line 5 (string-length line)))))

;; A task that asks to wake every 10 ms stands in for a key: how late it
;; wakes is how long a key would wait while the answer is read.
(define (measure label)
  (let* ([home (getenv "HOME")]
         [program (car (command-line))]
         [record (string-append home "/record-" label)]
         [c (jsonrpc:start "bench"
              (list program "--script" (string-append home "/fake-server.ss")
                    (string-append (path-parent program) "/libraries") record)
              (jsonrpc:handlers))]
         [latest 0.0] [done? #f])
    (jsonrpc:request c "echo" '#(1))
    (spawn-task
      (lambda ()
        (let loop ()
          (unless done?
            (let ([asked (now-ms)])
              (sleep-for 0.01)
              (set! latest (max latest (- (now-ms) asked 10.0)))
              (loop))))))
    (jsonrpc:request c "big" '(("size" . 2000000)))
    (let ([arrived (now-ns)])
      (set! done? #t)
      (show (format "jsonrpc-2mb-answer-~a-ms" label) (/ (- arrived (sent-ns record)) 1e6))
      (show (format "jsonrpc-2mb-key-delay-~a-ms" label) latest))
    (jsonrpc:stop! c)))

(define (run)
  (set-option! jsonrpc:events-log-size 0)
  (measure "log-off")
  (remove-option! jsonrpc:events-log-size)
  (measure "log-default"))
