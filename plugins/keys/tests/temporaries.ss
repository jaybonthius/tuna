(import (tuna) (test) (test-runner) (test-user) (web) (tables) (commands) (keys) (keys-test)
        (rename (only (chezscheme) collect-request-handler) (collect-request-handler chez:collect-request-handler)))

(define seen '())

(define (see! . what) (set! seen (cons what seen)))

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(commands:define-command (record) "Records the keys that ran it." (see! 'record (keys:command-keys)))

(commands:define-command (other) "Records that it ran." (see! 'other))

(commands:define-command (wait [name 'waiting])
  "Waits until resumed or quit."
  (guard (c [(cancelled? c) (see! 'quit name)])
    (see! 'waiting name)
    (suspend (lambda (resume) #f))))

(tables:define-table repeat-keymap "Keys that go on after repeat-other.")

(define repeat-ended 0)

(commands:define-command (repeat-other)
  "Runs other, then lets o run it again."
  (other)
  (keys:push-keymap! (web:current-client) repeat-keymap
    (lambda (found command) (eq? found repeat-keymap))
    (lambda () (set! repeat-ended (+ repeat-ended 1)))))

(keys:bind! repeat-keymap "o" other)
(keys:bind! keys:global "C-c r" record)
(keys:bind! keys:global "C-c o" repeat-other)
(keys:bind! keys:global "C-c w" wait)

(define (keymap-name keymap)
  (cond
    [(not keymap) #f]
    [(eq? keymap keys:global) 'global]
    [(tables:table? keymap) (string->symbol (tables:documentation keymap))]
    [else keymap]))

(define (command-name command)
  (cond
    [(eq? command record) 'record]
    [(eq? command other) 'other]
    [else command]))

(test "before each command, and when a key finds nothing, the newest temporary keymap is tested with the keymap the key was found in and the command; one not kept ends, runs its on-exit, and the next is tested"
  (tables:define-table first-temporary "first")
  (tables:define-table second-temporary "second")
  (keys:bind! first-temporary "a" record)
  (keys:bind! second-temporary "b" other)
  (let* ([tests '()] [exits '()] [one (test-user:client)] [two (test-user:open-client)]
         [keep-while (lambda (name ok)
                       (lambda (found command)
                         (set! tests (cons (list name (keymap-name found) (command-name command)) tests))
                         (ok found command)))]
         [exit-of (lambda (name) (lambda () (set! exits (cons name exits))))]
         [end-first (keys:push-keymap! one first-temporary (keep-while 'first (lambda (found command) #t)) (exit-of 'first))]
         [end-second (keys:push-keymap! one second-temporary (keep-while 'second (lambda (found command) (eq? found second-temporary)))
                       (exit-of 'second))])
    (test-user:press! "b a")
    (check-equal? '((second second other) (second first record) (first first record)) (reverse tests))
    (check-equal? '(second) exits)
    (check-equal? (list first-temporary) (filter (lambda (k) (memq k (list first-temporary second-temporary))) (keys:active-keymaps one)))
    (set! tests '())
    (check-equal? '("C-x C-z is undefined") (keys-test:report-messages (lambda () (test-user:press! "C-x C-z"))))
    (check-equal? '((first #f #f)) (reverse tests))
    (check (not (memq first-temporary (keys:active-keymaps two))))
    (end-first)
    (end-first)
    (check-equal? '(first second) exits)
    (check (not (memq first-temporary (keys:active-keymaps one))))
    (check-equal? '((other) (record "a")) (take-seen!))
    (web:close-client! two)))

(test "a keymap a command pushes is not tested for the key that ran it, and stays while its keys are typed"
  (set! repeat-ended 0)
  (test-user:press! "C-c o o o")
  (check-equal? '((other) (other) (other)) (take-seen!))
  (check-equal? 0 repeat-ended)
  (check (memq repeat-keymap (keys:active-keymaps (test-user:client))))
  (test-user:press! "C-c r")
  (check-equal? 1 repeat-ended)
  (check (not (memq repeat-keymap (keys:active-keymaps (test-user:client)))))
  (check-equal? '((record "C-c r")) (take-seen!)))

(test "a keep or on-exit that raises is reported, and its keymap ends"
  (tables:define-table raising-first "raising first")
  (tables:define-table raising-second "raising second")
  (let* ([exits '()] [one (test-user:client)])
    (keys:push-keymap! one raising-first (lambda (found command) (car '())) (lambda () (set! exits (cons 'a exits))))
    (keys:push-keymap! one raising-second (lambda (found command) #f) (lambda () (vector-ref (vector) 0)))
    (check-equal? '("~s is not a valid index for ~s" "~s is not a pair")
                  (keys-test:report-messages (lambda () (test-user:press! "C-c r"))))
    (check-equal? '(a) exits)
    (check-equal? '() (filter (lambda (k) (memq k (list raising-first raising-second))) (keys:active-keymaps one)))
    (check-equal? '((record "C-c r")) (take-seen!))))

(test "push-keymap! checks its arguments"
  (tables:define-table checked-temporary "checked")
  (let ([one (test-user:client)])
    (check-raises (test-runner:raised-with 'keys:push-keymap! "not a keymap") (keys:push-keymap! one 'x (lambda (f c) #t)))
    (check-raises (test-runner:raised-with 'keys:push-keymap! "not a procedure") (keys:push-keymap! one checked-temporary 'keep))
    (check-raises (test-runner:raised-with 'keys:push-keymap! "not a procedure")
      (keys:push-keymap! one checked-temporary (lambda (f c) #t) 'exit))
    (for-each
      (lambda (prompt)
        (check-raises (test-runner:raised-with 'keys:push-keymap! "not a prompt, a procedure or #f")
          (keys:push-keymap! one checked-temporary (lambda (f c) #t) void prompt)))
      (list 'x '() '(("x" . #f)) (list 7)))))

(test "a temporary keymap ends with the owner that pushed it, without running its on-exit then, and another owner's stays"
  (tables:define-table own-temporary "own")
  (let* ([one (test-user:client)] [exits '()] [count (lambda () (length (keys:active-keymaps one)))] [before (count)])
    (load-module! '(keys-test pusher))
    (check-equal? (+ before 1) (count))
    (unload-owner! (module-owner '(keys-test pusher)))
    (check-equal? before (count))
    (load-module! '(keys-test pusher))
    (let ([end-own (keys:push-keymap! one own-temporary (lambda (f c) #t) (lambda () (set! exits (cons 'own exits))))])
      (check-equal? (+ before 2) (count))
      (unload-owner! (module-owner '(keys-test pusher)))
      (check-equal? (+ before 1) (count))
      (check (memq own-temporary (keys:active-keymaps one)))
      (check-equal? '() exits)
      (end-own)
      (check-equal? '(own) exits))))

(test "a client that is gone takes its session with it, even when its temporary keymap's procedures hold it"
  (tables:define-table holding-temporary "holding")
  (let ([gone (let ([client (string #\f)])
                (keys:push-keymap! client holding-temporary (lambda (found command) (eq? found client)))
                (weak-cons client '()))])
    ;; An explicit collect refuses while other threads, such as saved
    ;; data's writer, run; a rendezvous pauses them first.
    (parameterize ([chez:collect-request-handler (lambda () (collect (collect-maximum-generation)))])
      (collect-rendezvous))
    (check (bwp-object? (car gone)))))

(test "keyboard-quit clears the pending keys and the prefix argument; with none pending it also ends the temporary keymaps"
  (tables:define-table quit-temporary "quit")
  (let* ([one (test-user:client)] [exits '()]
         [end (keys:push-keymap! one quit-temporary (lambda (f c) #t) (lambda () (set! exits (cons 'k exits))))])
    (test-user:press! "C-u C-g")
    (check-equal? '() exits)
    (check-equal? #f (keys:prefix-description one))
    (keys:bind! keys:global "C-x C-g" keys:keyboard-quit)
    (test-user:press! "C-x C-g")
    (check-equal? '() exits)
    (check-equal? #f (keys:pending one))
    (check (memq quit-temporary (keys:active-keymaps one)))
    (test-user:press! "C-g")
    (check-equal? '(k) exits)
    (check (not (memq quit-temporary (keys:active-keymaps one))))
    (tables:remove! keys:global "C-x C-g")))

(test "keyboard-quit with nothing pending cancels the newest paused command that a key of its client started"
  (let* ([one (test-user:client)] [two (test-user:open-client)]
         [wait-in (lambda (client name)
                    (spawn-task (lambda (restore) (keys:press! client "C-c") (keys:press! client "w")))
                    (test-user:settle))]
         [waits (begin (wait-in one 'first) (wait-in one 'second) (wait-in two 'other) (take-seen!))])
    (check-equal? '((waiting waiting) (waiting waiting) (waiting waiting)) waits)
    (keys:press! one "C-g")
    (test-user:settle)
    (check-equal? '((quit waiting)) (take-seen!))
    (keys:press! one "C-g")
    (test-user:settle)
    (keys:press! one "C-g")
    (test-user:settle)
    (check-equal? '((quit waiting)) (take-seen!))
    (keys:press! two "C-g")
    (test-user:settle)
    (check-equal? '((quit waiting)) (take-seen!))
    (web:close-client! two)))

(test "two C-g taken before the first quit lands quit two paused commands"
  (let ([one (test-user:client)])
    (spawn-task (lambda (restore) (keys:press! one "C-c") (keys:press! one "w")))
    (spawn-task (lambda (restore) (keys:press! one "C-c") (keys:press! one "w")))
    (test-user:settle)
    (take-seen!)
    (keys:press! one "C-g")
    (keys:press! one "C-g")
    (test-user:settle)
    (check-equal? '((quit waiting) (quit waiting)) (take-seen!))
    (commands:run keys:keyboard-quit)))

(test "a quit key the user types quits the command still running, and keyboard-quit then runs as its binding"
  (test-user:press! "C-c w")
  (check-equal? '((waiting waiting)) (take-seen!))
  (test-user:press! "C-g")
  (check-equal? '((quit waiting)) (take-seen!)))

(test "when a client is removed, its temporary keymaps end, each running its on-exit, and the commands its keys paused are quit; another client's stay"
  (tables:define-table jump-keymap "jump")
  (let* ([c1 (test-user:open-client)] [c2 (test-user:open-client)] [exits '()]
         [exit-of (lambda (name) (lambda () (set! exits (cons name exits))))])
    (keys:push-keymap! c1 jump-keymap (lambda (found command) #t) (exit-of 'one) "Jump: ")
    (keys:push-keymap! c2 jump-keymap (lambda (found command) #t) (exit-of 'two) "Jump: ")
    (test-user:press! c1 "C-c w")
    (check-equal? '((waiting waiting)) (take-seen!))
    (check-equal? '("Jump: " "Jump: ") (list (keys:prompt c1) (keys:prompt c2)))
    (web:close-client! c1)
    (test-user:settle)
    (check-equal? '(one) exits)
    (check-equal? '((quit waiting)) (take-seen!))
    (check-equal? '(#f "Jump: ") (list (keys:prompt c1) (keys:prompt c2)))
    (web:close-client! c2)
    (check-equal? '(two one) exits)))

(test "a temporary keymap's prompt is the client's prompt while it is the newest with one; a procedure is called each time it is asked for"
  (tables:define-table prompting-keymap "prompting")
  (tables:define-table plain-keymap "plain")
  (let* ([one (test-user:client)] [asked 0]
         [end-a (keys:push-keymap! one prompting-keymap (lambda (f c) #t) void (list "Failing I-search: " (cons #f "fo")))]
         [end-b (keys:push-keymap! one plain-keymap (lambda (f c) #t))])
    (check-equal? '("Failing I-search: " (#f . "fo")) (keys:prompt one))
    (end-a)
    (check-equal? #f (keys:prompt one))
    (let ([end-c (keys:push-keymap! one prompting-keymap (lambda (f c) #t) void
                   (lambda () (set! asked (+ asked 1)) (format "Asked ~a: " asked)))])
      (check-equal? "Asked 1: " (keys:prompt one))
      (check-equal? "Asked 2: " (keys:prompt one))
      (end-c))
    (end-b)))

(test "a prompt procedure that raises, or returns what is no prompt, is reported and gives #f"
  (tables:define-table bad-prompt-keymap "bad prompt")
  (let* ([one (test-user:client)] [prompt #f]
         [end (keys:push-keymap! one bad-prompt-keymap (lambda (f c) #t) void (lambda () (car '())))])
    (check-equal? '("~s is not a pair") (keys-test:report-messages (lambda () (set! prompt (keys:prompt one)))))
    (check-equal? #f prompt)
    (end)
    (let ([end (keys:push-keymap! one bad-prompt-keymap (lambda (f c) #t) void (lambda () 'x))])
      (check-equal? '("a prompt procedure returned what is not a prompt or #f")
                    (keys-test:report-messages (lambda () (set! prompt (keys:prompt one)))))
      (check-equal? #f prompt)
      (end))))
