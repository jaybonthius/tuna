#!tuna
(import (runs) (processes) (timers))

(define (now-ms)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000.0) (/ (time-nanosecond t) 1e6))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

;; A task that asks to wake every 10 ms stands in for a key: how late it
;; wakes is how long a key would wait while the run writes.
(define (flood-ms line)
  (let* ([latest 0.0] [done? #f]
         [b (runs:start-for-user "*bench*" line (processes:options [directory "~/"]))]
         [start (now-ms)])
    (spawn-task
      (lambda (restore)
        (let loop ()
          (unless done?
            (let ([asked (now-ms)])
              (timers:sleep 0.01)
              (set! latest (max latest (- (now-ms) asked 10.0)))
              (loop))))))
    (let loop ()
      (unless (runs:status b)
        (timers:sleep 0.005)
        (loop)))
    (set! done? #t)
    (values (- (now-ms) start) latest)))

(define (run)
  (let-values ([(ms delay) (flood-ms "seq 1 1000000")])
    (show "run-seq-1m-ms" ms)
    (show "run-seq-1m-key-delay-ms" delay))
  (let-values ([(ms delay) (flood-ms "seq 1 200000 | awk '{printf \"\\033[3%dm%s\\033[0m\\n\", $1 % 8, $1}'")])
    (show "run-colored-200k-ms" ms)
    (show "run-colored-200k-key-delay-ms" delay)))
