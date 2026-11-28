(import (tuna) (test) (test-runner) (test-user) (web) (views) (layout) (options) (tables) (commands) (keys) (keys-test))

(define got '())

(define (got! v) (set! got (cons v got)))

(define (take-got!) (let ([g (reverse got)]) (set! got '()) g))

(define (quit-or thunk) (guard (c [(cancelled? c) 'quit]) (thunk)))

(define ran '())

(commands:define-command (read-one)
  "Records the next key, the prefix argument and the keys that ran it."
  (let ([key (quit-or keys:read-key)])
    (got! (list key (commands:prefix-argument) (keys:command-keys)))))

(commands:define-command (read-sequence)
  "Records the next key sequence."
  (got! (quit-or keys:read-key-sequence)))

(commands:define-command (visit)
  "Records that it ran."
  (set! ran (cons 'visit ran)))

(define go #f)

(commands:define-command (wait-then-read [sequence? (commands:prefix-argument)])
  "Waits for go, then records the next key, or with a prefix argument the next key sequence."
  (suspend (lambda (resume) (set! go resume)))
  (got! (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))])
          ((if sequence? keys:read-key-sequence keys:read-key)))))

(commands:define-command (read-asking [sequence? (commands:prefix-argument)])
  "Records the next key, or with a prefix argument the next key sequence, read with a prompt."
  (got! (quit-or (lambda () (if sequence? (keys:read-key-sequence "Keys: ") (keys:read-key "Key: "))))))

(commands:define-command (read-with-parts)
  "Records the next key, read with a prompt that shows text."
  (got! (keys:read-key (list "Key for " (cons #f "x") ": "))))

(keys:bind! keys:global "C-c k" read-one)
(keys:bind! keys:global "C-c s" read-sequence)
(keys:bind! keys:global "C-x C-f" visit)
(keys:bind! keys:global "C-c w" wait-then-read)
(keys:bind! keys:global "C-c a" read-asking)
(keys:bind! keys:global "C-c p" read-with-parts)

(define (take-ran!) (let ([r ran]) (set! ran '()) r))

(define (event-summary e)
  (if (keys:event? e)
      (cons (keys:event-key e) (map views:posn-point (cdr e)))
      e))

(test "a key read returns the next key without looking it up, so nothing runs; reading gives the keys that ran the reading command"
  (let ([two (test-user:open-client)])
    (test-user:press! "C-c k")
    (check-equal? '("C-c k" #f) (list (keys:reading (test-user:client)) (keys:reading two)))
    (test-user:press! "C-x")
    (check-equal? '(("C-x" #f "C-c k")) (take-got!))
    (check-equal? '(#f #f) (list (keys:pending (test-user:client)) (keys:reading (test-user:client))))
    (test-user:press! "C-c k <f5>")
    (check-equal? '(("<f5>" #f "C-c k")) (take-got!))
    (check-equal? '() (take-ran!))
    (web:close-client! two)))

(test "a read returns every key, quit keys included, and they quit nothing"
  (test-user:press! "C-c k C-g")
  (test-user:press! "C-c k ESC")
  (check-equal? '(("C-g" #f "C-c k") ("ESC" #f "C-c k")) (take-got!)))

(test "a mouse key is read as its event, and a press or a move never ends a read, even when bound"
  (test-user:show! "|0123456789")
  (keys:bind! keys:global "<down-mouse-1>" keys:ignore)
  (test-user:press! "C-c k")
  (test-user:drag! (layout:selected-view) 3 5)
  (check-equal? '((("<drag-mouse-1>" 3 5) #f "C-c k")) (map (lambda (g) (cons (event-summary (car g)) (cdr g))) (take-got!)))
  (tables:remove! keys:global "<down-mouse-1>"))

(test "the reading command keeps its own prefix argument, and the read leaves the client's alone: a C-u read is data"
  (test-user:press! "C-u 3 C-c k C-u")
  (check-equal? '(("C-u" 3 "C-c k")) (take-got!))
  (test-user:press! "C-x C-f")
  (check-equal? '(visit) (take-ran!))
  (check-equal? #f (keys:prefix-description (test-user:client))))

(test "while a read waits, no temporary keymap is tested, and advice on press! sees the key"
  (tables:define-table read-temporary "temporary")
  (let* ([tested 0] [pressed '()]
         [end (keys:push-keymap! (test-user:client) read-temporary (lambda (found command) (set! tested (+ tested 1)) #t))]
         [note (lambda (press client key) (set! pressed (cons key pressed)) (press client key))])
    (test-user:press! "C-c k")
    (set! tested 0)
    (advice-add! keys:press! note)
    (test-user:press! "a")
    (advice-remove! keys:press! note)
    (check-equal? '(("a" #f "C-c k")) (take-got!))
    (check-equal? 0 tested)
    (check-equal? '("a") pressed)
    (end)))

(test "a sequence read is finished by press!'s rules and returned as typed, and the keys read so far are pending"
  (test-user:press! "C-c s C-x")
  (check-equal? '("C-x" "C-c s") (list (keys:pending (test-user:client)) (keys:reading (test-user:client))))
  (test-user:press! "C-f")
  (check-equal? '("C-x C-f") (take-got!))
  (check-equal? '() (take-ran!))
  (check-equal? #f (keys:pending (test-user:client)))
  (for-each (lambda (keys) (test-user:press! "C-c s") (test-user:press! keys)) '("ESC" "C-F" "C-g" "C-x C-g" "C-c z"))
  (check-equal? '("ESC" "C-F" "C-g" "C-x C-g" "C-c z") (take-got!)))

(test "a sequence read returns a mouse key's event, a press then a drag as the drag, and a mouse key after a typed prefix as typed"
  (test-user:show! "|0123456789")
  (test-user:press! "C-c s")
  (test-user:click! (layout:selected-view) 3)
  (test-user:press! "C-c s")
  (test-user:drag! (layout:selected-view) 3 6)
  (test-user:press! "C-c s C-x")
  (test-user:click! (layout:selected-view) 2)
  (check-equal? '(("<mouse-1>" 3) ("<drag-mouse-1>" 3 6) "C-x <mouse-1>") (map event-summary (take-got!))))

(test "an ESC that is the Meta prefix waits for the next key, and a sequence read returns both as typed"
  (options:set! keys:quit-keys '("C-g"))
  (keys:unbind! keys:global "ESC")
  (test-user:press! "C-c s ESC x")
  (check-equal? '("ESC x") (take-got!))
  (options:unset! keys:quit-keys)
  (keys:bind! keys:global "ESC" keys:keyboard-quit))

(test "keys typed while a command waits before reading are an unfinished sequence: a sequence read continues them, a key read drops them"
  (test-user:press! "C-u C-c w C-x")
  (go void)
  (test-user:settle)
  (check-equal? '("C-x" "C-c w") (list (keys:pending (test-user:client)) (keys:reading (test-user:client))))
  (test-user:press! "C-f")
  (check-equal? '("C-x C-f") (take-got!))
  (check-equal? '() (take-ran!))
  (test-user:press! "C-c w C-x")
  (go void)
  (test-user:settle)
  (check-equal? '(#f "C-c w") (list (keys:pending (test-user:client)) (keys:reading (test-user:client))))
  (test-user:press! "C-f")
  (check-equal? '("C-f") (take-got!)))

(test "a read's prompt is given by reading-prompt while the read waits, and by prompt before a temporary keymap's"
  (tables:define-table prompted-temporary "prompted")
  (let* ([one (test-user:client)] [two (test-user:open-client)]
         [end (keys:push-keymap! one prompted-temporary (lambda (f c) #t) void "Jump: ")])
    (test-user:press! "C-c a")
    (check-equal? '("C-c a" "Key: " #f "Key: ") (list (keys:reading one) (keys:reading-prompt one) (keys:reading-prompt two) (keys:prompt one)))
    (test-user:press! "x")
    (check-equal? '("x") (take-got!))
    (check-equal? '(#f "Jump: ") (list (keys:reading-prompt one) (keys:prompt one)))
    (test-user:press! "C-u C-c a C-x")
    (check-equal? '("Keys: " "C-x") (list (keys:reading-prompt one) (keys:pending one)))
    (test-user:press! "C-f")
    (check-equal? '("C-x C-f") (take-got!))
    (test-user:press! "C-c k")
    (check-equal? '(#f "Jump: ") (list (keys:reading-prompt one) (keys:prompt one)))
    (test-user:press! "y")
    (check-equal? '(("y" #f "C-c k")) (take-got!))
    (end)
    (web:close-client! two)))

(test "a read's prompt may hold shown text"
  (test-user:press! "C-c p")
  (check-equal? '("Key for " (#f . "x") ": ") (keys:reading-prompt (test-user:client)))
  (test-user:press! "y")
  (check-equal? '("y") (take-got!)))

(test "a read refuses what is no prompt, and needs the main thread and a command a key ran"
  (for-each
    (lambda (read who)
      (check-raises (test-runner:raised-with who "not a prompt or #f") (read 'x))
      (check-equal? (list who "not on the main thread") (keys-test:on-thread read))
      (check-raises (test-runner:raised-with who "no command a key ran is running") (read)))
    (list keys:read-key keys:read-key-sequence)
    '(keys:read-key keys:read-key-sequence))
  (for-each
    (lambda (bad) (check-raises (test-runner:raised-with 'keys:read-key "not a prompt or #f") (keys:read-key bad)))
    (list (lambda () "Key: ") '() '(("x" . #f))))
  (check-equal? '(keys:reading "not on the main thread") (keys-test:on-thread (lambda () (keys:reading (test-user:client)))))
  (check-equal? '(keys:reading-prompt "not on the main thread")
                (keys-test:on-thread (lambda () (keys:reading-prompt (test-user:client))))))

(test "a client has one read at a time"
  (test-user:press! "C-c w C-c k")
  (go void)
  (test-user:settle)
  (check-equal? '((keys:read-key "a key is already being read for this client")) (take-got!))
  (test-user:press! "z")
  (check-equal? '(("z" #f "C-c k")) (take-got!)))

(test "another client's keys run while one reads, and each client reads on its own"
  (let ([one (test-user:client)] [two (test-user:open-client)])
    (test-user:press! one "C-c k")
    (test-user:press! two "C-x C-f")
    (check-equal? '(visit) (take-ran!))
    (test-user:press! two "C-c k")
    (check-equal? '("C-c k" "C-c k") (list (keys:reading one) (keys:reading two)))
    (test-user:press! two "c")
    (test-user:press! one "d")
    (check-equal? '(("c" #f "C-c k") ("d" #f "C-c k")) (take-got!))
    (web:close-client! two)))

(test "while a client reads, its page marks no key as a quit, and gets its quit keys back once the read has its key"
  (let* ([c (test-user:open-client)]
         [settings (lambda () (map (lambda (call) (cdr (assoc "quitKeys" (cdr call))))
                                   (filter (lambda (call) (equal? "keys-settings" (car call))) (test-user:take-page-calls! c))))])
    (test-user:settle)
    (check-equal? '(#("C-g" "ESC")) (settings))
    (test-user:press! c "C-c k")
    (check-equal? '(#()) (settings))
    (check-equal? '() (keys:page-quit-keys c))
    (test-user:press! c "C-g")
    (check-equal? '(("C-g" #f "C-c k")) (take-got!))
    (check-equal? '(#("C-g" "ESC")) (settings))
    (web:close-client! c)))

(test "when its client is removed, a read raises &cancelled in its command; a key handed to the read just before reaches it first"
  (let ([c1 (test-user:open-client)] [c2 (test-user:open-client)])
    (test-user:press! c1 "C-c k")
    (web:close-client! c1)
    (test-user:settle)
    (check-equal? '((quit #f "C-c k")) (take-got!))
    (check-equal? #f (keys:reading c1))
    (let ([c3 (test-user:open-client)])
      (test-user:press! c2 "C-c k")
      (test-user:press! c3 "C-c k")
      (keys:press! c3 "e")
      (web:close-client! c3)
      (test-user:settle)
      (check-equal? '(("e" #f "C-c k")) (take-got!))
      (check-equal? "C-c k" (keys:reading c2))
      (test-user:press! c2 "f")
      (check-equal? '(("f" #f "C-c k")) (take-got!))
      (web:close-client! c2))))

(commands:define-command (bind-other-view [keys (keys:read-key-sequence "Bind key: ")])
  "Binds the next key sequence typed to layout:other-view."
  (keys:bind! keys:global (if (keys:event? keys) (keys:event-key keys) keys) layout:other-view))

(keys:bind! keys:global "C-c b" bind-other-view)

(test "the page's example command binds the next key sequence typed"
  (test-user:press! "C-c b")
  (check-equal? '("C-c b" "Bind key: ") (list (keys:reading (test-user:client)) (keys:reading-prompt (test-user:client))))
  (test-user:press! "C-c v")
  (check-equal? layout:other-view (keys:lookup (test-user:client) "C-c v")))
