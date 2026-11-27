(import (tuna) (test) (test-runner) (test-user) (web) (views) (buffers) (hooks) (options) (tables) (commands) (keys) (keys-test))

(define seen '())

(define (see! . what) (set! seen (cons what seen)))

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(commands:define-command (record)
  "Records what it sees of the keys that ran it."
  (see! (keys:command-keys) (keys:typed-char) (keys:shift-translated?) (commands:prefix-argument)))

(commands:define-command (visit)
  "Records its prefix argument."
  (see! 'visit (commands:prefix-argument)))

(commands:define-command (moving)
  "Records the character typed, its prefix number and whether shift was taken off."
  (see! 'moving (keys:typed-char) (commands:prefix-number) (keys:shift-translated?)))

(commands:define-command (wait [name 'waiting])
  "Waits until resumed or quit."
  (guard (c [(cancelled? c) (see! 'quit name)])
    (suspend (lambda (resume) #f))))

(keys:bind! keys:global "C-c r" record)
(keys:bind! keys:global "C-x C-f" visit)
(keys:bind! keys:global "C-c w" wait)

(define (undefined-messages thunk)
  (keys-test:report-messages thunk))

;; As for a user who takes ESC out of the quit keys and unbinds it.
(define (escape-as-meta!)
  (options:set! keys:quit-keys '("C-g"))
  (keys:unbind! keys:global "ESC"))

(define (escape-as-quit!)
  (options:unset! keys:quit-keys)
  (keys:bind! keys:global "ESC" keys:keyboard-quit))

(test "a sequence is pending until its last key, which runs its command"
  (test-user:press! "C-c")
  (check-equal? "C-c" (keys:pending (test-user:client)))
  (test-user:press! "r")
  (check-equal? #f (keys:pending (test-user:client)))
  (check-equal? '(("C-c r" #\r #f #f)) (take-seen!)))

(test "each client has its own pending keys, and a client that typed nothing has none"
  (let ([one (test-user:client)] [two (test-user:open-client)])
    (test-user:press! one "C-x")
    (test-user:press! two "C-c")
    (check-equal? '("C-x" "C-c" #f) (list (keys:pending one) (keys:pending two) (keys:pending 'unknown)))
    (test-user:press! one "C-f")
    (check-equal? '(#f "C-c") (list (keys:pending one) (keys:pending two)))
    (test-user:press! two "r")
    (check-equal? '((visit #f) ("C-c r" #\r #f #f)) (take-seen!))
    (web:close-client! two)))

(test "a command sees the keys that ran it, the character they type and whether shift was taken off; outside a command it sees #f"
  (for-each (lambda (k) (keys:bind! keys:global k record))
    '("C-c SPC" "C-c TAB" "C-c RET" "C-c a" "<f1>" "C-c é" "M-r"))
  (escape-as-meta!)
  (for-each test-user:press! '("C-c SPC" "C-c TAB" "C-c RET" "C-c a" "<f1>" "C-c é" "ESC r" "M-r"))
  (escape-as-quit!)
  (check-equal? '(("C-c SPC" #\space #f #f) ("C-c TAB" #\tab #f #f) ("C-c RET" #\newline #f #f) ("C-c a" #\a #f #f)
                  ("<f1>" #f #f #f) ("C-c é" #\é #f #f) ("ESC r" #\r #f #f) ("M-r" #f #f #f))
                (take-seen!))
  (check-equal? '(#f #f #f #f) (list (keys:command-keys) (keys:command-event) (keys:typed-char) (keys:shift-translated?))))

(define forked #f)

(commands:define-command (forker)
  "Forks a task that reads the keys."
  (fork-task (lambda (restore) (set! forked (list (keys:command-keys) (keys:typed-char) (keys:shift-translated?))))))

(keys:bind! keys:global "C-c y" forker)

(test "a task forked in a command runs no command"
  (test-user:press! "C-c y")
  (test-runner:wait-until (lambda () forked))
  (check-equal? '(#f #f #f) forked))

(test "a shifted key that finds nothing runs its unshifted binding shift-translated"
  (tables:define-table moving-keymap)
  (keys:bind! moving-keymap "<printing-char>" moving)
  (keys:bind! moving-keymap "SPC" moving)
  (keys:bind! moving-keymap "<right>" moving)
  (keys:bind! moving-keymap "C-f" moving)
  (let ([entry (lambda (client posn) (list moving-keymap))])
    (hooks:add! keys:find-keymaps entry -50)
    (test-user:press! "x X SPC <right> S-<right> C-f C-F")
    (hooks:remove! keys:find-keymaps entry))
  (check-equal? '((moving #\x 1 #f) (moving #\X 1 #f) (moving #\space 1 #f) (moving #f 1 #f) (moving #f 1 #t) (moving #f 1 #f)
                  (moving #f 1 #t))
                (take-seen!)))

(define tasks '())

(define clients '())

(commands:define-command (note-task)
  "Notes its task and client."
  (set! tasks (cons (current-task) tasks))
  (set! clients (cons (web:current-client) clients)))

(keys:bind! keys:global "C-c t" note-task)

(test "a key pressed outside an input item runs its command in the task it is pressed in, with web:current-client bound to the client"
  (let ()
    (let* ([pressing (spawn-task (lambda (restore) (keys:press! (test-user:client) "C-c") (keys:press! (test-user:client) "t") (current-task)))]
           [pressed-in (test-runner:join pressing)])
      (check-equal? (car tasks) pressed-in)
      (check-equal? (list (test-user:client)) clients)
      (check-equal? #f (web:current-client)))))

(commands:define-command (insert-typed [char (keys:typed-char)])
  "Inserts CHAR at point."
  (let ([view (views:current)])
    (buffers:replace! (views:buffer view) (views:point view) (views:point view) (string char))))

(test "the page's example command inserts the character typed"
  (tables:define-table typing-keymap)
  (keys:bind! typing-keymap "<printing-char>" insert-typed)
  (let ([entry (lambda (client posn) (list typing-keymap))])
    (hooks:add! keys:find-keymaps entry -50)
    (test-user:show! "|")
    (test-user:type! "Hi!")
    (hooks:remove! keys:find-keymaps entry))
  (check-equal? "|!iH" (test-user:text)))

(test "the prefix commands give the next command its prefix argument"
  (escape-as-meta!)
  (for-each
    (lambda (keys) (test-user:press! (string-append keys " C-x C-f")))
    '("C-u" "C-u C-u" "C-u C-u C-u" "C-u 1 2" "C-u 0" "M-5" "M-1 2" "M-1 M-2" "M--" "M-- 5" "M-- 0" "M-- M--"
      "C-u -" "C-u - 5" "C-u 5 -" "M-5 C-u" "ESC 3"))
  (escape-as-quit!)
  (test-user:press! "C-x C-f")
  (check-equal? '((4) (16) (64) 12 0 5 12 12 - -5 - #f - -5 -5 (4) 3 #f) (map cadr (take-seen!))))

(test "a key after C-u that is no digit runs with the prefix argument, and the prefix keymap ends"
  (tables:define-table counted-keymap)
  (keys:bind! counted-keymap "<printing-char>" moving)
  (let ([entry (lambda (client posn) (list counted-keymap))])
    (hooks:add! keys:find-keymaps entry -50)
    (test-user:press! "C-u x")
    (check-equal? '((moving #\x 4 #f)) (take-seen!))
    (check (not (memq keys:universal-argument-keymap (keys:active-keymaps (test-user:client)))))
    (hooks:remove! keys:find-keymaps entry)))

(test "the prefix argument is the client's, and a prefix key keeps it"
  (let ([one (test-user:client)] [two (test-user:open-client)])
    (test-user:press! one "C-u 4")
    (test-user:press! two "C-x C-f")
    (test-user:press! one "C-x")
    (check-equal? "C-x" (keys:pending one))
    (check-equal? '((visit #f)) (take-seen!))
    (test-user:press! one "C-f")
    (check-equal? '((visit 4)) (take-seen!))
    (web:close-client! two)))

(test "keys that find nothing run keys:undefined, which warns, and the pending keys and the prefix argument clear"
  (check-equal? '("C-c z is undefined") (undefined-messages (lambda () (test-user:press! "C-u C-c z"))))
  (test-user:press! "C-x C-f")
  (check-equal? #f (keys:pending (test-user:client)))
  (check-equal? '((visit #f)) (take-seen!))
  (check-equal? '("<f12> is undefined") (undefined-messages (lambda () (test-user:press! "<f12>"))))
  (check-equal? '("the key is undefined") (undefined-messages (lambda () (commands:run keys:undefined)))))

(test "an ESC that is no quit key waits for the key it makes Meta; ESC ESC finds nothing"
  (escape-as-meta!)
  (keys:bind! keys:global "M-x" record)
  (let ()
    (test-user:press! "ESC")
    (check-equal? "ESC" (keys:pending (test-user:client)))
    (test-user:press! "x")
    (check-equal? #f (keys:pending (test-user:client)))
    (check-equal? '(("ESC x" #\x #f #f)) (take-seen!))
    (check-equal? '("ESC ESC is undefined") (undefined-messages (lambda () (test-user:press! "ESC ESC"))))
    (test-user:press! "C-x ESC")
    (check-equal? "C-x ESC" (keys:pending (test-user:client)))
    (check-equal? '("C-x ESC x is undefined") (undefined-messages (lambda () (test-user:press! "x"))))
    (tables:remove! keys:global "M-x")
    (escape-as-quit!)))

(test "a binding whose command's module is not loaded warns, naming the keys and the command"
  (load-module! '(keys-test under-prefix))
  (let* ([command (keys:lookup 'client "C-c q x")] [name (commands:command-name command)])
    (keys:bind! keys:global "C-c f" command)
    (unload-owner! (module-owner '(keys-test under-prefix)))
    (check-equal? (list (format "C-c f runs ~a, which is not loaded" name))
                  (undefined-messages (lambda () (test-user:press! "C-c f"))))
    (load-module! '(keys-test under-prefix))
    (check-equal? '() (undefined-messages (lambda () (test-user:press! "C-c q x"))))
    (unload-owner! (module-owner '(keys-test under-prefix))))
  (tables:set! keys:global "C-c s" 'posted)
  (check-equal? '("C-c s runs posted, which is not loaded") (undefined-messages (lambda () (test-user:press! "C-c s"))))
  (tables:remove! keys:global "C-c s"))

(test "advice on keys:press! sees every key"
  (let* ([pressed '()] [note (lambda (press client key) (set! pressed (cons key pressed)) (press client key))])
    (advice-add! keys:press! note)
    (test-user:press! "C-c r C-u C-x C-f")
    (advice-remove! keys:press! note)
    (check-equal? '("C-c" "r" "C-u" "C-x" "C-f") (reverse pressed))
    (check-equal? '(("C-c r" #\r #f #f) (visit (4))) (take-seen!))))

(test "press! takes a client"
  (check-raises (keys-test:raised-by 'keys:press! "not a client") (keys:press! 'one "C-g")))
