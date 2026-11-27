(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (test-runner) (timers) (web) (layout) (views) (buffers) (keys) (commands) (options) (editing)
        (echo-area) (echo-area-test))

(define echo echo-area-test:echo)

;; A fixed pause below stands only where the claim is that nothing shows
;; for a time longer than echo-keystrokes.
(define (shows text) (test-runner:wait-until (lambda () (equal? text (echo)))))

(define (shows-for client text) (test-runner:wait-until (lambda () (equal? text (echo client)))))

(define (undefined-during thunk)
  (map condition-message (echo-area-test:reports-during thunk)))

(commands:define-command (nothing) "Does nothing." (void))

(keys:bind! keys:global "C-x n" nothing)
(keys:bind! keys:global "C-x 4 n" nothing)

(test "the echo area shows a client's unfinished keys after a pause of echo-keystrokes seconds, 1 by default"
  (check-equal? 1 (echo-area:echo-keystrokes))
  (options:set! echo-area:echo-keystrokes 0.3)
  (test-user:press! "C-x")
  (check-equal? #f (echo))
  (shows "C-x-"))

(test "once keys show, each next key shows at once, and a key that finishes them leaves them as typed until the next typed key"
  (test-user:press! "4")
  (check-equal? "C-x 4-" (echo))
  (undefined-during (lambda () (test-user:press! "C-g")))
  (test-user:press! "C-x")
  (check-equal? #f (echo))
  (shows "C-x-")
  (test-user:press! "n")
  (check-equal? "C-x n" (echo))
  (test-user:press! "a")
  (check-equal? #f (echo)))

(define waiting #f)

(commands:define-command (pausing) "Pauses until resumed." (suspend (lambda (resume) (set! waiting resume))))

(keys:bind! keys:global "C-x p" pausing)

(test "a key whose command pauses shows what it finished while the command waits, and the client's later keys replace it for good"
  (test-user:press! "C-x")
  (shows "C-x-")
  (test-user:press! "p")
  (check-equal? "C-x p" (echo))
  (test-user:press! "a")
  (check-equal? #f (echo))
  (waiting void)
  (test-user:settle)
  (check-equal? #f (echo)))

(test "keys finished before the pause never show"
  (test-user:press! "C-x n")
  (timers:sleep 0.6)
  (check-equal? #f (echo)))

(test "each key before the pause starts it again"
  (test-user:press! "C-x")
  (timers:sleep 0.2)
  (test-user:press! "4")
  (timers:sleep 0.2)
  (check-equal? #f (echo))
  (shows "C-x 4-")
  (undefined-during (lambda () (test-user:press! "C-g"))))

(test "a message covers the keys, and the next typed key shows them again"
  (test-user:press! "C-x")
  (shows "C-x-")
  (echo-area:message! "Saved")
  (test-user:settle)
  (check-equal? "Saved" (echo))
  (test-user:press! "4")
  (check-equal? "C-x 4-" (echo))
  (check-equal? '("C-x 4 C-g is undefined") (undefined-during (lambda () (test-user:press! "C-g"))))
  (check-equal? "C-x 4 C-g is undefined" (echo)))

(test "a pending prefix argument shows as the keys that give it"
  (test-user:press! "C-u")
  (shows "C-u-")
  (test-user:press! "C-u 5")
  (check-equal? "C-u 5-" (echo))
  (test-user:press! "C-x")
  (check-equal? "C-u 5 C-x-" (echo))
  (test-user:press! "n")
  (check-equal? "C-u 5 C-x n" (echo))
  (test-user:press! "M--")
  (shows "C-u --")
  (test-user:press! "C-g")
  (check-equal? "Quit" (echo)))

(test "a read with no prompt shows the keys of the command reading, as keys still to be finished"
  (views:set-buffer! (echo-area-test:view) (buffers:make "notes" "one\n"))
  (test-user:press! "C-q")
  (check-equal? #f (echo))
  (shows "C-q-")
  (test-user:press! "b")
  (check-equal? "C-q b" (echo)))

(commands:define-command (read-with-prompt)
  "Reads a key sequence with a prompt and says what was read."
  (echo-area:message! "Read ~a" (keys:read-key-sequence "Key: ")))

(keys:bind! keys:global "C-c r" read-with-prompt)

(test "a read with a prompt shows it at once, then the keys read after it as they come, in a div.echo-area-echo marked with the echo area's keymap"
  (test-user:press! "C-c r")
  (check-equal? "Key: " (echo))
  (test-user:press! "C-x")
  (check-equal? "Key: C-x-" (echo))
  (let ([e (echo-area-test:element (test-user:client))])
    (check-equal? (views:keymap-mark echo-area:keymap) (test-user:element-attribute e "data-keymap"))
    (check-equal? '("Key: ") (echo-area-test:prompt-parts (test-user:client))))
  (test-user:press! "4")
  (check-equal? "Key: C-x 4-" (echo))
  (test-user:press! "n")
  (shows "Read C-x 4 n"))

(commands:define-command (read-quietly) "Reads a key with a prompt." (keys:read-key "Press a key: "))

(keys:bind! keys:global "C-c q" read-quietly)

(test "a read whose command shows nothing leaves the prompt and the keys until the next typed key"
  (test-user:press! "C-c q")
  (test-user:press! "z")
  (check-equal? "Press a key: z" (echo))
  (test-user:press! "a")
  (check-equal? #f (echo)))

(commands:define-command (say-then-read)
  "Says hello, then reads a key with a prompt."
  (echo-area:message! "Hello")
  (keys:read-key "Press a key: "))

(keys:bind! keys:global "C-c h" say-then-read)

(commands:define-command (say-then-read-parts)
  "Says hello, then reads a key with a prompt that shows text."
  (echo-area:message! "Hello")
  (keys:read-key (list "Key for " (cons #f "notes") ": ")))

(keys:bind! keys:global "C-c l" say-then-read-parts)

(test "a read's prompt shows as the read starts, over a message; a message shown while it waits covers it while it shows"
  (test-user:press! "C-c h")
  (check-equal? "Press a key: " (echo))
  (timers:sleep 0.6)
  (check-equal? "Press a key: " (echo))
  (echo-area:message! "Saved")
  (test-user:settle)
  (check-equal? "Saved" (echo))
  (timers:sleep 0.6)
  (check-equal? "Saved" (echo))
  (test-user:press! "z")
  (check-equal? "Press a key: z" (echo))
  (test-user:press! "a")
  (test-user:press! "C-c l")
  (check-equal? "Key for notes: " (echo))
  (test-user:press! "a"))

(test "a click that starts a read with a prompt shows it over a message"
  (keys:bind! keys:global "<mouse-1>" read-quietly)
  (echo-area:message! "Hello")
  (echo-area-test:click-at! (echo-area-test:view) 2)
  (check-equal? "Press a key: " (echo))
  (test-user:press! "z")
  (keys:bind! keys:global "<mouse-1>" editing:mouse-set-point)
  (test-user:press! "a"))

(define other (test-user:open-client))

(test "each client sees only its own keys; a message covers them all, and a typed key clears it for every client"
  (test-user:press! other "C-x")
  (shows-for other "C-x-")
  (check-equal? #f (echo))
  (test-user:press! "C-x")
  (shows "C-x-")
  (check-equal? "C-x-" (echo other))
  (echo-area:message! "Both")
  (test-user:settle)
  (check-equal? '("Both" "Both") (list (echo) (echo other)))
  (test-user:press! other "n")
  (check-equal? '("C-x-" "C-x n") (list (echo) (echo other)))
  (test-user:press! "n"))

(test "a read's prompt covered by a message shows again when another client's key clears the message"
  (test-user:press! "C-c q")
  (echo-area:message! "From two")
  (test-user:settle)
  (check-equal? '("From two" "From two") (list (echo) (echo other)))
  (test-user:press! other "a")
  (check-equal? '(#f "Press a key: ") (list (echo-area:current-message) (echo)))
  (test-user:press! "q")
  (check-equal? "Press a key: q" (echo))
  (test-user:press! "a"))

(test "what follows the prompt is echo-area:keys-text, which advice changes"
  (let ([with-hint (lambda (keys-text c) (let ([text (keys-text c)]) (and text (string-append text " (C-h for help)"))))])
    (advice-add! echo-area:keys-text with-hint)
    (test-user:press! "C-x")
    (shows "C-x- (C-h for help)")
    (check-equal? "C-x- (C-h for help)" (echo-area:keys-text (test-user:client)))
    (advice-remove! echo-area:keys-text with-hint))
  (test-user:press! "n")
  (check-equal? "C-x n" (echo-area:keys-text (test-user:client)))
  (check-raises (echo-area-test:raised? 'echo-area:keys-text "not a client") (echo-area:keys-text 'nobody))
  (check-equal? '(echo-area:keys-text "not on the main thread")
    (echo-area-test:on-thread (lambda () (echo-area:keys-text (test-user:client))))))

(test "while the echo area is hidden it shows no keys either"
  (let ([hide (lambda (hidden?) #t)])
    (advice-add! echo-area:hidden? hide)
    (test-user:press! "C-x")
    (timers:sleep 0.6)
    (check-equal? #f (echo))
    (advice-remove! echo-area:hidden? hide))
  (test-user:settle)
  (check-equal? "C-x-" (echo))
  (test-user:press! "n"))

(test "at 0, no keys show, but a prompt still does; a negative pause is refused"
  (options:set! echo-area:echo-keystrokes 0)
  (test-user:press! "C-x")
  (timers:sleep 0.6)
  (check-equal? #f (echo))
  (test-user:press! "n")
  (test-user:press! "C-c r")
  (test-user:press! "C-x")
  (check-equal? "Key: " (echo))
  (test-user:press! "n")
  (check-raises (lambda (c) (assertion-violation? c)) (options:set! echo-area:echo-keystrokes -1)))

(test "a client removed takes its echo with it"
  (options:set! echo-area:echo-keystrokes 0.3)
  (let ([third (test-user:open-client)])
    (test-user:press! third "C-x")
    (web:close-client! third)
    (timers:sleep 0.6)
    (check-equal? #f (echo-area:keys-text third))))
