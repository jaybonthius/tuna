(import (tuna) (test) (test-runner) (test-user) (web) (options) (tables) (timers) (commands) (keys) (echo-area) (which-key)
        (which-key-test))

(options:set! which-key:delay 0.5)

(define resume-paused #f)

(commands:define-command (pausing) "Pauses until resumed." (suspend (lambda (resume) (set! resume-paused resume))))

(keys:bind! keys:global "C-c w h" which-key-test:keymap)
(keys:bind! keys:global "C-c w q z" which-key-test:squeak)
(keys:bind! keys:global "C-c w z" which-key-test:honk)
(keys:bind! keys:global "C-c w f p" pausing)
(keys:bind! keys:global "<mouse-3> a" which-key-test:honk)
(keys:bind! keys:global "<wheel-down> a" which-key-test:honk)

;; The claims below that no popup shows are about a time going by, so
;; they wait past the delay and look.
(define (past-the-delay) (timers:sleep 0.7))

(define (shown) (test-runner:wait-until which-key-test:shows?))

(define (undefined-messages thunk)
  (let ([reported '()])
    (let ([keep (lambda (next c) (set! reported (cons (condition-message c) reported)))])
      (advice-add! report keep)
      (thunk)
      (advice-remove! report keep))
    (reverse reported)))

(test "a key that leaves keys pending starts a timer of which-key:delay seconds, and the popup shows once it runs out"
  (test-user:press! "C-c w")
  (check-equal? #f (which-key-test:shows?))
  (shown)
  (check-equal? "C-c w" (car (which-key-test:popup))))

(test "once shown, the popup follows each further key of the sequence at once, and goes as soon as a command ends the sequence"
  (test-user:press! "h")
  (check-equal? '("C-c w h" ("h" "which-key-test:honk") ("s" "which-key-test:squeak")) (which-key-test:popup))
  (test-user:press! "s")
  (check-equal? #f (which-key-test:popup)))

(test "a new sequence waits for its own timer; an undefined key or a quit ends it and the popup goes"
  (test-user:press! "C-c w")
  (check-equal? #f (which-key-test:shows?))
  (shown)
  (check-equal? '("C-c w x is undefined") (undefined-messages (lambda () (test-user:press! "x"))))
  (check-equal? #f (which-key-test:popup))
  (test-user:press! "C-c w")
  (shown)
  (check-equal? '("C-c w C-g is undefined") (undefined-messages (lambda () (test-user:press! "C-g"))))
  (check-equal? #f (which-key-test:popup)))

(test "each key that leaves keys pending before the popup shows starts the timer again, for the keys pending then"
  (options:set! which-key:delay 1.0)
  (test-user:press! "C-c w")
  (timers:sleep 0.6)
  (test-user:press! "q")
  (timers:sleep 0.6)
  (check-equal? #f (which-key-test:shows?))
  (shown)
  (check-equal? '("C-c w q" ("z" "which-key-test:squeak")) (which-key-test:popup))
  (test-user:press! "z")
  (options:set! which-key:delay 0.5))

(test "the popup goes when a command pauses, since press! clears the pending keys before it runs the command"
  (test-user:press! "C-c w")
  (shown)
  (test-user:press! "f")
  (check-equal? "C-c w f" (car (which-key-test:popup)))
  (test-user:press! "p")
  (check-equal? #f (which-key-test:popup))
  (resume-paused void)
  (test-user:settle))

(test "the popup is drawn only for the client whose keys are pending"
  (let ([one (test-user:client)] [two (test-user:open-client)])
    (test-user:press! one "C-c w")
    (shown)
    (check-equal? '("C-c w" #f) (list (car (which-key-test:popup one)) (which-key-test:popup two)))
    (test-user:press! two "C-c w")
    (check-equal? '("C-c w" #f) (list (car (which-key-test:popup one)) (which-key-test:popup two)))
    (test-runner:wait-until (lambda () (which-key-test:popup two)))
    (test-user:press! two "z")
    (check-equal? '("C-c w" #f) (list (car (which-key-test:popup one)) (which-key-test:popup two)))
    (test-user:press! one "z")
    (web:close-client! two)))

(test "a delay of 0 shows the popup with the screen of the key that leaves keys pending; the delay is finite and not negative"
  (options:set! which-key:delay 0)
  (test-user:press! "C-c w")
  (check-equal? "C-c w" (car (which-key-test:popup)))
  (test-user:press! "z")
  (options:set! which-key:delay 0.5)
  (for-each
    (lambda (v) (check-raises (lambda (c) (and (who-condition? c) (eq? 'options:set! (condition-who c)))) (options:set! which-key:delay v)))
    '(-1 +inf.0 x)))

(test "when no key can follow the pending keys, no popup shows"
  (tables:define-table empty-keymap)
  (keys:bind! keys:global "C-c w e" empty-keymap)
  (options:set! which-key:delay 0)
  (test-user:press! "C-c w e")
  (check-equal? '("C-c w e" #f) (list (keys:pending (test-user:client)) (which-key-test:popup)))
  (check-equal? '("C-c w e x is undefined") (undefined-messages (lambda () (test-user:press! "x"))))
  (options:set! which-key:delay 0.5))

(test "after a lone ESC that waits to make the next key Meta no popup shows, nor after one typed while the popup shows"
  (options:set! keys:quit-keys '("C-g"))
  (keys:unbind! keys:global "ESC")
  (test-user:press! "ESC")
  (past-the-delay)
  (check-equal? #f (which-key-test:shows?))
  (check-equal? '("ESC C-g is undefined") (undefined-messages (lambda () (test-user:press! "C-g"))))
  (test-user:press! "C-c w")
  (shown)
  (test-user:press! "ESC")
  (check-equal? #f (which-key-test:shows?))
  (check-equal? '("C-c w ESC C-g is undefined") (undefined-messages (lambda () (test-user:press! "C-g"))))
  (options:unset! keys:quit-keys)
  (keys:bind! keys:global "ESC" keys:keyboard-quit))

(test "by default ESC is a quit key and ends the sequence, so the popup goes"
  (test-user:press! "C-c w")
  (shown)
  (check-equal? '("C-c w ESC is undefined") (undefined-messages (lambda () (test-user:press! "ESC"))))
  (check-equal? #f (which-key-test:shows?)))

(test "after a mouse key or a wheel key that starts a sequence, no popup shows"
  (test-user:show! "|text")
  (which-key-test:click! 3 1)
  (check-equal? "<mouse-3>" (keys:pending (test-user:client)))
  (past-the-delay)
  (check-equal? #f (which-key-test:shows?))
  (test-user:press! "a")
  (which-key-test:wheel! "down" 1)
  (check-equal? "<wheel-down>" (keys:pending (test-user:client)))
  (past-the-delay)
  (check-equal? #f (which-key-test:shows?))
  (test-user:press! "a"))

(test "the echo area shows the pending keys after its own pause, and the popup shows and follows them as before"
  (options:set! echo-area:echo-keystrokes 0.3)
  (let ([echo (lambda () (map test-user:element-text (test-user:elements (test-user:screen) "echo-area-echo")))])
    (test-user:press! "C-c w")
    (shown)
    (test-runner:wait-until (lambda () (equal? '("C-c w-") (echo))))
    (check-equal? "C-c w" (car (which-key-test:popup)))
    (test-user:press! "h")
    (check-equal? '("C-c w h-") (echo))
    (check-equal? "C-c w h" (car (which-key-test:popup)))
    (test-user:press! "s")
    (check-equal? #f (which-key-test:popup)))
  (options:unset! echo-area:echo-keystrokes))
