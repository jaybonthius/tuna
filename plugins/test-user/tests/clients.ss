(import (tuna) (test) (test-user) (web) (keys) (commands) (editing) (layout) (options) (views) (buffers) (hooks))

(define (raised-by who)
  (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))

(define (calls-named names calls)
  (filter (lambda (call) (member (car call) names)) calls))

(define waiting #f)

(commands:define-command (wait-for-ever)
  "Pauses until cancelled."
  (guard (e [(cancelled? e) (set! waiting (list 'cancelled (cancelled-reason e)))])
    (set! waiting 'paused)
    (suspend (lambda (resume) (void)))))

(define pressed-by '())

(commands:define-command (note-client)
  "Notes the client whose key ran it."
  (set! pressed-by (cons (web:current-client) pressed-by)))

(define asked #f)

(commands:define-command (ask-the-page)
  "Asks its client's page a question and keeps the answer."
  (set! asked (web:ask-page (web:current-client) "times-ten" 4)))

(commands:define-command (insert-read-key)
  "Reads a key and inserts it at the start of the selected view's buffer."
  (let ([key (keys:read-key)])
    (buffers:insert! (views:buffer (layout:selected-view)) 1 key)))

(define spinning #f)

(commands:define-command (spin)
  "Runs until cancelled."
  (set! spinning #t)
  (let loop () (loop)))

(keys:bind! keys:global "C-c r" insert-read-key)
(keys:bind! keys:global "C-c s" spin)
(keys:bind! keys:global "C-c w" wait-for-ever)
(keys:bind! keys:global "C-c n" note-client)
(keys:bind! keys:global "C-c a" ask-the-page)

(test "test-user:client is a client of web, opened when test-user loads, that web:clients lists"
  (check (web:client? (test-user:client)))
  (check (memq (test-user:client) (web:clients))))

(test "keys pressed and text typed run as the client's input, and have run when press! and type! return"
  (test-user:show! "one|")
  (test-user:type! " two\nthree")
  (check-equal? "one two\nthree|" (test-user:text))
  (test-user:press! "C-a C-f")
  (check-equal? "one two\nt|hree" (test-user:text))
  (test-user:type! "")
  (check-equal? "one two\nt|hree" (test-user:text)))

(test "a command that asks its page has continued with the answer when press! returns"
  (let ([other (test-user:open-client (lambda (name value) (* 10 value)))])
    (set! asked #f)
    (test-user:press! other "C-c a")
    (check-equal? 40 asked)
    (web:close-client! other)))

(test "a quit key is posted as a quit, so it stops a command that is still running"
  (test-user:press! "C-c w")
  (check-equal? 'paused waiting)
  (test-user:press! "C-g")
  (check-equal? '(cancelled quit) waiting))

(test "a quit key stops a command that runs without pausing at the first quit, which the command reports before after-command runs"
  (let* ([events '()]
         [note-end (lambda (command) (set! events (cons command events)))]
         [keep (lambda (next c) (set! events (cons (if (cancelled? c) (list 'cancelled (cancelled-reason c)) c) events)))])
    (set! spinning #f)
    (hooks:add! commands:after-command note-end)
    (advice-add! report keep)
    ;; test-user:press! would wait behind the running command, so the C-g
    ;; comes from a thread of its own, as a browser's does.
    (fork-task
      (lambda (restore)
        (let wait () (unless spinning (sleep (make-time 'time-duration 1000000 0)) (wait)))
        (web:post-input! (test-user:client) '(("type" . "key") ("name" . "C-g") ("quit" . #t)))))
    (test-user:press! "C-c s")
    (advice-remove! report keep)
    (hooks:remove! commands:after-command note-end)
    (check-equal? (list '(cancelled quit) spin keys:keyboard-quit) (reverse events))))

(test "a quit key typed to a command that reads a key is the key it reads, as in a browser"
  (test-user:show! "|")
  (test-user:press! "C-q C-g")
  (check-equal? "\x7;|" (test-user:text))
  (test-user:press! "C-q")
  (check-equal? '() (keys:page-quit-keys (test-user:client)))
  (test-user:press! "C-g")
  (check-equal? "\x7;\x7;|" (test-user:text)))

(test "keys go to the client named, and a client test-user did not open is refused"
  (let ([other (test-user:open-client)])
    (set! pressed-by '())
    (test-user:press! other "C-c n")
    (test-user:press! "C-c n")
    (check-equal? (list (test-user:client) other) pressed-by)
    (web:close-client! other)
    (check-raises (raised-by 'test-user:press!) (test-user:press! 'client "a"))
    (check-raises (raised-by 'test-user:type!) (test-user:type! 'client "a"))))

(test "a tab is typed as TAB, and text with a character that is no key is refused before any key is typed"
  (let* ([keys '()] [note (lambda (next client key) (set! keys (cons key keys)) (next client key))])
    (advice-add! keys:press! note)
    (test-user:show! "|")
    (test-user:type! "a\tb")
    (advice-remove! keys:press! note)
    (check-equal? '("a" "TAB" "b") (reverse keys))
    (test-user:show! "|")
    (check-raises (raised-by 'test-user:type!) (test-user:type! "a\x1;b"))
    (check-raises (raised-by 'keys:sequence-keys) (test-user:press! "a  b"))
    (test-user:settle)
    (check-equal? "|" (test-user:text))))

(test "the page calls made for a client are taken oldest first, each once, as a page would get them"
  (let ([other (test-user:open-client)])
    (web:call-page! other "first" 1)
    (web:call-page! other "second" '#(2 null))
    (check-equal? '(("first" . 1) ("second" . #(2 null))) (calls-named '("first" "second") (test-user:take-page-calls! other)))
    (check-equal? '() (test-user:take-page-calls! other))
    (web:call-page! (test-user:client) "first" 3)
    (check-equal? '(("first" . 3)) (calls-named '("first") (test-user:take-page-calls!)))
    (web:close-client! other)))

(test "a client's page questions are answered by the procedure it was opened with, by default with null"
  (let* ([other (test-user:open-client (lambda (name value) (vector name (* 2 value))))]
         [asker (spawn-task (lambda (restore) (web:ask-page other "double" 21)))])
    (test-user:settle)
    (let-values ([(how detail) (join-task asker)])
      (check-equal? '(returned (#("double" 42))) (list how detail)))
    (let ([unanswered (spawn-task (lambda (restore) (web:ask-page (test-user:client) "double" 1)))])
      (test-user:settle)
      (let-values ([(how detail) (join-task unanswered)])
        (check-equal? '(returned (null)) (list how detail))))
    (web:close-client! other)
    (check-raises (raised-by 'test-user:open-client) (test-user:open-client 'answer))))

(test "test-user:title is the title of the client's last screen, a new title alone included"
  (test-user:show! "|")
  (test-user:settle)
  (options:set! layout:page-title (lambda (name) "Other title"))
  (test-user:settle)
  (check-equal? "Other title" (test-user:title))
  (options:unset! layout:page-title)
  (test-user:settle)
  (check (not (equal? "Other title" (test-user:title))))
  (let ([other (test-user:open-client)])
    (check-raises (raised-by 'test-user:title) (test-user:title other))
    (web:close-client! other)))

(test "settle returns once the tasks queued before it have run and their batch has ended"
  (let ([ran #f])
    (spawn-task (lambda (restore) (set! ran #t)))
    (test-user:settle)
    (check ran)))

(test "settle returns once a command that a key's read resumed has continued and been drawn"
  (test-user:show! "|one")
  (test-user:press! "C-c r x")
  (let ([id (number->string (views:id (layout:selected-view)))])
    (check-equal? '("xone")
                  (map test-user:element-text
                       (test-user:elements (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
                                                 (test-user:elements-with (test-user:screen) "data-view"))
                                           "line")))))
