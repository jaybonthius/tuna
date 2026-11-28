(import (tuna) (test) (test-runner) (test-user) (web) (options) (tables) (commands) (keys) (keys-test))

(define seen '())

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(define marker (make-thread-parameter #f))

(define (name-of command)
  (cond
    [(eq? command note) 'note]
    [(eq? command other) 'other]
    [(eq? command count-more) 'count-more]
    [(eq? command keys:keyboard-quit) 'keyboard-quit]
    [else command]))

(commands:define-command (note)
  "Notes the marker, its prefix argument and the last command."
  (set! seen (cons (list (marker) (commands:prefix-argument) (name-of (commands:last-command))) seen)))

(commands:define-command (other) "Does nothing." (void))

(commands:define-command (count-three)
  "Makes the next command's prefix argument 3."
  (keys:set-prefix-argument! 3))

(commands:define-command (count-more)
  "Multiplies the prefix argument by ten for the next command."
  (keys:set-prefix-argument! (* 10 (commands:prefix-number))))

(commands:define-command (count-none)
  "Sets the prefix argument, then clears it."
  (keys:set-prefix-argument! '(16))
  (keys:set-prefix-argument! #f))

(commands:define-command (count-list)
  "Makes the next command's prefix argument (12)."
  (keys:set-prefix-argument! '(12)))

(define (marking value) (lambda (run) (parameterize ([marker (cons value (or (marker) '()))]) (run))))

(commands:define-command (mark-a) "Hands the next command a wrapper." (keys:wrap-next-command! (marking 'a) "C-c a"))

(commands:define-command (mark-b) "Hands the next command another." (keys:wrap-next-command! (marking 'b) "C-c b"))

(define waited #f)

(commands:define-command (wait)
  "Waits until resumed or quit."
  (guard (c [(cancelled? c) (set! waited 'quit)])
    (set! waited 'waiting)
    (suspend (lambda (resume) #f))))

(keys:bind! keys:global "C-c n" note)
(keys:bind! keys:global "C-c x" other)
(keys:bind! keys:global "C-c 3" count-three)
(keys:bind! keys:global "C-c m" count-more)
(keys:bind! keys:global "C-c 0" count-none)
(keys:bind! keys:global "C-c l" count-list)
(keys:bind! keys:global "C-c a" mark-a)
(keys:bind! keys:global "C-c b" mark-b)
(keys:bind! keys:global "C-c w" wait)

(test "a command hands the next command a prefix argument with set-prefix-argument!"
  (test-user:press! "C-c x C-c 3 C-c n")
  (check-equal? '((#f 3 other)) (take-seen!))
  (test-user:press! "C-c 3 C-c m C-c m C-c n C-c n")
  (check-equal? '((#f 300 note) (#f #f note)) (take-seen!)))

(test "a prefix command leaves the last command as it was, so the command after a run of them sees the one before"
  (test-user:press! "C-c x C-u M-5 - C-c n")
  (test-user:press! "M-- C-u 1 C-c m C-c n")
  (check-equal? '((#f -5 other) (#f 10 note)) (take-seen!)))

(test "the prefix argument is the client's, and clears when the next command runs, also when a command sets it and clears it"
  (let ([two (test-user:open-client)])
    (test-user:press! "C-c 3 C-c 0 C-c n")
    (test-user:press! two "C-c 3")
    (test-user:press! "C-c n")
    (check-equal? '((#f #f note) (#f #f note)) (take-seen!))
    (check-equal? "C-u 3" (keys:prefix-description two))
    (test-user:press! "C-u")
    (check-equal? '("C-u" "C-u 3") (list (keys:prefix-description (test-user:client)) (keys:prefix-description two)))
    (test-user:press! "C-c n")
    (check-equal? '((#f (4) note)) (take-seen!))
    (check-equal? #f (keys:prefix-description (test-user:client)))
    (web:close-client! two)))

(test "set-prefix-argument! needs a command a key ran, a prefix argument and the main thread"
  (check-raises (test-runner:raised-with 'keys:set-prefix-argument! "no command a key ran is running") (keys:set-prefix-argument! 3))
  (check-equal? '("no command a key ran is running") (keys-test:report-messages (lambda () (commands:run count-three))))
  (for-each
    (lambda (v) (check-raises (test-runner:raised-with 'keys:set-prefix-argument! "not a prefix argument") (keys:set-prefix-argument! v)))
    '(x 1.5 (4 4) ("4") +))
  (check-equal? '(keys:set-prefix-argument! "not on the main thread") (keys-test:on-thread (lambda () (keys:set-prefix-argument! 3)))))

(test "prefix-description gives the prefix argument as the keys that give it"
  (let ([described (lambda (keys)
                     (test-user:press! keys)
                     (let ([d (keys:prefix-description (test-user:client))]) (test-user:press! "C-g") d))])
    (check-equal? '("C-u" "C-u C-u" "C-u C-u C-u" "C-u 5" "C-u 12" "C-u -" "C-u -3" "C-u 3" "C-u (12)")
                  (map described '("C-u" "C-u C-u" "C-u C-u C-u" "M-5" "C-u 1 2" "M--" "M-- 3" "C-c 3" "C-c l"))))
  (check-equal? #f (keys:prefix-description 'unknown))
  (check-equal? '(keys:prefix-description "not on the main thread")
                (keys-test:on-thread (lambda () (keys:prefix-description (test-user:client))))))

(test "a command that reads keys takes a prefix argument typed among them with lookup-in and prefix-after"
  (let* ([one (test-user:client)] [active (keys:active-keymaps one)] [counting (cons keys:universal-argument-keymap active)]
         [prefix-command? (lambda (v) (memq v (list keys:universal-argument keys:digit-argument keys:negative-argument)))]
         [typed-prefix (lambda (first . keys)
                         (let loop ([keys keys] [prefix #f] [keymaps first])
                           (let ([c (and (pair? keys) (keys:lookup-in keymaps (car keys)))])
                             (if (prefix-command? c)
                                 (loop (cdr keys) (keys:prefix-after c (car keys) prefix) counting)
                                 (list prefix keys)))))])
    (check-equal? '(((16) ("x")) (12 ("x")) (-5 ("x")) (-3 ("x")) (7 ("x")) (#f ("3" "x")) (32 ("x")) (#f ("x")))
                  (list (typed-prefix active "C-u" "C-u" "x") (typed-prefix active "C-u" "1" "2" "x") (typed-prefix active "M-5" "-" "x")
                        (typed-prefix active "M--" "3" "x") (typed-prefix active "C-u" "-" "-" "7" "x") (typed-prefix active "3" "x")
                        (typed-prefix counting "3" "2" "x") (typed-prefix active "x")))))

(test "prefix-after gives what each prefix command makes of a prefix argument, and refuses another command or a key with no digit"
  (check-equal? '((4) (16) 12 -12 - #f 5 -5 -)
                (list (keys:prefix-after keys:universal-argument "C-u" #f) (keys:prefix-after keys:universal-argument "C-u" '(4))
                      (keys:prefix-after keys:digit-argument "2" 1) (keys:prefix-after keys:digit-argument "M-2" -1)
                      (keys:prefix-after keys:negative-argument "M--" #f) (keys:prefix-after keys:negative-argument "-" '-)
                      (keys:prefix-after keys:digit-argument "5" #f) (keys:prefix-after keys:digit-argument "5" '-)
                      (keys:prefix-after keys:digit-argument "0" '-)))
  (check-raises (test-runner:raised-with 'keys:prefix-after "not a prefix command for the key") (keys:prefix-after keys:digit-argument "M-x" 4))
  (check-raises (test-runner:raised-with 'keys:prefix-after "not a prefix command for the key") (keys:prefix-after note "C-u" #f))
  (check-raises (test-runner:raised-with 'keys:prefix-after "not a prefix argument") (keys:prefix-after keys:universal-argument "C-u" 'x)))

(test "a wrapper runs the next command a key runs inside it, the newest innermost, and goes"
  (test-user:press! "C-c x C-c a C-c n C-c n")
  (check-equal? '(((a) #f other) (#f #f note)) (take-seen!))
  (test-user:press! "C-c a C-c b C-c n")
  (check-equal? '(((b a) #f note)) (take-seen!)))

(test "a prefix command keeps the wrappers it was handed for the command after, and the description gives them before the prefix argument"
  (test-user:press! "C-c a C-u")
  (check-equal? "C-c a C-u" (keys:prefix-description (test-user:client)))
  (test-user:press! "C-c n")
  (check-equal? '(((a) (4) note)) (take-seen!)))

(test "a prefix argument typed before a wrapper's prefix command is spent by it"
  (test-user:press! "C-u C-c a C-c n")
  (check-equal? '(((a) #f note)) (take-seen!)))

(test "input that is no key leaves the wrapper waiting, and each client has its own"
  (let ([two (test-user:open-client)])
    (test-user:press! "C-c a")
    (keys:run-as-input (test-user:client) note)
    (test-user:press! two "C-c n")
    (test-user:press! "C-c n")
    (check-equal? '((#f #f note) (#f #f note) ((a) #f note)) (take-seen!))
    (web:close-client! two)))

(test "C-g drops a waiting wrapper and does no more; the next C-g quits the paused command"
  (let ([one (test-user:client)])
    (spawn-task (lambda (restore) (keys:press! one "C-c") (keys:press! one "w")))
    (test-user:settle)
    (check-equal? 'waiting waited)
    (test-user:press! "C-c a")
    (check-equal? "C-c a" (keys:prefix-description one))
    (keys:press! one "C-g")
    (test-user:settle)
    (check-equal? '(#f waiting) (list (keys:prefix-description one) waited))
    (keys:press! one "C-g")
    (test-user:settle)
    (check-equal? 'quit waited)))

(test "wrap-next-command! needs a key or click being handled and a procedure"
  (check-raises (test-runner:raised-with 'keys:wrap-next-command! "no key or click is being handled")
    (keys:wrap-next-command! (marking 'c) "C-c c"))
  (check-raises (test-runner:raised-with 'keys:wrap-next-command! "not a procedure") (keys:wrap-next-command! 'c "C-c c")))
