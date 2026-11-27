(import (tuna) (test) (test-user) (web) (buffers) (document) (faces) (tables) (commands) (keys) (echo-area) (repeat)
        (repeat-test))

(define steps '())

(define (take-steps!) (let ([s (reverse steps)]) (set! steps '()) s))

(commands:define-command (step) "Records a step and its prefix argument." (set! steps (cons (list 'step (commands:prefix-argument)) steps)))

(commands:define-command (back) "Records a step back." (set! steps (cons 'back steps)))

(commands:define-command (other) "Records another command." (set! steps (cons 'other steps)))

(commands:define-command (failing)
  "Shows an error, then raises."
  (parameterize ([echo-area:face faces:error]) (echo-area:message! "no more steps"))
  (set! steps (cons 'failing steps))
  (error 'failing "no more steps"))

(commands:define-command (jump) "Records a jump." (set! steps (cons 'jump steps)))

(tables:define-table step-keymap "Keys that go on stepping.")

(tables:define-table jump-keymap "Keys that go on jumping.")

(keys:bind! step-keymap "n" step)
(keys:bind! step-keymap "p" back)
(keys:bind! step-keymap "x" back)
(keys:bind! step-keymap "f" failing)
(keys:bind! step-keymap "C-c s" other)
(keys:bind! jump-keymap "j" jump)
(keys:bind! keys:global "C-c n" step)
(keys:bind! keys:global "C-c p" back)
(keys:bind! keys:global "C-c x" other)
(keys:bind! keys:global "C-c f" failing)
(keys:bind! keys:global "C-c j" jump)
(keys:bind! keys:global "<f5>" step)
(tables:set! keys:repeat-keymaps step-keymap)
(tables:set! keys:repeat-keymaps jump-keymap)

(define (repeating? keymap client) (and (memq keymap (keys:active-keymaps client)) #t))

(define (stepping? client) (repeating? step-keymap client))

(define (undefined-messages thunk)
  (map condition-message (repeat-test:reports-during thunk)))

(test "after a command run by two or more keys, a repeating keymap that binds the last key to it stays while its keys are typed"
  (test-user:press! "C-c n")
  (check (stepping? (test-user:client)))
  (test-user:press! "n n p")
  (check-equal? '((step #f) (step #f) (step #f) back) (take-steps!))
  (check (stepping? (test-user:client)))
  (test-user:press! "C-c x")
  (check (not (stepping? (test-user:client))))
  (check-equal? '(other) (take-steps!)))

(test "a command run by one key, or by no client's key, enters no keymap; nor does one whose last key the keymap binds to another command"
  (test-user:press! "<f5>")
  (check (not (stepping? (test-user:client))))
  (commands:run step)
  (check (not (stepping? (test-user:client))))
  (test-user:press! "C-c x")
  (check (not (stepping? (test-user:client))))
  (check-equal? '((step #f) (step #f) other) (take-steps!)))

(test "a prefix argument before the keys goes to the command; one typed while repeating is another key, which ends the repetition"
  (test-user:press! "C-u C-c n")
  (check-equal? '((step (4))) (take-steps!))
  (check (stepping? (test-user:client)))
  (test-user:press! "C-u")
  (check (not (stepping? (test-user:client))))
  (check-equal? '("n is undefined") (undefined-messages (lambda () (test-user:press! "n"))))
  (check-equal? '() (take-steps!)))

(test "a key pressed outside an input item is its client's, so it repeats as a typed one does"
  (spawn-task (lambda (restore) (keys:press! (test-user:client) "C-c") (keys:press! (test-user:client) "n")))
  (test-user:settle)
  (check (stepping? (test-user:client)))
  (check-equal? '((step #f)) (take-steps!))
  (test-user:press! "C-g"))

(test "each client repeats on its own"
  (let ([one (test-user:client)] [two (test-user:open-client)])
    (test-user:press! one "C-c n")
    (check-equal? '(#t #f) (list (stepping? one) (stepping? two)))
    (test-user:press! two "C-c p p")
    (test-user:press! one "n")
    (check-equal? '((step #f) back back (step #f)) (take-steps!))
    (check-equal? '(#t #t) (list (stepping? one) (stepping? two)))
    (test-user:press! two "C-g")
    (check-equal? '(#t #f) (list (stepping? one) (stepping? two)))
    (test-user:press! one "C-g")
    (web:close-client! two)))

(test "entering another repeating keymap ends the one repeating before"
  (test-user:press! "C-c n C-c j")
  (check-equal? '(#f #t) (list (stepping? (test-user:client)) (repeating? jump-keymap (test-user:client))))
  (test-user:press! "j j")
  (check-equal? '((step #f) jump jump jump) (take-steps!))
  (test-user:press! "C-g"))

(test "a key sequence found in the repeating keymap goes on repeating and shows the hint"
  (test-user:press! "C-c n C-c s")
  (check (stepping? (test-user:client)))
  (check-equal? "Repeat with n, p, x, f, C-c s" (echo-area:current-message))
  (take-steps!)
  (test-user:press! "C-g"))

(test "each repetition shows the keys that go on in the echo area, without logging them; a key that ends it takes the hint away"
  (let ([log (lambda () (document:text (buffers:document (buffers:find "*Messages*"))))])
    (let ([before (log)])
      (test-user:press! "C-c n n")
      (check-equal? "Repeat with n, p, x, f, C-c s" (echo-area:current-message))
      (check-equal? before (log)))
    (test-user:press! "C-c x")
    (check-equal? #f (echo-area:current-message))
    (take-steps!)))

(test "a command that raises has still run, so its keymap repeats, and the hint follows the message it showed, in its face; only the message is logged"
  (let* ([log (lambda () (document:text (buffers:document (buffers:find "*Messages*"))))]
         [before (string-length (log))]
         [reported (repeat-test:reports-during (lambda () (test-user:press! "C-c f")))])
    (check-equal? '("no more steps") (map condition-message reported))
    (check (stepping? (test-user:client)))
    (check-equal? "no more steps [Repeat with n, p, x, f, C-c s]" (echo-area:current-message))
    (check-equal? faces:error (echo-area:current-face))
    (check-equal? "no more steps\nfailing: no more steps\n" (substring (log) before (string-length (log))))
    (repeat-test:reports-during (lambda () (test-user:press! "f")))
    (check (stepping? (test-user:client)))
    (check-equal? "no more steps [Repeat with n, p, x, f, C-c s]" (echo-area:current-message))
    (check-equal? '(failing failing) (take-steps!))
    (test-user:press! "C-g")))

(test "a click, which clears no message, ends the repetition and leaves the message the hint followed, in its face"
  (keys:bind! keys:global "<mouse-1>" other)
  (test-user:show! "|clicked")
  (repeat-test:reports-during (lambda () (test-user:press! "C-c f")))
  (repeat-test:click! 1 2)
  (check-equal? '("no more steps" error #f) (list (echo-area:current-message) (echo-area:current-face) (stepping? (test-user:client))))
  (test-user:press! "C-g")
  (test-user:press! "<f5>")
  (check-equal? #f (stepping? (test-user:client)))
  (take-steps!)
  (tables:remove! keys:global "<mouse-1>"))

(test "a click bound in the keymap replaces the hint rather than adding to it, and a click outside it takes the hint back"
  (keys:bind! keys:global "<mouse-1>" other)
  (keys:bind! step-keymap "<mouse-1>" step)
  (test-user:show! "|clicked")
  (test-user:press! "C-c n")
  (repeat-test:click! 1 2)
  (repeat-test:click! 1 2)
  (check-equal? '((step #f) (step #f) (step #f)) (take-steps!))
  (check-equal? "Repeat with n, p, x, f, C-c s, <mouse-1>" (echo-area:current-message))
  (keys:unbind! step-keymap "<mouse-1>")
  (repeat-test:click! 1 2)
  (check-equal? '(#f #f) (list (stepping? (test-user:client)) (echo-area:current-message)))
  (check-equal? '(other) (take-steps!))
  (tables:remove! keys:global "<mouse-1>"))

(test "a key bound in a repeating keymap works only while it repeats"
  (test-user:press! "C-c n x")
  (check-equal? '((step #f) back) (take-steps!))
  (test-user:press! "C-g")
  (check-equal? '("x is undefined") (undefined-messages (lambda () (test-user:press! "x")))))

(test "taken out of the table, a keymap no longer repeats, and one taken out while it repeats stays until a key ends it"
  (test-user:press! "C-c n")
  (tables:remove! keys:repeat-keymaps step-keymap)
  (test-user:press! "n")
  (check (stepping? (test-user:client)))
  (test-user:press! "C-c x")
  (check (not (stepping? (test-user:client))))
  (test-user:press! "C-c n")
  (check (not (stepping? (test-user:client))))
  (tables:set! keys:repeat-keymaps step-keymap)
  (take-steps!))

(test "with show-hint overridden to do nothing, no hint shows and the keymap still repeats"
  (override-set! repeat:show-hint (lambda (keymap) (void)))
  (test-user:press! "C-c n n")
  (check-equal? '(#t #f) (list (stepping? (test-user:client)) (echo-area:current-message)))
  (override-remove! repeat:show-hint)
  (test-user:press! "C-g")
  (take-steps!))

(test "show-hint takes a keymap or #f"
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'repeat:show-hint (condition-who c))
                                 (string=? "neither a keymap nor #f" (condition-message c))))
    (repeat:show-hint 'resize)))

(test "reloading the plugin ends every repetition, and the repeating keymaps, which keys holds, stay"
  (test-user:press! "C-c n")
  (reload-modules! '((repeat)))
  (check (not (stepping? (test-user:client))))
  (check (tables:ref keys:repeat-keymaps step-keymap #f))
  (test-user:press! "C-c p p")
  (check (stepping? (test-user:client)))
  (check-equal? '((step #f) back back) (take-steps!))
  (test-user:press! "C-g"))

(test "unloading the plugin ends the repetition and takes the hint back"
  (test-user:press! "C-c n")
  (check-equal? "Repeat with n, p, x, f, C-c s" (echo-area:current-message))
  (unload-owner! (module-owner '(repeat)))
  (test-user:settle)
  (check-equal? '(#f #f) (list (stepping? (test-user:client)) (echo-area:current-message)))
  (test-user:press! "C-c n")
  (check (not (stepping? (test-user:client))))
  (take-steps!))
