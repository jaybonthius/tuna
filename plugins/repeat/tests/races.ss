(import (tuna) (test) (test-runner) (test-user) (tables) (commands) (keys) (repeat) (repeat-test quits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (sleep-ms ms) (chez:sleep (make-time 'time-duration (* ms 1000000) 0)))

(define steps 0)

(commands:define-command (step) "Counts a step." (set! steps (+ steps 1)))

(commands:define-command (back) "Counts a step back." (set! steps (- steps 1)))

(tables:define-table step-keymap "Keys that go on stepping.")

(keys:bind! step-keymap "n" step)
(keys:bind! step-keymap "p" back)
(keys:bind! keys:global "C-c n" step)
(keys:bind! keys:global "C-c p" back)
(tables:set! keys:repeat-keymaps step-keymap)

(test "quits landing in presses, the commands and the entries that start and end repetitions leave C-g to end them, and keys repeat as before"
  (let* ([one (test-user:client)] [quitting (box #t)] [quits 0] [quits-reported 0] [presses 0]
         [keys-pressed '("C-c" "n" "n" "p" "p" "C-c" "p" "n" "C-u" "C-c" "n" "C-c" "n" "p" "C-g")]
         [count-reports (lambda (next c)
                          (cond
                            [(cancelled? c) (set! quits-reported (+ quits-reported 1))]
                            [(warning? c) (void)]
                            [else (next c)]))])
    (advice-add! report count-reports)
    ;; A quit lands up to a thousand ticks after it is asked for, and one
    ;; asked for just before the quitter stops may land after it has. One
    ;; guard holds from before the quitter starts until well after it has
    ;; stopped, since a quit between two guards would end the test.
    (let ([quitter #f] [until (+ (real-time) 1500)])
      (let again ()
        (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
          (unless quitter
            (set! quitter
              (fork-task
                (lambda (restore)
                  (let loop ()
                    (when (unbox quitting)
                      (repeat-test/quits:request-quit!)
                      (sleep-ms 1)
                      (loop)))))))
          ;; A quit that ends a repetition, or drops a prefix, leaves the
          ;; keys after it undefined, and their warnings are the storm's.
          (with-exception-handler
            (lambda (c) (unless (warning? c) (raise-continuable c)))
            (lambda ()
              (let loop ()
                (when (< (real-time) until)
                  (for-each (lambda (k) (keys:press! one k) (set! presses (+ presses 1))) keys-pressed)
                  (loop)))))
          (set-box! quitting #f)
          (test-runner:join quitter)
          (let settle ([n 0]) (when (< n 100000) (settle (+ n 1)))))))
    (advice-remove! report count-reports)
    (check (> (+ quits quits-reported) 100))
    (check (> presses 1000))
    (keys:press! one "C-g")
    (keys:press! one "C-g")
    (check (not (memq step-keymap (keys:active-keymaps one))))
    (set! steps 0)
    (test-user:press! "C-c n n n p")
    (check-equal? 2 steps)
    (check (memq step-keymap (keys:active-keymaps one)))))
