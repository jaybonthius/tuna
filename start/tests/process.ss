(import (test) (plugins process)
        (rename (only (chezscheme) fork-thread sleep) (fork-thread chez:fork-thread) (sleep chez:sleep)))

(define (output-files)
  (filter (lambda (name) (string=? (path-extension name) "out"))
          (directory-list (string-append (getenv "HOME") "/.cache/tuna"))))

(define (run . arguments)
  (call-with-values (lambda () (run-program (car arguments) (cdr arguments))) list))

(test "arguments reach the program as they are"
  (for-each
    (lambda (text) (check-equal? (list 0 text) (run "printf" "%s" text)))
    '("plain" "a b" "it's" "\"quoted\"" "$HOME" "`date`" "back\\slash" "new\nline" "*" "" "ünïcödé")))

(test "the exit status and the output come back, standard error included"
  (check-equal? '(3 "out err") (run "sh" "-c" "printf out; printf ' err' >&2; exit 3"))
  (check-equal? '(0 "") (run "cat"))
  (check-equal? '(-15 "") (run "sh" "-c" "kill -TERM $$"))
  (check-equal? 127 (car (run "tuna-no-such-program"))))

(test "runs on many threads at once each keep their own status and output"
  (let* ([threads 8] [runs 40] [wrong 0] [m (make-mutex)])
    (for-each thread-join
      (map (lambda (i)
             (chez:fork-thread
               (lambda ()
                 (do ([n 0 (+ n 1)]) ((= n runs))
                   (let ([text (format "~a/~a" i n)] [status (modulo (+ i n) 7)])
                     (unless (equal? (list status text)
                                     (run "sh" "-c" "printf %s \"$1\"; exit \"$2\"" "sh" text
                                          (number->string status)))
                       (with-mutex m (set! wrong (+ wrong 1)))))))))
           (iota threads)))
    (check-equal? 0 wrong)
    (check-equal? '() (output-files))))

(test "other threads collect while a thread waits for its program"
  (let ([waiter (chez:fork-thread (lambda () (run "sleep" "0.5")))])
    (chez:sleep (make-time 'time-duration 100000000 0))
    (let ([start (current-time 'time-monotonic)])
      (collect-rendezvous)
      (let ([d (time-difference (current-time 'time-monotonic) start)])
        (check (< (+ (* (time-second d) 1000000000) (time-nanosecond d)) 200000000))))
    (thread-join waiter)))

(test "arguments are checked"
  (check-raises assertion-violation? (run-program 'sh '()))
  (check-raises assertion-violation? (run-program "sh" '(1))))
