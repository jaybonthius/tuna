#!tuna
(import (terminal) (buffers) (document) (options) (timers))

(define (now-ms)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000.0) (/ (time-nanosecond t) 1e6))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define (screen-has? b text)
  (let* ([s (terminal:screen-text b)] [n (string-length text)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? (substring s i (+ i n)) text) (loop (+ i 1)))))))

(define (wait-for b text)
  (let loop ()
    (unless (screen-has? b text)
      (timers:sleep 0.005)
      (loop))))

;; Every row of the flood carries a colour, so each row's styles are
;; drawn as spans.
(define (run)
  (options:set! terminal:shell '("sh"))
  (options:set! terminal:environment '(("PS1" . "$ ")))
  (let ([b (terminal:start #f)])
    (wait-for b "$ ")
    (let ([start (now-ms)])
      (terminal:send! b "seq 1 20000 | awk '{printf \"\\033[3%dm%s\\033[0m\\n\", $1 % 8, $1}'; echo flood-end\r")
      (wait-for b "\nflood-end")
      (show "terminal-colored-20k-ms" (- (now-ms) start)))))
