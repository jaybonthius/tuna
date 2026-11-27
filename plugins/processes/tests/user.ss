(import (tuna) (test) (test-runner) (timers) (processes) (processes-test recorder) (processes-test setting))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (ignore-output bytes end) (void))

(define (split-on-dash s)
  (let loop ([i 0] [start 0] [parts '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s start i) parts))]
      [(char=? (string-ref s i) #\-) (loop (+ i 1) (+ i 1) (cons (substring s start i) parts))]
      [else (loop (+ i 1) start parts)])))

(test "a user process belongs to no module, and its id holds three numbers, so an id kept in saved data never names another process"
  (let ([shell (processes:start-for-user "sleep" '("5"))])
    (check-equal? #f (processes:owner shell))
    (let ([parts (split-on-dash (processes:id shell))])
      (check-equal? 3 (length parts))
      (check (for-all string->number parts)))
    (check-equal? shell (processes:find (processes:id shell)))
    (check-equal? #f (processes:find "1763367298-41822-4"))
    (processes:stop! shell)))

(test "a module follows a user process from an offset: the output from there still in the log, then new output, the end and the exit status"
  (let* ([r (processes-test/recorder:make)]
         [shell (processes:start-for-user "sh" '("-c" "printf 'a\\nb\\n'; read line; printf 'c\\n'"))])
    (test-runner:wait-until (lambda () (= (processes:output-end shell) 4)))
    (check-equal? 2 (processes:attach! shell 2 (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r)))
    (processes:send! shell "\n")
    (check-equal? '((output "b\nc\n" 6) (eof 6) (exit 0)) (processes-test/recorder:wait-for-exit r))
    (check (not (memq shell (processes:all))))))

(test "an ended user process stays in processes:all until an attachment's on-exit has run"
  (let ([r (processes-test/recorder:make)] [later (processes:start-for-user "printf" '("done\n"))])
    (test-runner:wait-until (lambda () (and (processes:status later) (= (processes:output-end later) 5))))
    (check-equal? 0 (processes:status later))
    (check (memq later (processes:all)))
    (check-equal? 5 (processes:attach! later (processes:output-end later) (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r)))
    (check-equal? '((eof 5) (exit 0)) (processes-test/recorder:wait-for-exit r))
    (check (not (memq later (processes:all))))))

(test "attaching again from the same module replaces its attachment"
  (let* ([first-calls '()] [r (processes-test/recorder:make)]
         [talker (processes:start-for-user "sh" '("-c" "read line; echo \"$line\""))])
    (processes:attach! talker 0
      (lambda (bytes end) (set! first-calls (cons 'output first-calls)))
      (lambda (status) (set! first-calls (cons 'exit first-calls))))
    (check-equal? 0 (processes:attach! talker 0 (processes-test/recorder:on-output r) (processes-test/recorder:on-exit r)))
    (processes:send! talker "hello\n")
    (check-equal? '((output "hello\n" 6) (eof 6) (exit 0)) (processes-test/recorder:wait-for-exit r))
    (check-equal? '() first-calls)))

(test "stopping a user process that has ended and that nobody follows removes it from processes:all"
  (let ([unfollowed (processes:start-for-user "true" '())])
    (test-runner:wait-until (lambda () (processes:status unfollowed)))
    (check (memq unfollowed (processes:all)))
    (processes:stop! unfollowed)
    (check (not (memq unfollowed (processes:all))))))

(define (counting)
  (let ([taken 0] [ended #f] [status #f])
    (values
      (lambda (bytes end) (if (eof-object? bytes) (set! ended end) (set! taken (+ taken (bytevector-length bytes)))))
      (lambda (s) (set! status s))
      (lambda ()
        (test-runner:wait-until (lambda () status))
        (list taken ended status)))))

(test "a user process nobody follows drops its oldest output by default, and attaching from an offset the log no longer holds starts at the oldest kept"
  (processes-test/setting:with processes:log-size 1000
    (lambda ()
      (let ([flood (processes:start-for-user "head" '("-c" "200000" "/dev/zero"))])
        (test-runner:wait-until (lambda () (= (processes:output-end flood) 200000)))
        (let-values ([(on-output on-exit result) (counting)])
          (check-equal? 199000 (processes:attach! flood 0 on-output on-exit))
          (check-equal? '(1000 200000 0) (result)))))))

(test "with full-log pause a user process stops reading once its log is full, so it waits and nothing it writes is lost"
  (processes-test/setting:with processes:log-size 1000
    (lambda ()
      (let ([held (processes:start-for-user "head" '("-c" "200000" "/dev/zero")
                    (processes:options [full-log (processes:full-log pause)]))])
        (test-runner:wait-until (lambda () (= (processes:output-end held) 1000)))
        (timers:sleep 0.2)
        (check-equal? 1000 (processes:output-end held))
        (check-equal? #f (processes:status held))
        (let-values ([(on-output on-exit result) (counting)])
          (check-equal? 0 (processes:attach! held 0 on-output on-exit))
          (check-equal? '(200000 200000 0) (result)))))))

(test "processes:attach! and processes:find check their arguments"
  (let ([held (processes:start-for-user "sleep" '("5"))])
    (test-runner:wait-until (lambda () (processes:pid held)))
    (check-equal? '(processes:attach! "not a user process")
      (violation (lambda () (processes:attach! (processes:start "true" '() ignore-output) 0 ignore-output))))
    (check-equal? '(processes:attach! "past the output read so far")
      (violation (lambda () (processes:attach! held 300000 ignore-output))))
    (check-equal? '(processes:attach! "not an output offset") (violation (lambda () (processes:attach! held -1 ignore-output))))
    (check-equal? '(processes:attach! "not a process") (violation (lambda () (processes:attach! 'held 0 ignore-output))))
    (check-equal? '(processes:find "not a string") (violation (lambda () (processes:find 'id))))
    (processes:stop! held)))
