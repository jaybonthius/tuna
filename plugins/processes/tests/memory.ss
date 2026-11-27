(import (tuna) (test) (timers) (processes))

(define (resident-mib)
  (call-with-input-file "/proc/self/status"
    (lambda (port)
      (let loop ()
        (let ([line (get-line port)])
          (if (and (> (string-length line) 6) (string=? (substring line 0 6) "VmRSS:"))
              (quotient (read (open-string-input-port (substring line 6 (string-length line)))) 1024)
              (loop)))))))

(define (peak-for seconds)
  (let loop ([n (* seconds 4)] [peak 0])
    (cond
      [(= n 0) peak]
      [else (timers:sleep 0.25) (loop (- n 1) (max peak (resident-mib)))])))

(test "a user process that floods output keeps Tuna's memory near the size of the log, whether a module follows it or none does"
  (let ([followed (processes:start-for-user "cat" '("/dev/zero") (processes:options [full-log (processes:full-log pause)]))])
    (processes:attach! followed 0 (lambda (bytes end) (void)))
    (check (< (peak-for 3) 400))
    (check (> (processes:output-end followed) 100000000))
    (processes:stop! followed))
  (let ([unfollowed (processes:start-for-user "cat" '("/dev/zero"))])
    (check (< (peak-for 3) 400))
    (check (> (processes:output-end unfollowed) 100000000))
    (processes:stop! unfollowed)))
