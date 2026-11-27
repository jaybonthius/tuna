(import (tuna) (test) (test-runner) (program))

(define (cpu-ticks pid)
  (call-with-input-file (format "/proc/~a/stat" pid)
    (lambda (p)
      (let skip () (unless (char=? (read-char p) #\)) (skip)))
      (let loop ([field 3] [total 0])
        (let ([value (read p)])
          (cond
            [(= field 15) (+ total value)]
            [(= field 14) (loop (+ field 1) value)]
            [else (loop (+ field 1) total)]))))))

(define (pause-seconds seconds)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep (make-time 'time-duration 0 seconds)) (resume void))))))

(test "an idle Tuna with the user interface loaded and a timer far off uses no processor time"
  (let ([folder (string-append (getenv "HOME") "/idle")])
    (test-runner:make-home! folder)
    (call-with-output-file (string-append folder "/.config/tuna/init.ss")
      (lambda (p)
        (put-string p "(import (tuna) (timers) (web))\n")
        (put-string p "(import (layout) (echo-area) (status-line))\n(timers:run-after 3600 void)\n")
        (put-string p "(call-with-output-file (string-append (getenv \"HOME\") \"/ready\") (lambda (p) (write 'ready p)))\n")
        (put-string p "(import (console))\n")))
    (let ([r (program:start (program:tuna) folder '() '())])
      (test-runner:wait-until (lambda () (file-exists? (string-append folder "/ready"))))
      (let ([before (cpu-ticks (program:pid r))])
        (pause-seconds 3)
        (let ([used (- (cpu-ticks (program:pid r)) before)])
          (program:close-input! r)
          (program:wait r)
          ;; A tick is a hundredth of a second; an idle loop takes none.
          (check (<= used 10)))))))
